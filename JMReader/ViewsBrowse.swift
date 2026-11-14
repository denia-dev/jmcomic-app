import SwiftUI

let accentPink = Color(red: 1.0, green: 0.18, blue: 0.533)

// MARK: - shared bits

struct RemoteImage: View {
    let path: String
    var scrambleNum: Int = 0
    var targetWidth: CGFloat = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.07))
                    .overlay(ProgressView().tint(.gray))
            }
        }
        .task(id: path) {
            image = await ImagePipe.shared.load(path: path, scrambleNum: scrambleNum, targetWidth: targetWidth)
        }
    }
}

struct ComicCell: View {
    let comic: Comic
    var columns: Int = 2
    /// Batch-select mode (favorites): shows a check badge on the cover.
    var selecting: Bool = false
    var selected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(path: ImagePipe.coverPath(albumId: comic.id), targetWidth: 400)
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipped()
                .cornerRadius(columns >= 4 ? 7 : 10)
                .overlay(alignment: .topLeading) {
                    if columns <= 3 && !comic.categoryTitle.isEmpty {
                        Text(comic.categoryTitle)
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.55)).foregroundColor(.white)
                            .cornerRadius(5).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(selected ? accentPink : .white)
                            .shadow(color: .black.opacity(0.45), radius: 3)
                            .padding(6)
                    }
                }
            Text(comic.name)
                .font(columns >= 4 ? .caption2 : (columns == 3 ? .caption : .subheadline))
                .fontWeight(.semibold)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
            if columns <= 3 {
                Text(comic.author)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).padding(.top, 2)
            }
        }
    }
}

struct ComicGrid: View {
    let items: [Comic]
    var columnsOverride: Int? = nil
    var applyBlockFilter = false
    var onLastAppear: (() -> Void)? = nil
    /// When set, cells get a "移动到收藏夹" context menu (cloud favorites only).
    var folders: [FavFolder] = []
    var onMoveToFolder: ((Comic, String) -> Void)? = nil
    /// Batch-select mode: cells toggle selection instead of navigating.
    var selecting: Bool = false
    var selectedIds: Set<String> = []
    var onToggleSelect: ((Comic) -> Void)? = nil
    /// Open details through direct-destination links instead of value
    /// routing. Used by the author page, whose grid sits one level deeper
    /// (inside a directly-pushed view carrying its own destination
    /// registrations); value routing misbehaved there on device.
    var directDetailLinks = false
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var blockStore: BlockTagStore

    var body: some View {
        let cols = columnsOverride ?? appState.gridColumns
        let shown = applyBlockFilter ? blockStore.visible(items) : items
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: cols >= 4 ? 8 : 13), count: cols),
                  spacing: cols >= 4 ? 12 : 18) {
            ForEach(shown) { comic in
                if selecting {
                    Button { onToggleSelect?(comic) } label: {
                        ComicCell(comic: comic, columns: cols,
                                  selecting: true, selected: selectedIds.contains(comic.id))
                    }
                    .buttonStyle(.plain)
                    .onAppear { if comic.id == shown.last?.id { onLastAppear?() } }
                } else if directDetailLinks {
                    NavigationLink { DetailView(albumId: comic.id) } label: {
                        ComicCell(comic: comic, columns: cols)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if comic.id == shown.last?.id { onLastAppear?() } }
                } else {
                    NavigationLink(value: comic.id) { ComicCell(comic: comic, columns: cols) }
                        .buttonStyle(.plain)
                        .onAppear { if comic.id == shown.last?.id { onLastAppear?() } }
                        .contextMenu {
                            if let onMoveToFolder, !folders.isEmpty {
                                Menu("移动到收藏夹") {
                                    ForEach(folders) { f in
                                        Button(f.name) { onMoveToFolder(comic, f.id) }
                                    }
                                }
                            }
                        }
                }
            }
        }
        .padding(.horizontal, cols >= 4 ? 10 : 14)
        .task(id: applyBlockFilter ? items.map(\.id).joined(separator: ",") : "") {
            if applyBlockFilter { blockStore.prefetch(items) }
        }
        .onAppear {
            // A whole page filtered away: keep paging so the grid can fill.
            if applyBlockFilter && shown.isEmpty && !items.isEmpty { onLastAppear?() }
        }
    }
}

struct ColumnButton: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        Button {
            appState.cycleColumns()
        } label: {
            Text("\(appState.gridColumns)列")
                .font(.subheadline).fontWeight(.semibold)
        }
    }
}

extension View {
    func withDestinations() -> some View {
        self
            .navigationDestination(for: String.self) { DetailView(albumId: $0) }
            .navigationDestination(for: JMCategory.self) { CategoryListView(category: $0) }
    }
}

// MARK: - home (channels)

enum HomeChannel: Identifiable, Equatable {
    case recommend, latest, ai
    case category(JMCategory)
    var id: String {
        switch self {
        case .recommend: return "recommend"
        case .latest: return "latest"
        case .ai: return "ai"
        case .category(let c): return "cat-\(c.slug)"
        }
    }
    var title: String {
        switch self {
        case .recommend: return "推荐"
        case .latest: return "最新"
        case .ai: return "AI生成"
        case .category(let c): return c.name
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloads: DownloadManager
    @State private var cats: [JMCategory] = []
    @State private var channel: HomeChannel = .recommend

    private var channels: [HomeChannel] {
        [.recommend, .latest, .ai] + cats.map { .category($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                channelStrip
                Group {
                    switch channel {
                    case .recommend:
                        RecommendView()
                    case .latest:
                        FeedView(source: .latest)
                    case .ai:
                        FeedView(source: .tagSearch("AI生成"))
                    case .category(let cat):
                        FeedView(source: .category(cat.slug))
                    }
                }
                .id(channel.id)
            }
            .toolbar(.hidden, for: .navigationBar)
                                    .withDestinations()
        }
        .task {
            if cats.isEmpty {
                if let list = try? await JMClient.shared.categories() { cats = list }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                appState.selectedTab = 3
            } label: {
                Image("AvatarArt")
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                appState.goSearch()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索").foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassSurface(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            NavigationLink {
                DownloadsView(embedded: true)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 19))
                        .padding(9)
                        .glassSurface(Circle(), interactive: true)
                    if downloads.jobs.contains(where: { $0.state == .working || $0.state == .queued }) {
                        Circle().fill(accentPink).frame(width: 9, height: 9).offset(x: 1, y: -1)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    private var channelStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(channels) { ch in
                        Button {
                            channel = ch
                        } label: {
                            Text(ch.title)
                                .font(.subheadline)
                                .fontWeight(channel == ch ? .bold : .regular)
                                .foregroundColor(channel == ch ? .white : .primary)
                                .padding(.horizontal, 13).padding(.vertical, 6)
                                .background {
                                    if channel == ch {
                                        Capsule().fill(accentPink)
                                    }
                                }
                                .glassSurface(Capsule(), interactive: true)
                                .opacity(channel == ch ? 1 : 0.92)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
        .padding(.bottom, 4)
    }
}

/// Paginated comic feed used by the Latest / Category / AI home channels.
struct FeedView: View {
    enum Source { case latest, category(String), tagSearch(String) }
    let source: Source
    @State private var items: [Comic] = []
    @State private var page = 0
    @State private var total = Int.max
    @State private var loading = false
    @State private var reachedEnd = false

    var body: some View {
        Group {
            if items.isEmpty && loading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ComicGrid(items: items, applyBlockFilter: true) { Task { await loadMore() } }
                        .padding(.top, 8)
                    if loading { ProgressView().padding() }
                    if !loading && items.isEmpty {
                        Text("暂时没内容").foregroundColor(.secondary).padding(.top, 40)
                    }
                }
                .tabMinimizeOnScroll()
                .refreshable { page = 0; reachedEnd = false; total = Int.max; await loadMore(reset: true) }
            }
        }
        .task { if items.isEmpty { await loadMore(reset: true) } }
    }

    private func loadMore(reset: Bool = false) async {
        guard !loading, !reachedEnd else { return }
        if !items.isEmpty && items.count >= total { reachedEnd = true; return }
        loading = true
        defer { loading = false }
        do {
            let res: (total: Int, items: [Comic], redirectAid: String?)
            switch source {
            case .latest:
                let list = try await JMClient.shared.latest(page: page + 1)
                res = (Int.max, list, nil)
            case .category(let slug):
                let cf = try await JMClient.shared.categoryFilter(slug: slug, page: page + 1)
                res = (cf.total, cf.items, nil)
            case .tagSearch(let q):
                res = try await JMClient.shared.search(query: q, page: page + 1)
            }
            total = res.total
            if res.items.isEmpty { reachedEnd = true; return }
            page += 1
            items = reset ? res.items : items + res.items
        } catch {
            reachedEnd = true
        }
    }
}

/// Recommend channel: curated shelves from `promote` + a random-recommend grid.
struct RecommendView: View {
    @State private var sections: [PromoSection] = []
    @State private var randoms: [Comic] = []
    @State private var loading = false

    var body: some View {
        Group {
            if sections.isEmpty && loading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sections) { sec in
                            ShelfRow(section: sec)
                        }
                        if !randoms.isEmpty {
                            Text("随机推荐")
                                .font(.headline)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                            ComicGrid(items: randoms, columnsOverride: 2, applyBlockFilter: true)
                        }
                        if sections.isEmpty && randoms.isEmpty && !loading {
                            Text("暂时没内容").foregroundColor(.secondary).padding(30)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .tabMinimizeOnScroll()
                .refreshable { await load() }
            }
        }
        .task { if sections.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let all = (try? await JMClient.shared.promote()) ?? sections
        sections = all.filter { !$0.title.contains("連載更新") && !$0.title.contains("连载更新") }
        randoms = await loadRandoms()
    }

    /// The server's `random_recommend` returns the same ~30 newest albums
    /// shuffled on every call (verified live 2026-11-14: three calls, one
    /// identical id set), so refreshing never surfaced anything new. Build
    /// our own pool instead: a random window of the latest feed (80 per
    /// page), deduped and shuffled; each load picks a fresh window, so
    /// pull-to-refresh actually re-rolls. Falls back to the server list
    /// when the feed cannot be read at all.
    private func loadRandoms() async -> [Comic] {
        let start = Int.random(in: 1...24)
        var pool: [Comic] = []
        var seen = Set<String>()
        for page in start..<(start + 3) {
            guard let items = try? await JMClient.shared.latest(page: page) else { break }
            for c in items where seen.insert(c.id).inserted { pool.append(c) }
        }
        if pool.isEmpty { return (try? await JMClient.shared.randomRecommend()) ?? randoms }
        return Array(pool.shuffled().prefix(36))
    }
}

struct ShelfRow: View {
    let section: PromoSection
    @EnvironmentObject var blockStore: BlockTagStore
    var body: some View {
        let shown = blockStore.visible(section.items)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title)
                    .font(.headline)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(shown) { comic in
                            NavigationLink(value: comic.id) {
                                ComicCell(comic: comic, columns: 3)
                                    .frame(width: 102)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
            .task(id: section.items.map(\.id).joined(separator: ",")) {
                blockStore.prefetch(section.items)
            }
        }
    }
}

// MARK: - categories

struct CategoriesView: View {
    @EnvironmentObject var appState: AppState
    @State private var cats: [JMCategory] = []
    @State private var loading = false
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if cats.isEmpty && loading {
                    ProgressView("加载中…")
                } else if loadFailed && cats.isEmpty {
                    VStack(spacing: 12) {
                        Text("分类加载失败").font(.headline)
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    List(cats) { cat in
                        NavigationLink(value: cat) {
                            HStack {
                                Text(cat.name).font(.headline)
                                Spacer()
                                Text("\(cat.totalAlbums) 本").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                    .tabMinimizeOnScroll()
                    .refreshable { await load() }
                }
            }
            .navigationTitle("分类")
                                    .withDestinations()
        }
        .task { if cats.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { cats = try await JMClient.shared.categories(); loadFailed = false }
        catch { loadFailed = true }
    }
}

struct CategoryListView: View {
    let category: JMCategory
    @State private var items: [Comic] = []
    @State private var page = 0
    @State private var loading = false
    @State private var reachedEnd = false

    var body: some View {
        Group {
            if items.isEmpty && loading {
                ProgressView("加载中…")
            } else {
                ScrollView {
                    ComicGrid(items: items, applyBlockFilter: true) { Task { await loadMore() } }
                        .padding(.top, 10)
                    if loading { ProgressView().padding() }
                    if !loading && items.isEmpty {
                        Text("这个分类暂时没内容").foregroundColor(.secondary).padding(.top, 40)
                    }
                }
                .tabMinimizeOnScroll()
                .refreshable { page = 0; reachedEnd = false; await loadMore(reset: true) }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ColumnButton() } }
        .task { if items.isEmpty { await loadMore(reset: true) } }
    }

    private func loadMore(reset: Bool = false) async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await JMClient.shared.categoryFilter(slug: category.slug, page: page + 1)
            if res.items.isEmpty { reachedEnd = true; return }
            page += 1
            items = reset ? res.items : items + res.items
        } catch { reachedEnd = true }
    }
}

// MARK: - search

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var history: SearchHistory
    @State private var query: String = ""
    @State private var items: [Comic] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = false
    @State private var searched = false
    @State private var doujinItems: [Comic] = []
    @State private var doujinLoading = false
    @State private var searchOrder = "mr"
    @State private var searchMainTag = 0
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("搜漫画名、作者、标签", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { runSearch(query) }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.white.opacity(0.08)).cornerRadius(10)
                    Button("搜索") { runSearch(query) }.fontWeight(.semibold)
                }
                .padding(12)

                VStack(spacing: 6) {
                    chipRow(label: "类型",
                            options: [(0, "全部"), (1, "作品"), (2, "作者"), (3, "标签"), (4, "人物")],
                            selection: $searchMainTag)
                    chipRow(label: "排序",
                            options: [("mr", "最新"), ("mv", "最多观看"), ("tf", "最多爱心"), ("mp", "最多图片")],
                            selection: $searchOrder)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                if !searched && items.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            historyView
                            if !doujinItems.isEmpty {
                                Text("同人推荐").font(.headline)
                                    .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
                                ComicGrid(items: doujinItems, applyBlockFilter: true)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .tabMinimizeOnScroll()
                    .refreshable { await loadDoujin(reroll: true) }
                    .task { await loadDoujin() }
                } else {
                    ScrollView {
                        if searched && !loading {
                            Text("共 \(total) 本").font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                        }
                        ComicGrid(items: items, applyBlockFilter: true) { Task { await loadMore() } }
                            .padding(.top, 4)
                        if loading { ProgressView().padding() }
                        if searched && !loading && items.isEmpty {
                            Text("没搜到，换个词试试").foregroundColor(.secondary).padding(.top, 40)
                        }
                    }
                    .tabMinimizeOnScroll()
                }
            }
            .navigationTitle("搜索")
                                    .toolbar { ToolbarItem(placement: .topBarTrailing) { ColumnButton() } }
                        .withDestinations()
        }
        .onChange(of: appState.searchFocusToken) { _ in focused = true }
        .onChange(of: searchOrder) { _ in if searched { runSearch(query) } }
        .onChange(of: searchMainTag) { _ in if searched { runSearch(query) } }
        .onAppear {
            if let pending = appState.pendingSearch {
                appState.pendingSearch = nil
                query = pending
                runSearch(pending)
            }
        }
    }

    private func loadDoujin(reroll: Bool = false) async {
        // The recommendations used to vanish intermittently: a single failed
        // (or .task-cancelled) fetch left doujinItems empty with no retry.
        // Retry with backoff and only assign on success.
        // They also never changed: the fetch was pinned to page 1 and ran
        // once per view lifetime. Each load now draws a random page of the
        // doujin category (80 per page, thousands of pages), and the search
        // page's pull-to-refresh re-rolls it. A failed re-roll keeps the
        // previous list.
        if doujinLoading { return }
        if !reroll && !doujinItems.isEmpty { return }
        doujinLoading = true
        defer { doujinLoading = false }
        let page = Int.random(in: 1...60)
        for attempt in 0..<3 {
            if Task.isCancelled { return }
            if let res = try? await JMClient.shared.categoryFilter(slug: "doujin", page: page),
               !res.items.isEmpty {
                doujinItems = res.items
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
        }
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !history.items.isEmpty {
                HStack {
                    Text("搜索历史").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Button("清除") { history.clear() }.font(.caption)
                }
                FlowChips(items: history.items) { runSearch($0) }
            } else {
                Text("输入关键词开始搜索").foregroundColor(.secondary).padding(.top, 30)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runSearch(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        history.add(q)
        query = q
        page = 0; items = []; total = 0; searched = true
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard !loading else { return }
        if !items.isEmpty && items.count >= total && total > 0 { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await JMClient.shared.search(query: query, page: page + 1,
                                                       order: searchOrder, mainTag: searchMainTag)
            total = res.total
            page += 1
            if page == 1, let aid = res.redirectAid,
               let detail = try? await JMClient.shared.album(id: aid) {
                // JM id ("车牌号") search: the API points straight at one album.
                items = [Comic(id: detail.id, name: detail.name,
                               author: detail.authors.first ?? "")]
                total = 1
                return
            }
            items += res.items
        } catch { /* keep what we have */ }
    }

    private func chipRow<V: Hashable>(label: String, options: [(V, String)],
                                      selection: Binding<V>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options.indices, id: \.self) { i in
                        let opt = options[i]
                        Button {
                            selection.wrappedValue = opt.0
                        } label: {
                            Text(opt.1)
                                .font(.caption.weight(selection.wrappedValue == opt.0 ? .bold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(selection.wrappedValue == opt.0 ? accentPink : Color.white.opacity(0.08))
                                .foregroundColor(selection.wrappedValue == opt.0 ? .white : .primary)
                                .cornerRadius(13)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct FlowChips: View {
    let items: [String]
    var actionTitle: String? = nil
    var onAction: ((String) -> Void)? = nil
    var onTap: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { onTap(s) } label: {
                    Text(s).font(.subheadline).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08)).cornerRadius(16)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let actionTitle, let onAction {
                        Button(role: .destructive) { onAction(s) } label: {
                            Label(actionTitle, systemImage: "eye.slash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - blocked tags management

struct BlockedTagsView: View {
    @EnvironmentObject var blockStore: BlockTagStore
    @State private var newTag = ""
    @State private var newAuthor = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("作者").font(.headline)
                HStack(spacing: 8) {
                    TextField("输入要屏蔽的作者", text: $newAuthor)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(0.08)).cornerRadius(10)
                        .onSubmit { addNewAuthor() }
                    Button("添加") { addNewAuthor() }
                        .fontWeight(.semibold)
                        .disabled(newAuthor.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if blockStore.blockedAuthors.isEmpty {
                    Text("还没有屏蔽任何作者。在漫画详情页长按作者也可以快速屏蔽。")
                        .foregroundColor(.secondary)
                } else {
                    Text("长按可取消屏蔽").font(.caption).foregroundColor(.secondary)
                    FlowChips(items: blockStore.blockedAuthors,
                              actionTitle: "取消屏蔽",
                              onAction: { blockStore.removeAuthor($0) }) { _ in }
                }
                Text("标签").font(.headline).padding(.top, 8)
                HStack(spacing: 8) {
                    TextField("输入要屏蔽的标签", text: $newTag)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(0.08)).cornerRadius(10)
                        .onSubmit { addNew() }
                    Button("添加") { addNew() }
                        .fontWeight(.semibold)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if blockStore.blockedTags.isEmpty {
                    Text("还没有屏蔽任何标签。在漫画详情页长按标签也可以快速屏蔽。")
                        .foregroundColor(.secondary)
                } else {
                    Text("长按标签可取消屏蔽").font(.caption).foregroundColor(.secondary)
                    FlowChips(items: blockStore.blockedTags,
                              actionTitle: "取消屏蔽",
                              onAction: { blockStore.remove($0) }) { _ in }
                }
                Text("在首页、分类、搜索等列表中，作者命中屏蔽名单、或标题/作者/真实标签含屏蔽词的作品会直接隐藏；作品的作者与标签会随着浏览自动记录。收藏与历史不受影响。")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .tabMinimizeOnScroll()
        .navigationTitle("屏蔽标签与作者")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addNew() {
        blockStore.add(newTag)
        newTag = ""
    }

    private func addNewAuthor() {
        blockStore.addAuthor(newAuthor)
        newAuthor = ""
    }
}

// MARK: - login

struct LoginView: View {
    @EnvironmentObject var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var password: String = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                if let errorText {
                    Section { Text(errorText).foregroundColor(.red).font(.subheadline) }
                }
                Section {
                    Button {
                        Task { await doLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("登录").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(busy || name.isEmpty || password.isEmpty)
                }
                Section {
                    Text("登录后可同步账号收藏。密码只保存在这台手机的钥匙串里，不经过任何服务器中转。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func doLogin() async {
        busy = true
        errorText = nil
        do {
            try await account.signIn(username: name.trimmingCharacters(in: .whitespaces),
                                     password: password)
            dismiss()
        } catch let e as JMError {
            if case .server(let msg) = e { errorText = msg }
            else { errorText = "登录失败，检查网络后再试" }
        } catch {
            errorText = "登录失败，检查网络后再试"
        }
        busy = false
    }
}

// MARK: - favorites (local + account)

struct FavoritesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var blockStore: BlockTagStore
    @EnvironmentObject var downloads: DownloadManager
    @State private var showLogin = false
    @State private var selecting = false
    @State private var selectedIds: Set<String> = []
    @State private var favQuery = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderToDelete: FavFolder?
    // Render window for the cloud grid: the whole favorites list lives in
    // memory, but building all ~1000 cells the moment the profile page
    // opens (nested grid inside a VStack scroll view can go eager, and a
    // cold start is already busy with the home feed) froze the page on
    // entry. Only the first window of cells is built; scrolling grows it.
    @State private var cloudRenderLimit = 60
    @AppStorage("jm.favSortNewest") private var sortNewest = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    accountHeader
                    ProfileStatsCard()
                    CheckinCard()
                    ReadingStatsCard()
                    historyEntry
                    favControls
                    if account.isLoggedIn {
                        folderChips
                        sectionTitle("账号收藏")
                        if shownCloud.isEmpty && !account.cloudLoading {
                            Text(favQuery.isEmpty ? "这个收藏夹还没有收藏" : "没有匹配的收藏").foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                        } else {
                            ComicGrid(items: shownCloudWindow,
                                      onLastAppear: {
                                          if cloudRenderLimit < shownCloud.count {
                                              cloudRenderLimit += 60
                                          } else {
                                              Task { await account.loadCloudPage() }
                                          }
                                      },
                                      folders: account.displayFolders,
                                      onMoveToFolder: { comic, fid in
                                          Task { await account.moveFavorite(aid: comic.id, toFolder: fid) }
                                      },
                                      selecting: selecting,
                                      selectedIds: selectedIds,
                                      onToggleSelect: { comic in
                                          if selectedIds.contains(comic.id) {
                                              selectedIds.remove(comic.id)
                                          } else {
                                              selectedIds.insert(comic.id)
                                          }
                                      })
                        }
                        if account.cloudLoading { ProgressView().padding() }
                    }
                    if !shownLocal.isEmpty {
                        sectionTitle(account.isLoggedIn ? "本地收藏" : "收藏")
                        ComicGrid(items: shownLocal)
                    } else if !favQuery.isEmpty {
                        Text("没有匹配的收藏").foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.top, 10)
                    } else if !account.isLoggedIn {
                        VStack(spacing: 10) {
                            Image(systemName: "star").font(.largeTitle).foregroundColor(.secondary)
                            Text("还没有收藏").foregroundColor(.secondary)
                            Text("在详情页点右上角的星星就能收藏").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 50)
                    }
                }
                .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { batchBar }
            }
            .tabMinimizeOnScroll()
            .navigationTitle("个人")
                                    .toolbar {
                                        ToolbarItem(placement: .topBarTrailing) {
                                            HStack(spacing: 14) {
                                                ColumnButton()
                                                NavigationLink {
                                                    SettingsView()
                                                } label: {
                                                    Image(systemName: "gearshape")
                                                }
                                            }
                                        }
                                    }
            .withDestinations()
            .sheet(isPresented: $showLogin) { LoginView() }
            .task(id: account.username) {
                await account.ensureCloudCache()
                if !sortNewest { await account.loadAllCloud() }
            }
            .task(id: sortNewest) {
                if !sortNewest { await account.loadAllCloud() }
            }
            .onChange(of: favQuery) { _ in cloudRenderLimit = 60 }
            .onChange(of: sortNewest) { _ in cloudRenderLimit = 60 }
            .onChange(of: account.cloudFolderId) { _ in cloudRenderLimit = 60 }
        }
    }

    private var historyEntry: some View {
        NavigationLink {
            HistoryView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(accentPink)
                Text("观看历史").foregroundColor(.primary)
                Spacer()
                if !library.progress.isEmpty {
                    Text("\(library.progress.count) 本")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchesQuery(_ c: Comic) -> Bool {
        favQuery.isEmpty
            || c.name.localizedCaseInsensitiveContains(favQuery)
            || c.author.localizedCaseInsensitiveContains(favQuery)
    }

    private var shownCloud: [Comic] {
        var r = account.displayedCloud.filter(matchesQuery)
        // 只在全部加载完后才反转，半截数据反转必然是乱的
        if !sortNewest && account.displayedCloudFullyLoaded { r.reverse() }
        return r
    }

    private var shownCloudWindow: [Comic] {
        Array(shownCloud.prefix(cloudRenderLimit))
    }

    private var shownLocal: [Comic] {
        library.favorites.filter(matchesQuery).sorted {
            sortNewest ? library.favDate(for: $0) > library.favDate(for: $1)
                       : library.favDate(for: $0) < library.favDate(for: $1)
        }
    }

    private var favControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                TextField("搜收藏（标题/作者）", text: $favQuery).font(.subheadline)
                if !favQuery.isEmpty {
                    Button { favQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glassSurface(Capsule(), interactive: true)
            Menu {
                Button(sortNewest ? "✓ 最近收藏" : "最近收藏") { sortNewest = true }
                Button(sortNewest ? "最早收藏" : "✓ 最早收藏") { sortNewest = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.caption)
                    Text(sortNewest ? "最近收藏" : "最早收藏").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassSurface(Capsule(), interactive: true)
            }
            if account.isLoggedIn {
                Button {
                    selecting.toggle()
                    if !selecting { selectedIds.removeAll() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle").font(.caption)
                        Text(selecting ? "取消批量" : "批量下载").font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassSurface(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14)
    }

    private var batchBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(selectedIds.count) 本")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("下载已选") { downloadSelected() }
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(selectedIds.isEmpty ? Color.gray : accentPink)
                .clipShape(Capsule())
                .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func downloadSelected() {
        for comic in shownCloud where selectedIds.contains(comic.id) {
            downloads.enqueue(albumId: comic.id, title: comic.name)
        }
        selecting = false
        selectedIds.removeAll()
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(account.displayFolders) { folder in
                    Button {
                        Task { await account.switchFolder(folder.id) }
                    } label: {
                        Text(folder.name)
                            .font(.subheadline.weight(account.cloudFolderId == folder.id ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(account.cloudFolderId == folder.id ? accentPink : Color.white.opacity(0.08))
                            .foregroundColor(account.cloudFolderId == folder.id ? .white : .primary)
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if folder.id != "0" {
                            Button(role: .destructive) { folderToDelete = folder } label: {
                                Label("删除收藏夹", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.caption.weight(.bold))
                        Text("新建").font(.subheadline)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(accentPink)
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .alert("新建收藏夹", isPresented: $showNewFolder) {
            TextField("收藏夹名称", text: $newFolderName)
            Button("创建") { Task { await account.createFolder(name: newFolderName) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除收藏夹「\(folderToDelete?.name ?? "")」？",
                            isPresented: Binding(get: { folderToDelete != nil },
                                                 set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let f = folderToDelete { Task { await account.deleteFolder(id: f.id) } }
                folderToDelete = nil
            }
            Button("取消", role: .cancel) { folderToDelete = nil }
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isLoggedIn ? "person.circle.fill" : "person.circle")
                .font(.title2).foregroundColor(account.isLoggedIn ? accentPink : .secondary)
            if account.isLoggedIn {
                Text(account.username ?? "").font(.headline)
                Spacer()
                Button("注销") { account.signOut() }.font(.subheadline)
            } else {
                Text("未登录").font(.headline)
                Spacer()
                Button("登录同步收藏") { showLogin = true }
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(accentPink)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .padding(.horizontal, 14).padding(.top, 12)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.headline)
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }

}

// MARK: - detail

struct DetailView: View {
    let albumId: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var account: AccountStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var blockStore: BlockTagStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AlbumDetail?
    @State private var loadFailed = false
    @State private var cloudFav: Bool = false
    @State private var favBusy = false
    @State private var tagsExpanded = false
    /// The reader is presented as a full-screen cover, NOT pushed onto the
    /// navigation stack: on iOS 27.3 pushing it from a deep stack left the
    /// stack's visual order one step behind (the reader ran underneath the
    /// detail/author views and only surfaced after they were popped).
    @State private var readerRoute: ReaderRoute?

    private var asComic: Comic? {
        guard let d = detail else { return nil }
        return Comic(id: d.id, name: d.name, author: d.authors.first ?? "")
    }

    private var isFav: Bool {
        account.isLoggedIn ? cloudFav : (asComic.map { library.isFavorite($0.id) } ?? false)
    }

    var body: some View {
        Group {
            if let d = detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(d)
                        Text(d.name).font(.title3).fontWeight(.bold)
                            .padding(.horizontal, 16).padding(.top, 12)
                        if !d.authors.isEmpty {
                            authorRow(d)
                        }
                        Text(metaLine(d)).font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.top, 5)
                        if !d.tags.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                FlowChips(items: tagsExpanded ? d.tags : Array(d.tags.prefix(8)),
                                          actionTitle: "屏蔽此标签",
                                          onAction: { blockStore.add($0) }) { appState.requestSearch($0) }
                                if d.tags.count > 8 {
                                    Button { withAnimation { tagsExpanded.toggle() } } label: {
                                        Text(tagsExpanded ? "收起标签" : "展开全部 \(d.tags.count) 个标签")
                                            .font(.caption.weight(.semibold)).foregroundColor(accentPink)
                                    }
                                }
                            }
                            .padding(.horizontal, 16).padding(.top, 12)
                        }
                        readButton(d)
                        downloadButton(d)
                        chapterList(d)
                        if !d.description.isEmpty {
                            Text(d.description).font(.subheadline).foregroundColor(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                    }
                }
            } else if loadFailed {
                VStack(spacing: 12) {
                    Text("加载失败").font(.headline)
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("加载中…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if asComic != nil, account.isLoggedIn {
                    Menu {
                        ForEach(account.displayFolders) { f in
                            Button {
                                Task { await favToFolder(f.id) }
                            } label: {
                                Label("收藏到「\(f.name)」", systemImage: "folder")
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .disabled(favBusy)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if asComic != nil {
                    Button {
                        Task { await toggleFav() }
                    } label: {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .foregroundColor(isFav ? accentPink : .primary)
                    }
                    .disabled(favBusy)
                }
            }
        }
        .swipeAnywhereBack { dismiss() }
        .fullScreenCover(item: $readerRoute) { route in
            ReaderView(route: route)
        }
        .task { if detail == nil { await load() } }
            }

    private func toggleFav() async {
        guard let comic = asComic else { return }
        if account.isLoggedIn {
            favBusy = true
            defer { favBusy = false }
            do {
                // Server-side toggle; trust its report over local state.
                let nowFav = try await JMClient.shared.toggleFavorite(albumId: comic.id)
                cloudFav = nowFav
                if nowFav { account.clearRemovedFav(comic.id) }
                else { account.applyCloudRemoval(aid: comic.id) }
            } catch { /* leave state */ }
        } else {
            library.toggleFavorite(comic)
        }
    }

    /// Favorite (or re-file) this album into a specific folder.
    private func favToFolder(_ folderId: String) async {
        guard let comic = asComic, account.isLoggedIn, !favBusy,
              !folderId.hasPrefix("pending-") else { return }
        favBusy = true
        defer { favBusy = false }
        do {
            if !cloudFav {
                var nowFav = try await JMClient.shared.toggleFavorite(albumId: comic.id)
                if !nowFav {
                    // Local state was stale (server already had it): the
                    // toggle removed it — toggle once more to re-add.
                    nowFav = try await JMClient.shared.toggleFavorite(albumId: comic.id)
                }
                cloudFav = nowFav
                if nowFav { account.clearRemovedFav(comic.id) }
                if folderId != "0" {
                    try await JMClient.shared.favoriteFolderMove(albumId: comic.id, folderId: folderId)
                }
            } else {
                try await JMClient.shared.favoriteFolderMove(albumId: comic.id, folderId: folderId)
            }
            await account.applyFolderMove(aid: comic.id, toFolder: folderId)
        } catch { /* leave state */ }
    }

    private func header(_ d: AlbumDetail) -> some View {
        ZStack {
            RemoteImage(path: ImagePipe.coverPath(albumId: d.id))
                .frame(height: 250).clipped().blur(radius: 24).opacity(0.55)
            RemoteImage(path: ImagePipe.coverPath(albumId: d.id))
                .frame(width: 150, height: 200).clipped().cornerRadius(10)
                .shadow(radius: 12)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private func authorRow(_ d: AlbumDetail) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("作者").font(.caption).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(d.authors, id: \.self) { a in
                        NavigationLink {
                            AuthorWorksView(author: a)
                        } label: {
                            Text(a)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(accentPink)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(accentPink.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { blockStore.addAuthor(a) } label: {
                                Label("屏蔽该作者", systemImage: "eye.slash")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 7)
    }

    private func metaLine(_ d: AlbumDetail) -> String {
        var parts: [String] = []
        if !d.totalViews.isEmpty { parts.append("浏览 \(d.totalViews)") }
        if !d.likes.isEmpty { parts.append("点赞 \(d.likes)") }
        if d.chapters.isEmpty { parts.append("共 \(d.totalPhotos) 页") }
        else { parts.append("共 \(d.chapters.count) 话") }
        return parts.joined(separator: " · ")
    }

    private func readButton(_ d: AlbumDetail) -> some View {
        let prog = library.progressFor(albumId: d.id)
        let targetChapter = prog?.chapterId ?? d.firstChapterId
        let targetPage = (prog != nil && prog!.chapterId == targetChapter) ? prog!.page : 0
        let route = ReaderRoute(albumId: d.id, albumName: d.name, chapters: d.chapters,
                                startChapterId: targetChapter, startPage: targetPage)
        return Button { readerRoute = route } label: {
            Text(prog == nil ? "开始阅读" : "继续阅读 · \(prog!.chapterName) 第\(prog!.page + 1)页")
                .font(.headline).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(accentPink).cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 16)
    }

    @ViewBuilder
    private func downloadButton(_ d: AlbumDetail) -> some View {
        if downloads.store.record(for: d.id) != nil {
            Label("已下载，可在「文件」App 里打开", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundColor(.green)
                .padding(.horizontal, 16).padding(.top, 12)
        } else if let job = downloads.job(for: d.id) {
            DownloadProgressStrip(job: job)
                .padding(.horizontal, 16).padding(.top, 14)
        } else {
            Button {
                downloads.enqueue(albumId: d.id, title: d.name)
            } label: {
                Label("下载全本", systemImage: "arrow.down.circle")
                    .font(.headline).foregroundColor(accentPink)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.white.opacity(0.08)).cornerRadius(12)
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    @ViewBuilder
    private func chapterList(_ d: AlbumDetail) -> some View {
        if !d.chapters.isEmpty {
            Text("章节").font(.subheadline).foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 4)
            ForEach(d.chapters) { ch in
                let prog = library.progressFor(albumId: d.id)
                Button {
                    readerRoute = ReaderRoute(albumId: d.id, albumName: d.name, chapters: d.chapters,
                                              startChapterId: ch.id,
                                              startPage: prog?.chapterId == ch.id ? prog!.page : 0)
                } label: {
                    HStack {
                        Text(ch.name).font(.body)
                            .foregroundColor(prog?.chapterId == ch.id ? accentPink : .primary)
                        Spacer()
                        if prog?.chapterId == ch.id {
                            Text("已看 \(prog!.page + 1) 页").font(.caption).foregroundColor(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 16)
            }
        }
    }

    private func load() async {
        loadFailed = false
        do {
            // Overall cap: if the album call has not answered in 20 s (a dead
            // or stalled line can otherwise spin on the loading view for
            // minutes), surface the failure state with its retry button.
            let d = try await withThrowingTaskGroup(of: AlbumDetail.self) { group in
                group.addTask { try await JMClient.shared.album(id: albumId) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw JMError.badResponse
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            detail = d
            blockStore.remember(albumId: d.id, tags: d.tags, authors: d.authors)
            cloudFav = d.isFavorite
            if d.isFavorite { account.clearRemovedFav(d.id) }
        } catch { loadFailed = true }
    }
}

struct DownloadProgressStrip: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.phase).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Text("\(job.donePages)/\(job.totalPages) 页").font(.caption).foregroundColor(.secondary)
            }
            ProgressView(value: job.fraction).tint(accentPink)
        }
    }
}


// MARK: - storage page (个人 page)

struct StorageView: View {
    @State private var imgBytes: Int64 = 0
    @State private var imgFiles: Int = 0
    @State private var dlBytes: Int64 = 0
    @State private var dlFiles: Int = 0
    @State private var confirmClear = false
    @State private var justCleared = false

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("总占用").font(.caption).foregroundColor(.secondary)
                    Text(fmt(imgBytes + dlBytes))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundColor(accentPink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(spacing: 0) {
                    row(icon: "photo.stack", title: "图片缓存",
                        sub: "\(imgFiles) 张封面与漫画页", value: fmt(imgBytes))
                    Divider().padding(.leading, 46)
                    row(icon: "arrow.down.doc", title: "已下载漫画",
                        sub: "\(dlFiles) 本（PDF，在下载页左滑删除）", value: fmt(dlBytes))
                }
                .padding(.vertical, 6)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    confirmClear = true
                } label: {
                    HStack {
                        Spacer()
                        if justCleared {
                            Label("已清理", systemImage: "checkmark.circle.fill")
                        } else {
                            Text("清理图片缓存")
                        }
                        Spacer()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(justCleared ? .secondary : accentPink)
                }
                .disabled(imgBytes == 0 || justCleared)
                .padding(.vertical, 13)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("图片缓存是看过的封面和漫画页，清掉不影响收藏与已下载漫画，下次打开会重新下载。")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog("清理图片缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清掉 \(fmt(imgBytes)) 图片缓存，已下载的漫画不受影响。")
        }
    }

    private func row(icon: String, title: String, sub: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(accentPink)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(sub).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reload() async {
        let usage = await Task.detached {
            (ImagePipe.shared.diskCacheUsage(), DownloadedStore.diskUsage())
        }.value
        imgBytes = usage.0.bytes
        imgFiles = usage.0.files
        dlBytes = usage.1.bytes
        dlFiles = usage.1.files
    }

    private func clear() async {
        await Task.detached { ImagePipe.shared.clearDiskCache() }.value
        justCleared = true
        await reload()
    }
}

// MARK: - reading stats card (个人 page)

struct ReadingStatsCard: View {
    @EnvironmentObject var stats: ReadingStatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("阅读统计").font(.subheadline.weight(.semibold))
            if stats.albumCount == 0 {
                Text("开始阅读后，这里会统计你读过的漫画、章节和时长")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                HStack(spacing: 0) {
                    stat("读过", "\(stats.albumCount) 本")
                    stat("章节", "\(stats.chapterCount) 话")
                    stat("页数", "\(stats.pagesRead) 页")
                    stat("时长", durationText)
                }
            }
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
        // Totals are recorded silently while reading (publishing mid-push
        // popped the reader); refresh the display values when this card
        // appears.
        .onAppear { stats.flushPublishes() }
    }

    private var durationText: String {
        let m = stats.secondsRead / 60
        if m < 60 { return "\(m) 分钟" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundColor(accentPink)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - profile stats strip (个人 page)

struct ProfileStatsCard: View {
    @EnvironmentObject var account: AccountStore
    @State private var showLogin = false

    var body: some View {
        if account.isLoggedIn {
            Group {
                if let s = account.stats {
                    statsCard(s)
                } else {
                    syncPrompt
                }
            }
            .sheet(isPresented: $showLogin) { LoginView() }
        }
    }

    /// exp / level / coin only arrive with the login response; a session that
    /// has been alive since before the stats strip shipped has none cached.
    private var syncPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("账号数据未同步").font(.subheadline.weight(.semibold))
                Text("经验、等级、金币在登录时同步，重新登录一次即可显示")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("重新登录") { showLogin = true }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(accentPink)
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func statsCard(_ s: AccountStore.MemberStats) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("LV \(s.level)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(accentPink)
                ProgressView(value: Double(s.exp), total: Double(max(s.nextLevelExp, 1)))
                    .tint(accentPink)
                Text("\(s.exp)/\(s.nextLevelExp)")
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                stat("经验值", "\(s.exp)")
                stat("J Coins", "\(s.coin)")
                stat("可收藏数量", "\(s.favoritesCount)/\(s.favoritesMax)")
            }
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundColor(accentPink)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - settings (个人 page, gear at top right)

struct SettingsView: View {
    @EnvironmentObject var blockStore: BlockTagStore
    @AppStorage("settings.autoCheckIn") private var autoCheckIn = true
    @State private var storageBytes: Int64?
    @State private var apiModeText = "自动"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.checkmark")
                            .foregroundColor(accentPink)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动签到").foregroundColor(.primary)
                            Text("每天第一次打开 App 时自动签到")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $autoCheckIn)
                            .labelsHidden()
                            .tint(accentPink)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 52)
                    navRow(icon: "network", title: "线路设置", value: apiModeText) {
                        LineSettingsView()
                    }
                    Divider().padding(.leading, 52)
                    navRow(icon: "internaldrive", title: "存储空间",
                           value: storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }) {
                        StorageView()
                    }
                    Divider().padding(.leading, 52)
                    navRow(icon: "eye.slash", title: "屏蔽标签与作者",
                           value: (blockStore.blockedTags.count + blockStore.blockedAuthors.count) == 0
                               ? nil : "\(blockStore.blockedTags.count + blockStore.blockedAuthors.count) 项") {
                        BlockedTagsView()
                    }
                }
                .padding(.vertical, 6)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("线路名单来自 JM 官方域名分发，只包含官方域名，不使用任何第三方镜像。")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let manual = LineStore.shared.manualAPIHost,
               let line = LineStore.shared.apiLines().first(where: { $0.host == manual }) {
                apiModeText = line.name.isEmpty ? manual : line.name
            } else {
                apiModeText = "自动"
            }
            storageBytes = await Task.detached {
                ImagePipe.shared.diskCacheUsage().bytes + DownloadedStore.diskUsage().bytes
            }.value
        }
    }

    private func navRow<Dest: View>(icon: String, title: String, value: String?,
                                    @ViewBuilder dest: () -> Dest) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(accentPink)
                    .frame(width: 24)
                Text(title).foregroundColor(.primary)
                Spacer()
                if let value {
                    Text(value).font(.subheadline).foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - line (domain) settings

struct LineSettingsView: View {
    @State private var apiLines: [APILine] = []
    @State private var imgHosts: [String] = []
    @State private var manualAPI: String?
    @State private var manualIMG: String?
    @State private var apiMs: [String: Int] = [:]
    @State private var imgMs: [String: Int] = [:]
    @State private var apiFailed: Set<String> = []
    @State private var imgFailed: Set<String> = []
    @State private var testing = false
    @State private var refreshing = false
    @State private var refreshedText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                sectionCard(
                    title: "API 线路",
                    subtitle: "接口域名，决定搜索、详情、收藏等请求走哪条线"
                ) {
                    autoRow(isManual: manualAPI == nil) {
                        LineStore.shared.manualAPIHost = nil
                        manualAPI = nil
                    }
                    ForEach(apiLines, id: \.host) { line in
                        Divider().padding(.leading, 52)
                        lineRow(
                            title: line.name.isEmpty ? line.host : line.name,
                            sub: line.name.isEmpty ? nil : line.host,
                            ms: apiMs[line.host],
                            failed: apiFailed.contains(line.host),
                            selected: manualAPI == line.host,
                            fastest: apiMs.values.min() == apiMs[line.host] && apiMs[line.host] != nil
                        ) {
                            LineStore.shared.manualAPIHost = line.host
                            manualAPI = line.host
                        }
                    }
                }

                sectionCard(
                    title: "图片线路",
                    subtitle: "封面与漫画页的图片 CDN，决定图片加载速度"
                ) {
                    autoRow(isManual: manualIMG == nil) {
                        LineStore.shared.manualIMGHost = nil
                        manualIMG = nil
                    }
                    ForEach(imgHosts, id: \.self) { host in
                        Divider().padding(.leading, 52)
                        lineRow(
                            title: host,
                            sub: nil,
                            ms: imgMs[host],
                            failed: imgFailed.contains(host),
                            selected: manualIMG == host,
                            fastest: imgMs.values.min() == imgMs[host] && imgMs[host] != nil
                        ) {
                            LineStore.shared.manualIMGHost = host
                            manualIMG = host
                        }
                    }
                }

                Button {
                    Task { await testAll() }
                } label: {
                    HStack {
                        Spacer()
                        if testing { ProgressView() }
                        else { Text("全部测速") }
                        Spacer()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(accentPink)
                }
                .disabled(testing)
                .padding(.vertical, 13)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(spacing: 8) {
                    Text(refreshedText)
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button {
                        Task { await refreshList() }
                    } label: {
                        if refreshing { ProgressView() }
                        else { Text("刷新线路名单").font(.caption.weight(.semibold)) }
                    }
                    .disabled(refreshing)
                    .tint(accentPink)
                }
                .padding(.horizontal, 4)

                Text("自动模式下所有线路同时竞速，用最快的那条；手动指定后优先走选中的线路，挂了会自动回退到其他线路。测速结果只用来参考，延迟低不等于一定更稳。")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .navigationTitle("线路设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            await LineStore.shared.refreshIfStale()
            reload()
        }
    }

    private func sectionCard<Content: View>(title: String, subtitle: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 6)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func autoRow(isManual: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .foregroundColor(accentPink)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动").foregroundColor(.primary)
                    Text("全部线路竞速，用最快的")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if isManual {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(accentPink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineRow(title: String, sub: String?, ms: Int?, failed: Bool,
                         selected: Bool, fastest: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                        .lineLimit(1)
                    if let sub {
                        Text(sub).font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if testing && ms == nil && !failed {
                    ProgressView()
                } else if let ms {
                    Text("\(ms) ms")
                        .font(.subheadline.weight(fastest ? .bold : .regular))
                        .foregroundColor(fastest ? accentPink : .secondary)
                } else if failed {
                    Text("超时").font(.subheadline).foregroundColor(.red)
                } else {
                    Text("未测").font(.subheadline).foregroundColor(.secondary)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(accentPink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        apiLines = LineStore.shared.apiLines()
        imgHosts = LineStore.shared.imgHosts()
        manualAPI = LineStore.shared.manualAPIHost
        manualIMG = LineStore.shared.manualIMGHost
        if let date = LineStore.shared.refreshedAt() {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            refreshedText = "名单更新于 \(f.string(from: date))"
        } else {
            refreshedText = "名单尚未联网更新（使用内置官方域名）"
        }
    }

    private func refreshList() async {
        refreshing = true
        defer { refreshing = false }
        await LineStore.shared.refreshIfStale(force: true)
        reload()
    }

    private func testAll() async {
        testing = true
        defer { testing = false }
        apiMs = [:]; imgMs = [:]; apiFailed = []; imgFailed = []
        let lines = apiLines
        let hosts = imgHosts
        await withTaskGroup(of: Void.self) { group in
            for line in lines {
                group.addTask {
                    let ms = await LineStore.measureAPI(host: line.host)
                    await MainActor.run {
                        if let ms { apiMs[line.host] = ms } else { apiFailed.insert(line.host) }
                    }
                }
            }
            for host in hosts {
                group.addTask {
                    let ms = await LineStore.measureIMG(host: host)
                    await MainActor.run {
                        if let ms { imgMs[host] = ms } else { imgFailed.insert(host) }
                    }
                }
            }
        }
    }
}

// MARK: - auto daily check-in

enum AutoCheckIn {
    private static var todayKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static var todayNotice: String? {
        let d = UserDefaults.standard
        guard d.string(forKey: "autoCheckin.noticeDay") == todayKey else { return nil }
        return d.string(forKey: "autoCheckin.notice")
    }

    /// Runs once per day on launch / login change: if today's check-in is
    /// still open, sign it and remember the reward for the profile card.
    /// A failed attempt leaves the day unset so the next launch retries.
    @MainActor
    static func runIfNeeded(account: AccountStore) async {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: "settings.autoCheckIn") as? Bool ?? true
        guard enabled, account.isLoggedIn, let uid = AccountStore.currentUserId else { return }
        guard d.string(forKey: "autoCheckin.day") != todayKey else { return }
        guard let info = try? await JMClient.shared.dailyInfo(userId: uid) else { return }
        if info.todaySigned {
            d.set(todayKey, forKey: "autoCheckin.day")
            return
        }
        do {
            let reward = try await JMClient.shared.dailyCheck(userId: uid, dailyId: info.dailyId)
            account.applyCheckinReward(reward)
            d.set(todayKey, forKey: "autoCheckin.day")
            d.set("今日已自动签到\(reward.isEmpty ? "" : "：\(reward)")", forKey: "autoCheckin.notice")
            d.set(todayKey, forKey: "autoCheckin.noticeDay")
        } catch {
            // leave the day unset; next launch retries
        }
    }
}

// MARK: - daily check-in card (个人 page)

struct CheckinCard: View {
    @EnvironmentObject var account: AccountStore
    @State private var info: DailyInfo?
    @State private var loading = false
    @State private var checking = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.checkmark")
                    .foregroundColor(accentPink)
                Text("每日签到").font(.headline)
                Spacer()
                if let info {
                    Text(info.eventName).font(.caption).foregroundColor(.secondary)
                }
            }
            if !account.isLoggedIn {
                Text("登录后每天签到，领金币和经验奖励").font(.subheadline).foregroundColor(.secondary)
            } else if let info {
                calendar(info)
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本月已签 \(info.signedCount) 天 · 进度 \(info.progress)")
                            .font(.caption).foregroundColor(.secondary)
                        Text("连签3天 +\(info.threeCoin) 金币 · 连签7天 +\(info.sevenCoin) 金币 · 补签 \(info.makeupUsed)/\(info.makeupLimit)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if info.todaySigned {
                        Label("今日已签", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)
                    } else {
                        Button {
                            Task { await checkIn() }
                        } label: {
                            if checking { ProgressView() }
                            else { Text("立即签到").font(.subheadline.weight(.bold)) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accentPink)
                        .disabled(checking)
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundColor(accentPink)
                } else if info.todaySigned, let auto = AutoCheckIn.todayNotice {
                    Text(auto).font(.caption).foregroundColor(.secondary)
                }
            } else if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Text("签到信息没加载出来，进页面会自动重试").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .task(id: account.username) { await load() }
    }

    private func calendar(_ info: DailyInfo) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
            ForEach(info.weeks.flatMap { $0 }) { day in
                dayCell(day, today: day.date == info.todayString)
            }
        }
    }

    private func dayCell(_ day: DailyDay, today: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(day.signed == true ? accentPink : (today ? accentPink.opacity(0.15) : Color.secondary.opacity(0.10)))
                if today && day.signed != true {
                    Circle().strokeBorder(accentPink, lineWidth: 1.5)
                }
                if day.signed == true {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                } else {
                    Text(day.date)
                        .font(.system(size: 10).weight(today ? .bold : .regular))
                        .foregroundColor(day.signed == false && !today ? .secondary : .primary)
                }
            }
            if day.bonus {
                Image(systemName: "star.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.yellow)
                    .offset(x: 2, y: -2)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    private func load() async {
        guard account.isLoggedIn, let uid = AccountStore.currentUserId else { return }
        loading = true
        defer { loading = false }
        info = try? await JMClient.shared.dailyInfo(userId: uid)
    }

    private func checkIn() async {
        guard let uid = AccountStore.currentUserId else { return }
        checking = true
        defer { checking = false }
        do {
            let reward = try await JMClient.shared.dailyCheck(userId: uid, dailyId: info?.dailyId ?? 0)
            account.applyCheckinReward(reward)
            info = try? await JMClient.shared.dailyInfo(userId: uid)
            notice = info?.todaySigned == true ? "签到成功\(reward.isEmpty ? "" : "：\(reward)")" : "已提交，请稍后刷新看看"
        } catch {
            notice = "签到失败：\(error.localizedDescription)"
        }
    }
}


// MARK: - author works page

struct AuthorWorksView: View {
    let author: String
    @State private var items: [Comic] = []
    @State private var page = 0
    @State private var fetched = 0
    @State private var total = 0
    @State private var loading = false
    @State private var done = false

    var body: some View {
        ScrollView {
            if !items.isEmpty {
                ComicGrid(items: items, applyBlockFilter: true,
                          onLastAppear: { Task { await loadMore() } },
                          directDetailLinks: true)
                    .padding(.top, 6)
            }
            if loading {
                ProgressView().padding()
            } else if done && items.isEmpty {
                Text("没找到这位作者的作品").foregroundColor(.secondary).padding(.top, 40)
            }
        }
        .tabMinimizeOnScroll()
        .navigationTitle(author)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ColumnButton() } }
        .withDestinations()
        .task { if page == 0 { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        // Keep paging until this call turns up at least one credited work (or
        // the results run out). The old code stopped after a single page, so
        // when that page's broad matches were all filtered out the view was
        // left blank with no grid to trigger another load. mainTag 2 asks the
        // API for author matches specifically instead of searching everything.
        var added = 0
        var hops = 0
        while !done && added == 0 && hops < 10 {
            hops += 1
            let next = page + 1
            guard let r = try? await JMClient.shared.search(query: author, page: next, mainTag: 2)
            else { done = true; break }
            total = r.total
            page = next
            fetched += r.items.count
            // search can still stray; keep only works actually credited to this author
            let credited = r.items.filter { $0.author.contains(author) }
            for c in credited where !items.contains(where: { $0.id == c.id }) {
                items.append(c)
                added += 1
            }
            if r.items.isEmpty || fetched >= total { done = true }
        }
    }
}


// MARK: - 观看历史（数据来自 LibraryStore.progress：阅读器一直在记录的续读进度）
struct HistoryView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var showClearConfirm = false
    @State private var readerRoute: ReaderRoute?

    private struct Row: Identifiable {
        let albumId: String
        let entry: LibraryStore.ProgressEntry
        var id: String { albumId }
    }

    private var entries: [Row] {
        library.progress
            .map { Row(albumId: $0.key, entry: $0.value) }
            .sorted { $0.entry.updatedAt > $1.entry.updatedAt }
    }

    private func relTime(_ ts: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }

    var body: some View {
        List {
            ForEach(entries) { item in
                Button {
                    readerRoute = ReaderRoute(
                        albumId: item.albumId,
                        albumName: item.entry.albumName ?? "",
                        chapters: [],
                        startChapterId: item.entry.chapterId,
                        startPage: item.entry.page
                    )
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(path: ImagePipe.coverPath(albumId: item.albumId), targetWidth: 200)
                            .frame(width: 46, height: 61)
                            .clipped()
                            .cornerRadius(6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((item.entry.albumName ?? "").isEmpty ? "未知标题" : item.entry.albumName!)
                                .font(.subheadline).fontWeight(.semibold)
                                .lineLimit(1)
                            Text("\(item.entry.chapterName.isEmpty ? "单话" : item.entry.chapterName) · 看到第 \(item.entry.page + 1) 页")
                                .font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(relTime(item.entry.updatedAt))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.removeProgress(albumId: item.albumId)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readerRoute) { route in
            ReaderView(route: route)
        }
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { showClearConfirm = true }
                }
            }
        }
        .confirmationDialog("清空全部观看历史？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { library.clearProgress() }
            Button("取消", role: .cancel) {}
        }
        .overlay {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("还没有观看记录").foregroundColor(.secondary)
                    Text("看过的漫画会自动出现在这里，点开接着看")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .task {
            // 老记录没有存标题的，逐个回填
            for item in entries where (item.entry.albumName ?? "").isEmpty {
                if let d = try? await JMClient.shared.album(id: item.albumId) {
                    library.backfillProgressName(albumId: item.albumId, name: d.name)
                }
            }
        }
    }
}
