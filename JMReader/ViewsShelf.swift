import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - local image loading (downsampled, file-backed)

enum LocalImageLoader {
    static func thumbnail(_ url: URL, maxPixel: Int) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cg)
    }
}

private struct LocalThumbView: View {
    let url: URL?
    var maxPixel: Int = 480
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: url?.path) {
            guard let url else { return }
            let loaded = await Task.detached(priority: .utility) {
                LocalImageLoader.thumbnail(url, maxPixel: maxPixel)
            }.value
            if let loaded { image = loaded }
        }
    }
}

// MARK: - bookshelf: the books on THIS device
//
// Two independent axes, both requested by the owner:
//  - source: 全部 / JM下载 / 本地导入 (segmented control)
//  - type:   全部 / 漫画 / 小说 (chips) — imports are auto-classified by
//    format at import time (CBZ/ZIP/PDF -> 漫画, EPUB/TXT -> 小说);
//    JM downloads are always 漫画.
// Cloud favorites deliberately stay on the profile tab.

private enum ShelfItem: Identifiable {
    case download(DownloadedRecord)
    case local(LocalBook)
    var id: String {
        switch self {
        case .download(let r): return "dl-" + r.albumId
        case .local(let b): return "local-" + b.id
        }
    }
    var title: String {
        switch self {
        case .download(let r): return r.title
        case .local(let b): return b.title
        }
    }
    var isNovel: Bool {
        switch self {
        case .download: return false
        case .local(let b): return b.kind == .novel
        }
    }
}

/// Scroll-linked shrink/fade for the 最近阅读 rail cells (iOS 17+;
/// older systems just get the plain rail).
private struct RailCellEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTransition { cell, phase in
                cell.scaleEffect(phase.isIdentity ? 1 : 0.9)
                    .opacity(phase.isIdentity ? 1 : 0.45)
            }
        } else {
            content
        }
    }
}

private struct TargetLayoutIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollTargetLayout()
        } else {
            content
        }
    }
}

struct BookshelfView: View {
    @EnvironmentObject var shelf: LocalBookStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @State private var readerRoute: ReaderRoute?
    @State private var segment = 0        // 0 全部 1 下载 2 导入
    @State private var typeFilter = 0     // 0 全部 1 漫画 2 小说 (全部/导入 segments)
    @State private var dlCategory = "__all__"   // downloads segment: JM category filter
    @State private var showImporter = false
    @State private var note: String?
    @State private var pendingDelete: LocalBook?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var visibleLocals: [LocalBook] {
        shelf.books.filter { b in
            switch typeFilter {
            case 1: return b.kind != .novel
            case 2: return b.kind == .novel
            default: return true
            }
        }
    }

    private var visibleDownloads: [DownloadedRecord] {
        if segment == 1 {
            switch dlCategory {
            case "__all__": return downloads.store.records
            case "__none__": return downloads.store.records.filter { downloads.store.category(for: $0.albumId).isEmpty }
            default: return downloads.store.records.filter { downloads.store.category(for: $0.albumId) == dlCategory }
            }
        }
        return typeFilter == 2 ? [] : downloads.store.records
    }

    private var downloadCategories: [String] {
        Array(Set(downloads.store.records.map { downloads.store.category(for: $0.albumId) }.filter { !$0.isEmpty })).sorted()
    }

    private var hasUncategorizedDownloads: Bool {
        downloads.store.records.contains { downloads.store.category(for: $0.albumId).isEmpty }
    }

    private var allItems: [ShelfItem] {
        let d = visibleDownloads.map(ShelfItem.download)
        let l = visibleLocals.map(ShelfItem.local)
        switch segment {
        case 1: return d
        case 2: return l
        default:
            return (d + l).sorted { activity($0) > activity($1) }
        }
    }

    private func activity(_ item: ShelfItem) -> Double {
        switch item {
        case .download(let r): return r.date
        case .local(let b): return shelf.lastActivity(b)
        }
    }

    /// 最近阅读 = the online reading history (LibraryStore.progress),
    /// most recent first. This is what the owner asked for on the shelf:
    /// it must show up from his actual reading, not only after imports.
    private var recentReads: [(albumId: String, entry: LibraryStore.ProgressEntry)] {
        _ = library.progressTick   // refresh after a reader closes
        return library.progress
            .map { (albumId: $0.key, entry: $0.value) }
            .sorted { $0.entry.updatedAt > $1.entry.updatedAt }
            .prefix(10).map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                content
            }
            .navigationTitle("书架")
            .fullScreenCover(item: $readerRoute) { route in
                ReaderView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Label("导入", systemImage: "plus") }
                }
            }
            .overlay {
                if shelf.isImporting {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("导入中…").font(.subheadline)
                        }
                        .padding(22)
                        .glassSurface(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType.data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    Task {
                        let r = await shelf.importFiles(urls)
                        var parts: [String] = []
                        if !r.added.isEmpty { parts.append("已导入 \(r.added.count) 本") }
                        if !r.failed.isEmpty { parts.append("失败：\(r.failed.joined(separator: "、"))") }
                        note = parts.joined(separator: "\n")
                    }
                }
            }
            .alert("导入结果", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
                Button("好", role: .cancel) { note = nil }
            } message: {
                Text(note ?? "")
            }
            .confirmationDialog(
                pendingDelete.map { "删除《\($0.title)》？" } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除文件", role: .destructive) {
                    if let b = pendingDelete { shelf.delete(b) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("导入的文件删除后无法恢复。")
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(selected ? .bold : .regular)
                .foregroundColor(selected ? .white : .primary)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background { if selected { Capsule().fill(accentPink) } }
                .glassSurface(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("来源", selection: $segment) {
                Text("全部").tag(0)
                Text("下载").tag(1)
                Text("导入").tag(2)
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if segment == 1 {
                        chip("全部", selected: dlCategory == "__all__") { dlCategory = "__all__" }
                        ForEach(downloadCategories, id: \.self) { cat in
                            chip(cat, selected: dlCategory == cat) { dlCategory = cat }
                        }
                        if hasUncategorizedDownloads {
                            chip("未分类", selected: dlCategory == "__none__") { dlCategory = "__none__" }
                        }
                    } else {
                        chip("全部", selected: typeFilter == 0) { typeFilter = 0 }
                        chip("漫画", selected: typeFilter == 1) { typeFilter = 1 }
                        chip("小说", selected: typeFilter == 2) { typeFilter = 2 }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        let items = allItems
        let reads = (segment == 0 && typeFilter == 0) ? recentReads : []
        if items.isEmpty && reads.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 44)).foregroundColor(.secondary)
                Text(emptyTitle).font(.headline)
                Text(emptyHint)
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !reads.isEmpty {
                        Text("最近阅读").font(.headline)
                            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(reads, id: \.albumId) { read in
                                    Button {
                                        readerRoute = ReaderRoute(
                                            albumId: read.albumId,
                                            albumName: read.entry.albumName ?? "",
                                            chapters: [],
                                            startChapterId: read.entry.chapterId,
                                            startPage: read.entry.page)
                                    } label: {
                                        recentReadCell(read)
                                    }
                                    .buttonStyle(.plain)
                                    .modifier(RailCellEffect())
                                }
                            }
                            .padding(.horizontal, 16)
                            .modifier(TargetLayoutIfAvailable())
                        }
                        .padding(.bottom, 10)
                    }
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 26)).foregroundColor(accentPink)
                            Text("书架上还没有本地的书").font(.subheadline).fontWeight(.semibold)
                            Text("下载的漫画会出现在这里\n也可以导入自己的漫画和小说文件")
                                .font(.caption).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button { showImporter = true } label: {
                                Text("导入文件")
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                    .background(Capsule().fill(accentPink))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22).padding(.horizontal, 18)
                        .glassSurface(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16).padding(.top, 24)
                    }
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(items) { item in
                            NavigationLink { destination(for: item) } label: {
                                cell(item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                switch item {
                                case .download(let r):
                                    Button(role: .destructive) {
                                        downloads.store.delete(r)
                                    } label: { Label("删除下载", systemImage: "trash") }
                                case .local(let b):
                                    Button(role: .destructive) {
                                        pendingDelete = b
                                    } label: { Label("删除文件", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 16)
                }
            }
            .tabMinimizeOnScroll()
        }
    }

    private var emptyTitle: String {
        switch segment {
        case 1: return "还没有下载的书"
        case 2: return "还没有导入的书"
        default: return "书架还是空的"
        }
    }

    private var emptyHint: String {
        switch segment {
        case 1: return "在漫画详情页下载的书会出现在这里"
        case 2: return "点右上角导入自己的漫画或小说\n支持 CBZ / ZIP / PDF / EPUB / TXT"
        default: return "下载的书和导入的漫画、小说都会放在这里"
        }
    }

    @ViewBuilder
    private func destination(for item: ShelfItem) -> some View {
        switch item {
        case .download(let r):
            LocalPdfView(url: r.fileURL, title: r.title)
        case .local(let b):
            localDestination(b)
        }
    }

    @ViewBuilder
    private func localDestination(_ book: LocalBook) -> some View {
        switch book.kind {
        case .comic: LocalComicReaderView(book: book)
        case .pdf: LocalPdfView(url: shelf.fileURL(book, book.sourceName), title: book.title)
        case .novel: NovelReaderView(book: book)
        }
    }

    @ViewBuilder
    private func cell(_ item: ShelfItem) -> some View {
        switch item {
        case .download(let r): DownloadCell(record: r)
        case .local(let b): LocalBookCell(book: b)
        }
    }

    private func recentReadCell(_ read: (albumId: String, entry: LibraryStore.ProgressEntry)) -> some View {
        RemoteImage(path: ImagePipe.coverPath(albumId: read.albumId))
            .aspectRatio(3 / 4, contentMode: .fill)
            .frame(width: 96, height: 128)
            .clipped()
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }

    @ViewBuilder
    private func destination(for item: ShelfItem) -> some View {
        switch item {
        case .download(let r):
            LocalPdfView(url: r.fileURL, title: r.title)
        case .local(let b):
            localDestination(b)
        }
    }

    @ViewBuilder
    private func localDestination(_ book: LocalBook) -> some View {
        switch book.kind {
        case .comic: LocalComicReaderView(book: book)
        case .pdf: LocalPdfView(url: shelf.fileURL(book, book.sourceName), title: book.title)
        case .novel: NovelReaderView(book: book)
        }
    }

    @ViewBuilder
    private func cell(_ item: ShelfItem) -> some View {
        switch item {
        case .download(let r): DownloadCell(record: r)
        case .local(let b): LocalBookCell(book: b)
        }
    }

    private func progressText(_ e: LibraryStore.ProgressEntry) -> String {
        let ch = e.chapterName
        if ch.isEmpty || ch == (e.albumName ?? "") { return "看到第 \(e.page + 1) 页" }
        return "\(ch) · 第 \(e.page + 1) 页"
    }

    private func recentReadCell(_ read: (albumId: String, entry: LibraryStore.ProgressEntry)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(path: ImagePipe.coverPath(albumId: read.albumId))
                .aspectRatio(3 / 4, contentMode: .fill)
                .frame(width: 84, height: 112)
                .clipped()
                .cornerRadius(8)
            Text(read.entry.albumName ?? "").font(.caption2).lineLimit(2).frame(width: 84, alignment: .leading)
            Text(progressText(read.entry))
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cover(_ item: ShelfItem) -> some View {
        switch item {
        case .download(let r):
            RemoteImage(path: ImagePipe.coverPath(albumId: r.albumId))
        case .local(let b):
            if let rel = b.coverRel {
                LocalThumbView(url: shelf.fileURL(b, rel))
            } else {
                ZStack {
                    Rectangle().fill(LinearGradient(colors: [accentPink.opacity(0.75), accentBlue.opacity(0.75)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: b.kind == .novel ? "text.book.closed" : "photo")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

private struct DownloadCell: View {
    let record: DownloadedRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(path: ImagePipe.coverPath(albumId: record.albumId))
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(record.title).font(.caption).fontWeight(.medium).lineLimit(2)
            Text(record.chapters > 1 ? "下载 · \(record.chapters) 章" : "下载 · \(record.pages) 页")
                .font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

private struct LocalBookCell: View {
    let book: LocalBook
    @EnvironmentObject var shelf: LocalBookStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let rel = book.coverRel {
                    LocalThumbView(url: shelf.fileURL(book, rel))
                } else {
                    ZStack {
                        Rectangle().fill(LinearGradient(colors: [accentPink.opacity(0.75), accentBlue.opacity(0.75)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(spacing: 6) {
                            Image(systemName: book.kind == .novel ? "text.book.closed" : "photo")
                                .font(.system(size: 22)).foregroundColor(.white)
                            Text(book.title).font(.caption2).foregroundColor(.white)
                                .lineLimit(3).multilineTextAlignment(.center).padding(.horizontal, 6)
                        }
                    }
                }
                Text(formatBadge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(5)
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(book.title).font(.caption).fontWeight(.medium).lineLimit(2)
            Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private var formatBadge: String {
        let ext = (book.sourceName as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        switch book.kind {
        case .comic: return "CBZ"
        case .pdf: return "PDF"
        case .novel: return "TXT"
        }
    }

    private var subtitle: String {
        _ = shelf.progressTick   // refresh progress text when a reader closes
        switch book.kind {
        case .comic:
            let p = shelf.lastPage(book)
            return p > 0 ? "看到第 \(p + 1) / \(book.pageFiles.count) 页" : "漫画 · \(book.pageFiles.count) 页"
        case .pdf:
            return book.pageCount > 0 ? "PDF · \(book.pageCount) 页" : "PDF"
        case .novel:
            let c = shelf.lastChapter(book)
            return c > 0 ? "看到第 \(c + 1) / \(book.chapterTitles.count) 章" : "小说 · \(book.chapterTitles.count) 章"
        }
    }
}

// MARK: - local comic reader (vertical continuous scroll over extracted pages)

struct LocalComicReaderView: View {
    let book: LocalBook
    @EnvironmentObject var shelf: LocalBookStore
    @State private var current = 0
    @State private var restored = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(book.pageFiles.enumerated()), id: \.offset) { idx, name in
                        LocalPageView(url: shelf.fileURL(book, "pages/\(name)"))
                            .id(idx)
                            .onAppear {
                                current = idx
                                shelf.saveProgress(bookId: book.id, page: idx)
                                if !restored {
                                    restored = true
                                    let target = shelf.lastPage(book)
                                    if target > 0 { proxy.scrollTo(target, anchor: .top) }
                                }
                            }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !book.pageFiles.isEmpty {
                    Text("\(current + 1) / \(book.pageFiles.count)")
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassSurface(Capsule())
                        .padding(.bottom, 10)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { shelf.noteReaderClosed() }
    }
}

private struct LocalPageView: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color(white: 0.12))
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(ProgressView().tint(.gray))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: url.path) {
            let loaded = await Task.detached(priority: .userInitiated) {
                LocalImageLoader.thumbnail(url, maxPixel: 1600)
            }.value
            if let loaded { image = loaded }
        }
    }
}

// MARK: - novel reader (TXT / EPUB chapters as plain text)

struct NovelReaderView: View {
    let book: LocalBook
    @EnvironmentObject var shelf: LocalBookStore
    @State private var chapters: [NovelChapter] = []
    @State private var idx = 0
    @State private var showToc = false
    @AppStorage("jm.novelFontSize") private var fontSize: Double = 18

    var body: some View {
        Group {
            if chapters.isEmpty {
                ProgressView("加载中…")
            } else {
                let ch = chapters[min(idx, chapters.count - 1)]
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(ch.title).font(.title3).fontWeight(.bold)
                        Text(ch.text)
                            .font(.system(size: fontSize))
                            .lineSpacing(7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 16)
                }
                .id(idx)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        Button("上一章") { idx = max(0, idx - 1) }
                            .disabled(idx <= 0)
                        Spacer()
                        Button("目录") { showToc = true }
                        Spacer()
                        Button("下一章") { idx = min(chapters.count - 1, idx + 1) }
                            .disabled(idx >= chapters.count - 1)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { fontSize = max(14, fontSize - 1) } label: { Label("减小字号", systemImage: "textformat.size.smaller") }
                    Button { fontSize = min(26, fontSize + 1) } label: { Label("增大字号", systemImage: "textformat.size.larger") }
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .sheet(isPresented: $showToc) {
            NavigationStack {
                List(Array(chapters.enumerated()), id: \.offset) { i, ch in
                    Button {
                        idx = i
                        showToc = false
                    } label: {
                        HStack {
                            Text(ch.title).lineLimit(1)
                            Spacer()
                            if i == idx { Image(systemName: "checkmark").foregroundColor(accentPink) }
                        }
                    }
                    .foregroundColor(.primary)
                }
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if chapters.isEmpty {
                let loaded = shelf.novelChapters(book)
                chapters = loaded
                idx = min(shelf.lastChapter(book), max(0, loaded.count - 1))
            }
        }
        .onChange(of: idx) { new in shelf.saveProgress(bookId: book.id, chapter: new) }
        .onDisappear { shelf.noteReaderClosed() }
    }
}
