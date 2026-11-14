import SwiftUI

// MARK: - 猜你喜欢: personalized picks from the user's own favorites
//
// Taste profile = weighted tags/authors of the cloud favorites mirrored in
// LibraryStore. Tag knowledge comes from BlockTagStore's caches (filled by
// detail fetches); missing favorites are sampled (max 20 detail fetches).
// Candidates are pulled with tag searches (mainTag 0) and author searches
// (mainTag 2), scored by the weights of the queries that surfaced them,
// favorites excluded; the shelf grid applies the block filter on top.

@MainActor
enum TasteEngine {
    struct Profile {
        var tagWeights: [String: Int] = [:]
        var authorWeights: [String: Int] = [:]
        var topTags: [String] { tagWeights.sorted { $0.value > $1.value }.prefix(6).map(\.key) }
        var topAuthors: [String] { authorWeights.sorted { $0.value > $1.value }.prefix(4).map(\.key) }
    }

    static func buildProfile(favorites: [Comic], blocks: BlockTagStore) async -> Profile {
        var profile = Profile()
        for fav in favorites {
            for name in fav.author.split(separator: " ").map(String.init) where !name.isEmpty {
                profile.authorWeights[name, default: 0] += 2
            }
            if let tags = blocks.tagCache[fav.id] {
                for t in tags { profile.tagWeights[t, default: 0] += 1 }
            }
            if let authors = blocks.authorCache[fav.id] {
                for a in authors { profile.authorWeights[a, default: 0] += 1 }
            }
        }
        // Sample favorites whose tags are unknown yet and learn them.
        let unknown = favorites.filter { blocks.tagCache[$0.id] == nil }.shuffled()
        var fetched = 0
        for fav in unknown where fetched < 20 {
            if let detail = try? await JMClient.shared.album(id: fav.id) {
                blocks.remember(albumId: fav.id, tags: detail.tags, authors: detail.authors)
                for t in detail.tags { profile.tagWeights[t, default: 0] += 1 }
                for a in detail.authors { profile.authorWeights[a, default: 0] += 1 }
                fetched += 1
            }
        }
        return profile
    }

    static func candidates(profile: Profile, favorites: [Comic], shift: Int) async -> [Comic] {
        let favIds = Set(favorites.map(\.id))
        var scores: [String: Double] = [:]
        var comics: [String: Comic] = [:]
        func absorb(_ list: [Comic], weight: Double) {
            for c in list where !favIds.contains(c.id) {
                scores[c.id, default: 0] += weight
                if comics[c.id] == nil { comics[c.id] = c }
            }
        }
        for tag in profile.topTags {
            let page = 1 + (shift % 2)
            if let res = try? await JMClient.shared.search(query: tag, page: page) {
                absorb(res.items, weight: Double(profile.tagWeights[tag] ?? 1))
            }
        }
        for author in profile.topAuthors {
            if let res = try? await JMClient.shared.search(query: author, page: 1, mainTag: 2) {
                absorb(res.items, weight: Double(profile.authorWeights[author] ?? 2) * 1.5)
            }
        }
        // Score order with a little jitter so re-rolls feel fresh, then cap.
        let ranked = comics.values.sorted {
            (scores[$0.id] ?? 0) + Double.random(in: 0..<1.2) > (scores[$1.id] ?? 0) + Double.random(in: 0..<1.2)
        }
        return Array(ranked.prefix(36))
    }

    /// Fallback pool (same construction as RecommendView's randoms) for
    /// accounts with too few favorites to build a profile from.
    static func latestPool() async -> [Comic] {
        let start = Int.random(in: 1...24)
        var pool: [Comic] = []
        var seen = Set<String>()
        for page in start..<(start + 3) {
            var items: [Comic] = []
            for _ in 0..<2 where items.isEmpty {
                if let got = try? await JMClient.shared.latest(page: page) { items = got }
            }
            for c in items where seen.insert(c.id).inserted { pool.append(c) }
        }
        return Array(pool.shuffled().prefix(36))
    }
}

struct ForYouView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var blockStore: BlockTagStore
    @State private var items: [Comic] = []
    @State private var loading = false
    @State private var shift = 0
    @State private var thinProfile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("猜你喜欢").font(.headline)
                    Spacer()
                    Button {
                        Task { await load(reroll: true) }
                    } label: {
                        if loading {
                            ProgressView()
                        } else {
                            Text("换一批").font(.subheadline).foregroundColor(accentPink)
                        }
                    }
                    .disabled(loading)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                if thinProfile {
                    Text("收藏多一点之后，这里会按你的口味推荐；现在先随机推一些。")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 4)
                }
                if items.isEmpty && loading {
                    ProgressView("正在按你的口味挑…")
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else if items.isEmpty {
                    Text("暂时没挑到合适的，点「换一批」再试")
                        .foregroundColor(.secondary).padding(30)
                } else {
                    ComicGrid(items: items, columnsOverride: 4, applyBlockFilter: true)
                }
            }
            .padding(.bottom, 12)
        }
        .tabMinimizeOnScroll()
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func load(reroll: Bool = false) async {
        if loading { return }
        loading = true
        defer { loading = false }
        if reroll { shift += 1 }
        let favs = library.favorites
        if favs.count < 5 {
            thinProfile = true
            let pool = await TasteEngine.latestPool()
            if !pool.isEmpty { items = pool }
            return
        }
        thinProfile = false
        let profile = await TasteEngine.buildProfile(favorites: favs, blocks: blockStore)
        let got = await TasteEngine.candidates(profile: profile, favorites: favs, shift: shift)
        if !got.isEmpty { items = got }
    }
}
