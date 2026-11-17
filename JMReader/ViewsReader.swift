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
    /// Scroll mode pull-to-next-chapter: footer hint visibility, the
    /// armed state (pulled far enough, waiting for release), the
    /// once-per-chapter latch, and the instant scroll-reset counter.
    @State private var pullHint = false
    @State private var endSwipeArmed = false
    @State private var endSwipeLatched = false
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
        .onChange(of: chapterId) { _ in endSwipeLatched = false }
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
                    Text(hasNextChapter && pullHint ? "— 松开进入下一话 —" : "— 本话完 —")
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

    /// Scroll mode: pulling past the end of the chapter (rubber-band
    /// overscroll) arms the step to the next chapter; it fires on
    /// release (handleDragState), so the content never swaps while the
    /// finger is still pulling — build 73 fired mid-pull and the swap
    /// felt stiff. Pulling back into the chapter disarms it. Short
    /// chapters (content barely taller than the viewport) are excluded
    /// so a pull can't arm on a chapter that doesn't scroll.
    private func handleScrollOffset(_ off: CGFloat, total: CGFloat, viewport: CGFloat) {
        guard !paged, !pages.isEmpty, viewport > 0, total > viewport + 50 else { return }
        let over = off - (total - viewport)
        let hint = over > 40
        if hint != pullHint { pullHint = hint }
        if over > 90 { endSwipeArmed = true }
        else if over < 10 { endSwipeArmed = false }
    }

    private func handleDragState(_ dragging: Bool) {
        guard !dragging, endSwipeArmed else { return }
        endSwipeArmed = false
        guard !paged, !endSwipeLatched, hasNextChapter else { return }
        endSwipeLatched = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        stepChapter(1)
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
