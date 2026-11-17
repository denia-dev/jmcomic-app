import SwiftUI

struct ReaderRoute: Hashable, Identifiable {
    var albumId: String
    var albumName: String
    var chapters: [ChapterRef]
    var startChapterId: String
    var startPage: Int
    var id: String { albumId + "|" + startChapterId + "|" + String(startPage) }
}

struct ReaderView: View {
    let route: ReaderRoute
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var readingStats: ReadingStatsStore
    @Environment(\.dismiss) private var dismiss

    @State private var chapterId: String = ""
    @State private var chapterName: String = ""
    @State private var pages: [String] = []
    @State private var seriesFromAPI: [ChapterRef] = []
    @State private var currentPage: Int = 0
    @State private var showChrome = true
    @State private var loading = true
    @State private var loadFailed = false
    @State private var jumpTarget: Int?
    @State private var sliderValue: Double = 0
    @State private var didInit = false
    @State private var displayIndex: Int = 0
    /// Scroll mode pull-to-next-chapter transition: the live overscroll
    /// distance driving the next chapter's preview strip, the cover /
    /// reveal flags for the release transition, the chapter being
    /// transitioned to, its preloaded first-page preview, and the
    /// instant scroll-reset counter.
    @State private var pullOver: CGFloat = 0
    @State private var coverFull = false
    @State private var coverHidden = false
    @State private var transitioning = false
    @State private var transitionTargetId: String?
    @State private var nextPreview: UIImage?
    @State private var resetNonce = 0
    /// Chapters fetched ahead of time (the next-chapter preload fills this),
    /// so stepping to the next chapter doesn't wait on the network.
    @State private var chapterCache: [String: ChapterData] = [:]
    @State private var preloadTask: Task<Void, Never>?
    @AppStorage("reader.mode") private var readerMode = "scroll"   // scroll | page
    @AppStorage("reader.rtl") private var readerRTL = false

    private var paged: Bool { readerMode == "page" }

    private var chapters: [ChapterRef] {
        !route.chapters.isEmpty ? route.chapters : seriesFromAPI
    }
    private var chapterIndex: Int? { chapters.firstIndex { $0.id == chapterId } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if showChrome { chromeOverlay }
            if pullOver > 0 || coverFull { pullOverlay }
            if loading { ProgressView().tint(.white) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .restoreSwipeBack()
        .swipeAnywhereBack { dismiss() }
        .onChange(of: readerRTL) { _ in
            if paged { displayIndex = displayIndex(forLogical: currentPage) }
        }
        .onChange(of: readerMode) { _ in
            if paged { displayIndex = displayIndex(forLogical: currentPage) }
        }
        .onChange(of: currentPage) { newPage in
            // Reading stats: count pages as they are actually reached, in
            // both scroll and paged modes (both funnel through currentPage).
            readingStats.recordPage(episodeId: chapterId, pageIndex: newPage, chapterPages: pages.count)
        }
        .onChange(of: chapterId) { _ in pullOver = 0 }
        .task(id: chapterId) { await loadNextPreview() }
                        .task {
            if !didInit {
                didInit = true
                await openChapter(id: route.startChapterId, page: route.startPage)
            }
        }
        .task {
            // Reading-time statistics: accrue 10 s at a time while the
            // reader is on screen; the task dies with the view.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                readingStats.addSeconds(10)
            }
        }
        .onDisappear {
            preloadTask?.cancel()
            // Final progress save (per-page saves are silent now), then one
            // refresh signal so the detail view's resume label is current.
            saveProgress()
            library.noteProgressChanged()
            // Stats were recorded silently while reading; publish them now
            // that the reader is gone (publishing mid-push popped it back).
            readingStats.flushPublishes()
        }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            Group {
                if paged {
                    pagedContent
                } else {
                    scrollContent
                }
            }
            .onChange(of: jumpTarget) { target in
                if let target {
                    if paged {
                        displayIndex = displayIndex(forLogical: target)
                    } else {
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                    }
                    jumpTarget = nil
                }
            }
            .onChange(of: resetNonce) { _ in
                // Chapter switches land on the first page instantly; the
                // animated jumpTarget path stays for slider scrubs.
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, file in
                    ReaderPageView(chapterId: chapterId, file: file)
                        .id(idx)
                        .onAppear {
                            currentPage = idx
                            sliderValue = Double(idx)
                            saveProgress()
                            prefetch(after: idx)
                        }
                }
                if loadFailed {
                    Text("这一话加载失败，下拉或重进试试").foregroundColor(.gray)
                        .padding(.vertical, 60)
                } else if !pages.isEmpty {
                    Text("— 本话完 —")
                        .foregroundColor(.gray).font(.footnote)
                        .padding(.vertical, 34)
                }
            }
            .background {
                ScrollViewTracker(onDragging: { dragging in
                    handleDragState(dragging)
                }) { off, total, vp in
                    handleScrollOffset(off, total: total, viewport: vp)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        })
    }

    // MARK: - paged (horizontal) mode

    private func displayIndex(forLogical page: Int) -> Int {
        readerRTL ? max(pages.count - 1 - page, 0) : page
    }
    private func logicalPage(forDisplay idx: Int) -> Int {
        readerRTL ? max(pages.count - 1 - idx, 0) : idx
    }

    private var pagedContent: some View {
        TabView(selection: $displayIndex) {
            ForEach(pages.indices, id: \.self) { dIdx in
                let logical = logicalPage(forDisplay: dIdx)
                ZStack {
                    ReaderPageView(chapterId: chapterId, file: pages[logical])
                    HStack(spacing: 0) {
                        tapZone { stepPage(displayDelta: readerRTL ? 1 : -1) }
                        tapZone {
                            withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
                        }
                        tapZone { stepPage(displayDelta: readerRTL ? -1 : 1) }
                    }
                }
                .tag(dIdx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: displayIndex) { newValue in
            let logical = logicalPage(forDisplay: newValue)
            if logical != currentPage {
                currentPage = logical
                sliderValue = Double(logical)
                saveProgress()
                prefetch(after: logical)
            }
        }
    }

    private func tapZone(action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { action() }
    }

    private func stepPage(displayDelta: Int) {
        let next = displayIndex + displayDelta
        guard pages.indices.contains(next) else { return }
        withAnimation { displayIndex = next }
    }

    private var chromeOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline)
                        .padding(9).glassSurface(Circle(), interactive: true)
                }
                Text(chapterName.isEmpty ? route.albumName : chapterName)
                    .font(.subheadline).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassSurface(RoundedRectangle(cornerRadius: 10))
                Spacer()
                Menu {
                    Button(paged ? "上下卷轴" : "✓ 上下卷轴") { readerMode = "scroll" }
                    Button(paged ? "✓ 横向翻页" : "横向翻页") { readerMode = "page" }
                    if paged {
                        Divider()
                        Button(readerRTL ? "从左往右" : "✓ 从左往右") { readerRTL = false }
                        Button(readerRTL ? "✓ 从右往左" : "从右往左") { readerRTL = true }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.subheadline)
                        .padding(9)
                        .glassSurface(Circle(), interactive: true)
                }
                Text(pages.isEmpty ? "" : "\(currentPage + 1) / \(pages.count)")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassSurface(RoundedRectangle(cornerRadius: 10))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            Spacer()
            // Single slim row, about as tall as the round chrome buttons:
            // prev / page count / slider / next (user-approved mock, 2026-11-03).
            HStack(spacing: 10) {
                Button("‹ 上一话") { stepChapter(-1) }
                    .disabled(chapterIndex == nil || chapterIndex == 0)
                if !pages.isEmpty {
                    Text("\(currentPage + 1) / \(pages.count)")
                        .font(.footnote).foregroundColor(accentPink)
                        .fixedSize()
                    Slider(value: $sliderValue, in: 0...Double(max(pages.count - 1, 1)), step: 1) { editing in
                        if !editing { jumpTarget = Int(sliderValue) }
                    }
                    .tint(accentPink)
                }
                Button("下一话 ›") { stepChapter(1) }
                    .disabled(chapterIndex == nil || chapterIndex == chapters.count - 1)
            }
            .font(.subheadline).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassSurface(RoundedRectangle(cornerRadius: 30))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    // MARK: - actions

    private func openChapter(id: String, page: Int) async {
        if let cached = chapterCache[id] {
            applyChapter(cached, id: id, page: page)
            return
        }
        loading = true
        loadFailed = false
        do {
            let ch = try await JMClient.shared.chapter(id: id)
            chapterCache[id] = ch
            applyChapter(ch, id: id, page: page)
        } catch {
            loading = false
            loadFailed = true
        }
    }

    private func applyChapter(_ ch: ChapterData, id: String, page: Int) {
        chapterId = id
        chapterName = ch.name
        pages = ch.images
        if !ch.series.isEmpty { seriesFromAPI = ch.series }
        currentPage = 0
        sliderValue = 0
        displayIndex = displayIndex(forLogical: 0)
        loading = false
        loadFailed = false
        readingStats.recordChapter(albumId: route.albumId, episodeId: id)
        readingStats.recordPage(episodeId: id, pageIndex: page, chapterPages: ch.images.count)
        if page > 0 && page < ch.images.count {
            // give layout a beat, then jump
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                currentPage = page
                sliderValue = Double(page)
                jumpTarget = page
            }
        }
        if !ch.images.isEmpty { prefetch(after: -1) }
        preloadNextChapter()
    }

    /// Fetch the next chapter's data and warm the image cache for its first
    /// pages while the user reads the current one, so "下一话" opens
    /// instantly. Only the first pages, loaded one at a time: warming the
    /// whole chapter at once flooded the network and the image cache and
    /// made the current chapter stutter (v2.18 build 40; throttled in 41).
    private func preloadNextChapter() {
        guard let idx = chapterIndex else { return }
        let nextIdx = idx + 1
        guard chapters.indices.contains(nextIdx) else { return }
        let nextId = chapters[nextIdx].id
        guard chapterCache[nextId] == nil else { return }
        preloadTask?.cancel()
        preloadTask = Task {
            guard let ch = try? await JMClient.shared.chapter(id: nextId) else { return }
            chapterCache[nextId] = ch
            for file in ch.images.prefix(6) {
                if Task.isCancelled { return }
                let stem = (file as NSString).deletingPathExtension
                _ = await ImagePipe.shared.load(path: ImagePipe.pagePath(chapterId: nextId, file: file),
                                                scrambleNum: ImagePipe.splitNum(chapterId: nextId, stem: stem))
            }
        }
    }

    private func stepChapter(_ delta: Int) {
        guard let idx = chapterIndex else { return }
        let next = idx + delta
        guard chapters.indices.contains(next) else { return }
        let target = chapters[next]
        Task {
            await openChapter(id: target.id, page: 0)
            resetNonce += 1
        }
    }

    private var hasNextChapter: Bool {
        guard let idx = chapterIndex else { return false }
        return idx < chapters.count - 1
    }

    private var nextChapterRef: ChapterRef? {
        guard let idx = chapterIndex, chapters.indices.contains(idx + 1) else { return nil }
        return chapters[idx + 1]
    }

    /// The pull-transition overlay: the next chapter's first page rises
    /// from the bottom edge in step with the overscroll pull; on a
    /// committed release it expands to cover the screen, the chapter
    /// swaps underneath, and the cover crossfades away — the overlay's
    /// page and the new chapter's first page are the same image in the
    /// same layout, so the reveal is seamless.
    private var pullOverlay: some View {
        GeometryReader { geo in
            let h = coverFull ? geo.size.height : min(pullOver, 340)
            ZStack(alignment: .top) {
                Color.black
                if let nextPreview {
                    Image(uiImage: nextPreview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, alignment: .top)
                }
                if let next = nextChapterRef, h > 60 || coverFull {
                    Text("下一话 · \(next.name)")
                        .font(.footnote).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassSurface(RoundedRectangle(cornerRadius: 10))
                        .padding(.top, coverFull ? 54 : 10)
                }
                if coverFull, let target = transitionTargetId, chapterId != target {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: h)
            .clipped()
            .opacity(coverHidden ? 0 : 1)
            .offset(y: geo.size.height - h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Loads the next chapter's first page as the pull preview. Waits
    /// for the next-chapter preload to land the chapter data in
    /// chapterCache instead of fetching it a second time; the image
    /// itself comes through ImagePipe, which the preload also warms.
    private func loadNextPreview() async {
        nextPreview = nil
        guard let next = nextChapterRef else { return }
        var data = chapterCache[next.id]
        for _ in 0..<40 where data == nil {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            data = chapterCache[next.id]
        }
        guard let data, let file = data.images.first else { return }
        let stem = (file as NSString).deletingPathExtension
        nextPreview = await ImagePipe.shared.load(
            path: ImagePipe.pagePath(chapterId: next.id, file: file),
            scrambleNum: ImagePipe.splitNum(chapterId: next.id, stem: stem))
    }

    /// Scroll mode: publish the live overscroll distance so the pull
    /// overlay follows the finger. Quantized — the tracker reports
    /// every offset tick, and only visible changes should re-render.
    /// Short chapters (content barely taller than the viewport) are
    /// excluded so a pull can't start on a chapter that doesn't scroll.
    private func handleScrollOffset(_ off: CGFloat, total: CGFloat, viewport: CGFloat) {
        guard !transitioning else { return }
        guard !paged, !pages.isEmpty, viewport > 0, total > viewport + 50, hasNextChapter else {
            if pullOver != 0 { pullOver = 0 }
            return
        }
        let over = off - (total - viewport)
        let v = over > 0 ? over : 0
        if abs(v - pullOver) >= 2 || (v == 0) != (pullOver == 0) { pullOver = v }
    }

    /// On release past the pull threshold, run the cover transition:
    /// the preview expands to full screen, the chapter swaps underneath
    /// (invisible), then the cover crossfades away onto the new
    /// chapter's first page. Below the threshold nothing happens — the
    /// rubber band pulls the preview back down on its own.
    private func handleDragState(_ dragging: Bool) {
        guard !dragging, !paged, !transitioning, pullOver >= 110,
              let target = nextChapterRef else { return }
        transitioning = true
        transitionTargetId = target.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.22)) { coverFull = true }
        Task {
            try? await Task.sleep(nanoseconds: 230_000_000)
            await openChapter(id: target.id, page: 0)
            resetNonce += 1
            withAnimation(.easeInOut(duration: 0.25)) { coverHidden = true }
            try? await Task.sleep(nanoseconds: 260_000_000)
            coverFull = false
            coverHidden = false
            transitionTargetId = nil
            transitioning = false
            pullOver = 0
        }
    }

    private func saveProgress() {
        guard !chapterId.isEmpty else { return }
        library.saveProgress(albumId: route.albumId, chapterId: chapterId,
                             chapterName: chapterName, page: currentPage,
                             albumName: route.albumName)
    }

    private func prefetch(after idx: Int) {
        for j in (idx + 1)...(idx + 3) {
            guard pages.indices.contains(j) else { return }
            let file = pages[j]
            let stem = (file as NSString).deletingPathExtension
            ImagePipe.shared.preload(path: ImagePipe.pagePath(chapterId: chapterId, file: file),
                                     scrambleNum: ImagePipe.splitNum(chapterId: chapterId, stem: stem))
        }
    }
}

private struct ReaderPageView: View {
    let chapterId: String
    let file: String
    @State private var image: UIImage?

    private var stem: String { (file as NSString).deletingPathExtension }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.05)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay(ProgressView().tint(.gray))
            }
        }
        .task(id: chapterId + file) {
            image = await ImagePipe.shared.load(
                path: ImagePipe.pagePath(chapterId: chapterId, file: file),
                scrambleNum: ImagePipe.splitNum(chapterId: chapterId, stem: stem))
        }
    }
}
