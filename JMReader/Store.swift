import Foundation
import SwiftUI
import Security
import CryptoKit

enum Keychain {
    private static let service = "com.denia.jmreader.auth"

    static func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) != errSecSuccess {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

/// Cloud copy of the deleted-folder list, hosted on the user's own
/// Cloudflare Worker (the anireader-sync deployment, route
/// /jm/folders). JM's server-side folder delete is broken and its
/// folder_list disagrees across hosts, so the authoritative
/// "deleted" state lives here: shared across devices, immune to
/// reinstalls. The local tombstone map in AccountStore remains
/// the always-on cache and offline fallback — this client is only
/// ever consulted to merge MORE ids in, never to un-hide one.
private enum FolderRegistry {
    static let endpoint = URL(string: "https://anireader-sync.peimingliang8.workers.dev/jm/folders")!

    /// Capability key derived locally from the JM account; the
    /// server only ever sees this hash, never the name or uid.
    static func accountKey(username: String, uid: Int) -> String {
        SHA256.hash(data: Data("\(username):\(uid)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func fetchDeleted(key: String) async -> [String]? {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "acct", value: key)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["deleted"] as? [Any] else { return nil }
        return list.compactMap { $0 as? String }
    }

    static func reportDeleted(key: String, folderId: String) async {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["acct": key, "add": [folderId]])
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// Main-actor isolated: this store's @Published state must only ever be
/// mutated on the main thread. Its async helpers used to run on the
/// cooperative pool (non-isolated async funcs don't inherit the caller's
/// actor), so entering the profile page at cold start published from a
/// background thread while SwiftUI's view graph waited on the main
/// thread and the main thread waited on the publisher lock — a
/// three-way deadlock the FRONTBOARD watchdog killed (0x8BADF00D,
/// logs 2026-11-03 16:16 & 16:55).
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var username: String?
    @Published private(set) var stats: MemberStats?

    struct MemberStats: Codable {
        var exp: Int = 0
        var nextLevelExp: Int = 0
        var level: Int = 0
        var coin: Int = 0
        var favoritesCount: Int = 0
        var favoritesMax: Int = 0
    }

    private let statsKey = "jm.memberStats.v1"

    struct Auth { let jwt: String; let avs: String }

    /// Read by the API client on every request; nil when signed out.
    /// nonisolated: it only reads the keychain, and the API client calls
    /// it from background queues on every request.
    nonisolated static var currentAuth: Auth? {
        guard let jwt = Keychain.get("jwttoken"), !jwt.isEmpty else { return nil }
        return Auth(jwt: jwt, avs: Keychain.get("avs") ?? "")
    }

    var isLoggedIn: Bool { username != nil }

    /// The member id, decoded from the stored login token (SESSION.uid).
    nonisolated static var currentUserId: Int? {
        guard let jwt = Keychain.get("jwttoken") else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = obj["SESSION"] as? [String: Any] else { return nil }
        return (session["uid"] as? NSNumber)?.intValue
    }

    init() {
        username = Keychain.get("username")
        if username != nil,
           let data = UserDefaults.standard.data(forKey: statsKey),
           let st = try? JSONDecoder().decode(MemberStats.self, from: data) {
            stats = st
        }
        if let user = username { loadTombstones(for: user); loadRemovedFavs(for: user) }
    }

    private func saveStats() {
        if let st = stats, let data = try? JSONEncoder().encode(st) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }

    /// The favorites endpoint reports the live total on every load; fold it
    /// into the cached stats so the profile strip's 收藏 count never goes stale
    /// (exp / level / coin only exist in the login response).
    func syncFavoritesCount(_ total: Int) {
        guard var st = stats, total > 0, st.favoritesCount != total else { return }
        st.favoritesCount = total
        stats = st
        saveStats()
    }

    /// After a successful check-in the server reports the delta ("Jcoin:2 EXP:2");
    /// fold it into the cached stats so the profile strip stays current.
    func applyCheckinReward(_ msg: String) {
        guard var st = stats else { return }
        if let r = msg.range(of: "Jcoin:(\\d+)", options: .regularExpression) {
            st.coin += Int(msg[r].dropFirst(6)) ?? 0
        }
        if let r = msg.range(of: "EXP:(\\d+)", options: .regularExpression) {
            st.exp += Int(msg[r].dropFirst(4)) ?? 0
        }
        stats = st
        saveStats()
    }

    func signIn(username: String, password: String) async throws {
        let info = try await JMClient.shared.login(username: username, password: password)
        let jwt = anyString(info["jwttoken"])
        guard !jwt.isEmpty else { throw JMError.badResponse }
        Keychain.set("jwttoken", jwt)
        Keychain.set("avs", anyString(info["s"]))
        let name = anyString(info["username"]).isEmpty ? username : anyString(info["username"])
        Keychain.set("username", name)
        self.username = name
        loadTombstones(for: name)
        loadRemovedFavs(for: name)
        var st = MemberStats()
        st.exp = anyInt(info["exp"])
        st.nextLevelExp = anyInt(info["nextLevelExp"])
        st.level = anyInt(info["level"])
        st.coin = anyInt(info["coin"])
        st.favoritesCount = anyInt(info["album_favorites"])
        st.favoritesMax = anyInt(info["album_favorites_max"])
        stats = st
        saveStats()
    }

    // MARK: - cloud favorites cache (memory + disk snapshot, survives relaunch)
    @Published private(set) var cloudFavorites: [Comic] = []
    @Published private(set) var cloudTotal = 0
    @Published private(set) var cloudLoading = false
    private var cloudBulkLoading = false
    /// True once every favorites page has been fetched at least once.
    /// Merging filters duplicate ids (the server list shifts while
    /// paging), so the merged count can stay below the server total
    /// forever — completeness is tracked by pages fetched, not count.
    @Published private(set) var cloudAllFetched = false
    private var cloudPage = 0
    private var cloudPageSize = 0
    private var cloudOwner: String?

    private struct CloudFavSnapshot: Codable {
        var owner: String
        var total: Int
        var pages: Int
        var pageSize: Int
        var items: [Comic]
    }
    private let cloudKey = "jm.cloudFav.v1"

    var cloudFullyLoaded: Bool { cloudTotal > 0 && cloudFavorites.count >= cloudTotal }

    // MARK: - cloud favorite folders

    @Published private(set) var cloudFolders: [FavFolder] = []
    @Published private(set) var cloudFolderId: String = "0"
    /// Non-default folders are cached in memory only (the disk snapshot and
    /// the reconcile machinery stay scoped to the default folder).
    private var folderItems: [String: [Comic]] = [:]
    private var folderTotals: [String: Int] = [:]
    private var folderPages: [String: Int] = [:]
    private var folderLoading = false
    /// Ids of folders the user deleted, mapped to deletion time —
    /// hidden locally for good. Two measured facts force this design
    /// (live API probes, 2026-11-04):
    /// 1. JM's folder delete is broken server-side: POST
    ///    favorite_folder type=del returns envelope code 200 with a
    ///    payload of {status: fail, msg: 未知錯誤請聯繫管理員} in
    ///    every encoding/host/parameter variant tried. The delete
    ///    POST is still sent (harmless if JM ever fixes it), but
    ///    the local hide is the only deletion that actually works.
    /// 2. The API hosts disagree about folder_list for 12+ hours,
    ///    flip-flopping between responses, so no server response can
    ///    ever prove a folder is gone — tombstones never expire.
    /// Stored per account: folder ids are only unique per user, and
    /// an account switch must neither leak nor wipe another
    /// account's list. (Builds 36/37 got this wrong twice: the
    /// tombstone was dropped on the first server list missing the
    /// id, and ensureCloudCache wiped it on every cold start because
    /// cloudOwner is memory-only.)
    private var deletedFolderTombstones: [String: TimeInterval] = [:]

    private func tombstoneKey(for user: String) -> String { "jm.deletedFolders.v2.\(user)" }

    private func loadTombstones(for user: String) {
        if let saved = UserDefaults.standard.dictionary(forKey: tombstoneKey(for: user)) as? [String: TimeInterval] {
            deletedFolderTombstones = saved
        } else if let legacy = UserDefaults.standard.dictionary(forKey: "jm.deletedFolders.v1") as? [String: TimeInterval] {
            deletedFolderTombstones = legacy
        } else {
            deletedFolderTombstones = [:]
        }
    }

    private func saveTombstones() {
        guard let user = username else { return }
        UserDefaults.standard.set(deletedFolderTombstones, forKey: tombstoneKey(for: user))
    }

    /// Sign-out only: forget the outgoing account's local deletions.
    private func clearTombstones(for user: String?) {
        deletedFolderTombstones = [:]
        if let user {
            UserDefaults.standard.removeObject(forKey: tombstoneKey(for: user))
        }
        UserDefaults.standard.removeObject(forKey: "jm.deletedFolders.v1")
    }

    // MARK: - removed-favorite tombstones
    /// Albums the user unfavorited IN THIS APP. The favorites hosts
    /// flip-flop for hours (the folder-tombstone lesson), so a merge or
    /// reload can resurrect a just-removed album from a stale list —
    /// and persist the resurrection (build 43 report 2026-11-05: star
    /// turned off, album stayed in the list, back again after
    /// relaunch). While a tombstone lives, list building skips the id.
    /// Cleared when the album is favorited again in-app or the album
    /// endpoint itself reports it favorited; expires after 7 days as
    /// a cross-device safety valve.
    private var removedFavTombstones: [String: TimeInterval] = [:]

    private func removedFavKey(for user: String) -> String { "jm.removedFavs.v1.\(user)" }

    private func loadRemovedFavs(for user: String) {
        let saved = UserDefaults.standard.dictionary(forKey: removedFavKey(for: user)) as? [String: TimeInterval] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - 7 * 24 * 3600
        removedFavTombstones = saved.filter { $0.value > cutoff }
    }

    private func saveRemovedFavs() {
        guard let user = username else { return }
        UserDefaults.standard.set(removedFavTombstones, forKey: removedFavKey(for: user))
    }

    private func isRemovedFav(_ id: String) -> Bool { removedFavTombstones[id] != nil }

    /// The album is favorited again (here, or the server says so):
    /// stop filtering it out of the lists.
    func clearRemovedFav(_ id: String) {
        if removedFavTombstones.removeValue(forKey: id) != nil { saveRemovedFavs() }
    }

    private func clearRemovedFavs(for user: String?) {
        removedFavTombstones = [:]
        if let user { UserDefaults.standard.removeObject(forKey: removedFavKey(for: user)) }
    }

    private var cloudTombstonesFetchedAt: Date?

    private var registryKey: String? {
        guard let user = username, let uid = Self.currentUserId else { return nil }
        return FolderRegistry.accountKey(username: user, uid: uid)
    }

    /// Pull the cloud deleted-folder list and merge it into the
    /// local tombstones (union — a deletion recorded on any device
    /// applies everywhere). Failures are silent: the local list
    /// alone is a complete fallback. Throttled to once per 10 min
    /// so profile visits don't turn into KV read traffic.
    func refreshCloudTombstones() async {
        guard let key = registryKey else { return }
        if let at = cloudTombstonesFetchedAt, Date().timeIntervalSince(at) < 600 { return }
        cloudTombstonesFetchedAt = Date()
        guard let ids = await FolderRegistry.fetchDeleted(key: key) else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for id in ids where deletedFolderTombstones[id] == nil {
            deletedFolderTombstones[id] = now
            changed = true
        }
        if changed {
            saveTombstones()
            cloudFolders.removeAll { deletedFolderTombstones[$0.id] != nil }
            if deletedFolderTombstones[cloudFolderId] != nil {
                cloudFolderId = "0"
            }
        }
    }

    /// Folders as shown in pickers: the default folder always comes first.
    var displayFolders: [FavFolder] {
        if cloudFolders.contains(where: { $0.id == "0" }) { return cloudFolders }
        return [FavFolder(id: "0", name: "默认收藏")] + cloudFolders
    }

    var displayedCloud: [Comic] {
        cloudFolderId == "0" ? cloudFavorites : (folderItems[cloudFolderId] ?? [])
    }
    var displayedCloudTotal: Int {
        cloudFolderId == "0" ? cloudTotal : (folderTotals[cloudFolderId] ?? 0)
    }
    var displayedCloudFullyLoaded: Bool {
        if cloudFolderId == "0" && cloudAllFetched { return true }
        return displayedCloudTotal > 0 && displayedCloud.count >= displayedCloudTotal
    }

    private func noteFolders(_ folders: [FavFolder]) {
        let visible = folders.filter { deletedFolderTombstones[$0.id] == nil }
        if !visible.isEmpty { cloudFolders = visible }
    }

    func switchFolder(_ id: String) async {
        guard id != cloudFolderId else { return }
        cloudFolderId = id
        if id != "0", folderItems[id] == nil { await loadFolderPage() }
    }

    func loadFolderPage(reset: Bool = false) async {
        let fid = cloudFolderId
        guard fid != "0", !folderLoading, isLoggedIn else { return }
        if reset { folderItems[fid] = []; folderPages[fid] = 0; folderTotals[fid] = 0 }
        let loaded = folderItems[fid] ?? []
        if !loaded.isEmpty, let t = folderTotals[fid], loaded.count >= t { return }
        folderLoading = true
        cloudLoading = true
        defer { folderLoading = false; cloudLoading = false }
        do {
            let page = (folderPages[fid] ?? 0) + 1
            let res = try await JMClient.shared.favorites(page: page, folderId: fid)
            noteFolders(res.folders)
            folderTotals[fid] = res.total
            folderPages[fid] = page
            let known = Set(loaded.map(\.id))
            folderItems[fid] = loaded + res.items.filter { !known.contains($0.id) && !isRemovedFav($0.id) }
        } catch { /* keep what we have */ }
    }

    func createFolder(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Optimistic: show the folder right away under a pending id. The
        // favorites endpoint can serve a stale folder_list for a few
        // seconds after a write (a created folder only showed up after
        // leaving and re-entering the page), so poll until the real
        // folder (with its server id) shows up and swap the placeholder.
        let pendingId = "pending-" + UUID().uuidString
        cloudFolders.append(FavFolder(id: pendingId, name: name))
        do {
            try await JMClient.shared.favoriteFolderAdd(name: name)
        } catch {
            cloudFolders.removeAll { $0.id == pendingId }
            return
        }
        for _ in 0..<5 {
            if let res = try? await JMClient.shared.favorites(page: 1, folderId: "0"),
               res.folders.contains(where: { $0.name == name }) {
                noteFolders(res.folders)
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        cloudFolders.removeAll { $0.id == pendingId }
        await refreshFolderList()
    }

    func deleteFolder(id: String) async {
        guard id != "0" else { return }
        // Optimistic removal, same stale-read problem as create. The
        // tombstone keeps later (stale) server lists from bringing
        // the folder back — see noteFolders.
        deletedFolderTombstones[id] = Date().timeIntervalSince1970
        saveTombstones()
        if let key = registryKey {
            Task { await FolderRegistry.reportDeleted(key: key, folderId: id) }
        }
        let backup = cloudFolders
        cloudFolders.removeAll { $0.id == id }
        folderItems[id] = nil; folderTotals[id] = nil; folderPages[id] = nil
        if cloudFolderId == id { cloudFolderId = "0" }
        do {
            try await JMClient.shared.favoriteFolderDelete(folderId: id)
        } catch {
            deletedFolderTombstones[id] = nil
            saveTombstones()
            cloudFolders = backup
            return
        }
        for _ in 0..<3 {
            if let res = try? await JMClient.shared.favorites(page: 1, folderId: "0"),
               !res.folders.contains(where: { $0.id == id }) {
                noteFolders(res.folders)
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    private func refreshFolderList() async {
        if let res = try? await JMClient.shared.favorites(page: 1, folderId: cloudFolderId) {
            noteFolders(res.folders)
        }
    }

    func moveFavorite(aid: String, toFolder: String) async {
        guard !toFolder.hasPrefix("pending-") else { return }
        do {
            try await JMClient.shared.favoriteFolderMove(albumId: aid, folderId: toFolder)
            await applyFolderMove(aid: aid, toFolder: toFolder)
        } catch { /* keep state */ }
    }

    /// After a move: drop the comic from every cached list except the
    /// target's, and invalidate the target so it refetches.
    func applyFolderMove(aid: String, toFolder: String) async {
        if toFolder != "0", cloudFavorites.contains(where: { $0.id == aid }) {
            cloudFavorites.removeAll { $0.id == aid }
            cloudTotal = max(0, cloudTotal - 1)
            syncFavoritesCount(cloudTotal)
            persistCloudSnapshot()
        }
        for key in Array(folderItems.keys) where key != toFolder {
            folderItems[key]?.removeAll { $0.id == aid }
            if let items = folderItems[key] { folderTotals[key] = items.count }
        }
        if toFolder != "0" {
            folderItems[toFolder] = nil; folderTotals[toFolder] = nil; folderPages[toFolder] = nil
            if cloudFolderId == toFolder { await loadFolderPage() }
        } else if cloudFolderId == "0" {
            // Moved back to the default folder: a front-reconcile picks it up.
            await reconcileCloudCache()
        }
    }

    /// After an unfavorite: drop the comic from every cached list and
    /// fix the totals (mirrors applyFolderMove's cache surgery).
    func applyCloudRemoval(aid: String) {
        removedFavTombstones[aid] = Date().timeIntervalSince1970
        saveRemovedFavs()
        if cloudFavorites.contains(where: { $0.id == aid }) {
            cloudFavorites.removeAll { $0.id == aid }
            cloudTotal = max(0, cloudTotal - 1)
            syncFavoritesCount(cloudTotal)
            persistCloudSnapshot()
        }
        for key in Array(folderItems.keys) {
            if folderItems[key]?.contains(where: { $0.id == aid }) == true {
                folderItems[key]?.removeAll { $0.id == aid }
                if let items = folderItems[key] { folderTotals[key] = items.count }
            }
        }
    }

    private var persistScheduled = false
    private var persistGen = 0

    /// Encoding a 1000+ item snapshot on the main thread was part of the
    /// profile-page hitch: encode detached, and coalesce bursts (paging
    /// calls this per page) into one write with the latest state.
    private func persistCloudSnapshot() {
        guard let owner = cloudOwner else { return }
        persistGen += 1
        if persistScheduled { return }
        persistScheduled = true
        writeCloudSnapshot(owner: owner)
    }

    /// The writer re-checks the generation when it lands: if the list
    /// changed while a write was in flight, the coalescing used to drop
    /// the newer state entirely — a removal right after a page load
    /// never reached disk and the album resurrected on relaunch. Now
    /// the latest state is written again instead of just clearing the
    /// flag.
    private func writeCloudSnapshot(owner: String) {
        let gen = persistGen
        let snap = CloudFavSnapshot(owner: owner, total: cloudTotal, pages: cloudPage,
                                    pageSize: cloudPageSize, items: cloudFavorites)
        let key = cloudKey
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snap) {
                UserDefaults.standard.set(data, forKey: key)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.persistGen != gen {
                    self.writeCloudSnapshot(owner: owner)
                } else {
                    self.persistScheduled = false
                }
            }
        }
    }

    private func hydrateCloudFromDisk() async {
        guard let data = UserDefaults.standard.data(forKey: cloudKey) else { return }
        let snap = await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode(CloudFavSnapshot.self, from: data)
        }.value
        guard let snap, snap.owner == username else { return }
        cloudFavorites = snap.items.filter { !isRemovedFav($0.id) }
        cloudTotal = snap.total
        cloudPage = snap.pages
        cloudPageSize = snap.pageSize
    }

    /// Reset only when the signed-in account changes. Warm cache (memory or disk)
    /// is shown instantly; a one-page check in the background catches changes.
    func ensureCloudCache() async {
        guard isLoggedIn else { return }
        if cloudOwner != username {
            cloudOwner = username
            cloudFavorites = []; cloudPage = 0; cloudTotal = 0; cloudPageSize = 0; cloudAllFetched = false
            cloudFolders = []; cloudFolderId = "0"
            folderItems = [:]; folderTotals = [:]; folderPages = [:]
            if let user = username { loadTombstones(for: user); loadRemovedFavs(for: user) }
            await hydrateCloudFromDisk()
        }
        await refreshCloudTombstones()
        if cloudFavorites.isEmpty {
            await loadCloudPage()
        } else {
            await reconcileCloudCache()
        }
    }

    /// Cache check that does NOT nuke the whole cache on any change.
    /// The old validate cleared everything whenever the newest favorite
    /// or the total moved — for an active account that meant a full
    /// 55-page refetch on most profile visits, which is exactly the
    /// heavy path behind the intermittent profile freezes. Now:
    /// additions at the front are prepended after a short overlap walk,
    /// and only a SHRINK (unfavorited elsewhere) falls back to a reload.
    private func reconcileCloudCache() async {
        guard let res = try? await JMClient.shared.favorites(page: 1) else { return }
        noteFolders(res.folders)
        if res.total == cloudTotal && res.items.first?.id == cloudFavorites.first?.id {
            return // cache is fresh
        }
        if res.total < cloudFavorites.count {
            cloudFavorites = []; cloudPage = 0; cloudTotal = 0; cloudPageSize = 0; cloudAllFetched = false
            await loadCloudPage()
            return
        }
        var fresh: [Comic] = []
        var pageItems = res.items
        var overlapped = false
        for page in 1...3 {
            if page > 1 {
                guard let next = try? await JMClient.shared.favorites(page: page) else { break }
                pageItems = next.items
            }
            for item in pageItems {
                if item.id == cloudFavorites.first?.id { overlapped = true; break }
                if isRemovedFav(item.id) { continue }
                fresh.append(item)
            }
            if overlapped { break }
        }
        if overlapped {
            cloudFavorites = fresh + cloudFavorites
            cloudTotal = res.total
            syncFavoritesCount(res.total)
            persistCloudSnapshot()
        } else {
            cloudFavorites = []; cloudPage = 0; cloudTotal = 0; cloudPageSize = 0; cloudAllFetched = false
            await loadCloudPage()
        }
    }

    func loadCloudPage() async {
        guard !cloudLoading, isLoggedIn else { return }
        if cloudFolderId != "0" { await loadFolderPage(); return }
        if !cloudFavorites.isEmpty && cloudFullyLoaded { return }
        if cloudPageSize > 0, cloudTotal > 0,
           cloudPage >= Int(ceil(Double(cloudTotal) / Double(cloudPageSize))) {
            cloudAllFetched = true
            return
        }
        cloudLoading = true
        defer { cloudLoading = false }
        do {
            let res = try await JMClient.shared.favorites(page: cloudPage + 1)
            noteFolders(res.folders)
            cloudTotal = res.total
            syncFavoritesCount(res.total)
            if cloudPageSize == 0 { cloudPageSize = res.items.count }
            cloudPage += 1
            let known = Set(cloudFavorites.map(\.id))
            cloudFavorites += res.items.filter { !known.contains($0.id) && !isRemovedFav($0.id) }
            persistCloudSnapshot()
        } catch { /* keep cache */ }
    }

    /// Load every remaining page CONCURRENTLY (sequential paging was the slow part).
    func loadAllCloud() async {
        if cloudFolderId != "0" {
            // Non-default folders: page through everything sequentially.
            var guardPages = 0
            while !displayedCloudFullyLoaded, guardPages < 80 {
                let before = displayedCloud.count
                await loadFolderPage()
                guardPages += 1
                if displayedCloud.count == before { break }
            }
            return
        }
        // Two view tasks can ask for this at once; overlapping runs used to
        // interleave their mutations of the published favorites array.
        guard !cloudBulkLoading, !cloudLoading else { return }
        cloudBulkLoading = true
        defer { cloudBulkLoading = false }
        if cloudFavorites.isEmpty { await loadCloudPage() }
        guard isLoggedIn, cloudTotal > 0, cloudPageSize > 0 else { return }
        let totalPages = Int(ceil(Double(cloudTotal) / Double(cloudPageSize)))
        let startPage = cloudPage + 1
        // CRASH FIX (build 42; crash logs 2026-11-05, EXC_BREAKPOINT in
        // loadAllCloud): duplicates filtered during merging can keep the
        // count below the server total, so this was re-entered with
        // cloudPage >= totalPages and (cloudPage + 1)...totalPages was an
        // invalid range that trapped — and the persisted oldest-first
        // sort re-triggered it on every profile visit. All pages fetched
        // IS complete; say so and stop.
        if startPage > totalPages || cloudFullyLoaded {
            cloudAllFetched = true
            return
        }
        let remaining = Array(startPage...totalPages)
        // Fetch in waves of 8 pages: firing all ~54 remaining pages at
        // once bursts the network stack and the decrypt queue, and the
        // stall that follows lands right on the profile page.
        var fetched: [Int: [Comic]] = [:]
        for waveStart in stride(from: 0, to: remaining.count, by: 8) {
            let wave = Array(remaining[waveStart..<min(waveStart + 8, remaining.count)])
            let waveResult = await withTaskGroup(of: (Int, [Comic]).self, returning: [Int: [Comic]].self) { group in
                for p in wave {
                    group.addTask {
                        let r = try? await JMClient.shared.favorites(page: p)
                        return (p, r?.items ?? [])
                    }
                }
                var out: [Int: [Comic]] = [:]
                for await (p, items) in group { out[p] = items }
                return out
            }
            fetched.merge(waveResult) { _, new in new }
        }
        // Merge into a LOCAL array and publish ONCE. Appending item-by-item
        // fired objectWillChange per comic (~1000 publishes for a big
        // account), each re-rendering the whole favorites grid on the main
        // thread — the profile page froze solid and the scene watchdog
        // killed the app (0x8BADF00D, crash log 2026-11-03).
        var merged = cloudFavorites
        var seen = Set(merged.map(\.id))
        for p in remaining {
            for item in fetched[p] ?? [] where !seen.contains(item.id) && !isRemovedFav(item.id) {
                seen.insert(item.id)
                merged.append(item)
            }
        }
        if merged.count != cloudFavorites.count { cloudFavorites = merged }
        cloudPage = totalPages
        cloudAllFetched = true
        persistCloudSnapshot()
    }

    func signOut() {
        let outgoing = username
        Keychain.remove("jwttoken")
        Keychain.remove("avs")
        Keychain.remove("username")
        username = nil
        stats = nil
        cloudFavorites = []; cloudTotal = 0; cloudPage = 0; cloudPageSize = 0; cloudOwner = nil; cloudAllFetched = false
        cloudFolders = []; cloudFolderId = "0"
        folderItems = [:]; folderTotals = [:]; folderPages = [:]
        clearTombstones(for: outgoing)
        clearRemovedFavs(for: outgoing)
        UserDefaults.standard.removeObject(forKey: cloudKey)
        UserDefaults.standard.removeObject(forKey: statsKey)
    }
}

final class AppState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var pendingSearch: String?
    @Published var searchFocusToken: Int = 0
    @Published var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: "jm.gridColumns") }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "jm.gridColumns")
        gridColumns = [2, 3, 4].contains(saved) ? saved : 4
    }

    func requestSearch(_ query: String) {
        pendingSearch = query
        selectedTab = 1
    }

    func goSearch() {
        selectedTab = 1
        searchFocusToken += 1
    }

    func cycleColumns() {
        gridColumns = gridColumns >= 4 ? 2 : gridColumns + 1
    }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: [Comic] = []
    /// albumId -> timeIntervalSince1970 when it was favorited (for sorting)
    @Published private(set) var favDates: [String: Double] = [:]
    /// albumId -> (chapterId, pageIndex). Deliberately NOT @Published: the
    /// reader saves progress on every page turn, and publishing each save
    /// re-rendered the detail view underneath mid-push, popping the reader
    /// straight back (same failure as the tag/author caches). Saves are
    /// silent; `noteProgressChanged()` is called when the reader closes
    /// so surfaces showing progress refresh once, at a safe moment.
    private(set) var progress: [String: ProgressEntry] = [:]
    @Published private(set) var progressTick = 0

    func noteProgressChanged() { progressTick &+= 1 }

    struct ProgressEntry: Codable {
        var chapterId: String
        var chapterName: String
        var page: Int
        var updatedAt: Double
        var albumName: String? = nil
    }

    private let favURL: URL
    private let progKey = "jm.progress.v1"
    private let favDatesKey = "jm.favdates.v1"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        favURL = docs.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: favURL),
           let list = try? JSONDecoder().decode([Comic].self, from: data) {
            favorites = list
        }
        if let data = UserDefaults.standard.data(forKey: progKey),
           let map = try? JSONDecoder().decode([String: ProgressEntry].self, from: data) {
            progress = map
        }
        if let data = UserDefaults.standard.data(forKey: favDatesKey),
           let map = try? JSONDecoder().decode([String: Double].self, from: data) {
            favDates = map
        }
        if favDates.isEmpty && !favorites.isEmpty {
            // legacy favorites have no timestamps; synthesize from list order (newest first)
            let now = Date().timeIntervalSince1970
            for (i, c) in favorites.enumerated() { favDates[c.id] = now - Double(i) * 3600 }
            saveFavDates()
        }
    }

    func favDate(for comic: Comic) -> Double { favDates[comic.id] ?? 0 }

    private func saveFavDates() {
        if let data = try? JSONEncoder().encode(favDates) {
            UserDefaults.standard.set(data, forKey: favDatesKey)
        }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ comic: Comic) {
        if isFavorite(comic.id) {
            favorites.removeAll { $0.id == comic.id }
            favDates[comic.id] = nil
        } else {
            favorites.insert(comic, at: 0)
            favDates[comic.id] = Date().timeIntervalSince1970
        }
        saveFavDates()
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: favURL, options: .atomic)
        }
    }

    func progressFor(albumId: String) -> ProgressEntry? { progress[albumId] }

    func saveProgress(albumId: String, chapterId: String, chapterName: String, page: Int, albumName: String = "") {
        let name = albumName.isEmpty ? progress[albumId]?.albumName : albumName
        progress[albumId] = ProgressEntry(chapterId: chapterId, chapterName: chapterName,
                                          page: page, updatedAt: Date().timeIntervalSince1970,
                                          albumName: name)
        persistProgress()
    }

    func removeProgress(albumId: String) {
        progress[albumId] = nil
        persistProgress()
        noteProgressChanged()
    }

    func clearProgress() {
        progress = [:]
        persistProgress()
        noteProgressChanged()
    }

    /// Fill in a missing album title (entries recorded before titles were stored).
    func backfillProgressName(albumId: String, name: String) {
        guard var e = progress[albumId], (e.albumName ?? "").isEmpty, !name.isEmpty else { return }
        e.albumName = name
        progress[albumId] = e
        persistProgress()
    }

    private func persistProgress() {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: progKey)
        }
    }
}

final class SearchHistory: ObservableObject {
    @Published private(set) var items: [String] = []
    private let key = "jm.searchHistory.v1"

    init() { items = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func add(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        items.removeAll { $0 == q }
        items.insert(q, at: 0)
        items = Array(items.prefix(12))
        UserDefaults.standard.set(items, forKey: key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}


// MARK: - blocked tags (custom browse filter)

/// User-defined tag blocklist. Browse surfaces (home shelves, channels,
/// categories, search) hide matching comics two ways: immediately when the
/// title / author / category contains a blocked word, and — once an album's
/// real tags are known — when its detail tags contain a blocked tag. List
/// endpoints return no tags, so tags are learned from detail fetches
/// (opening a detail page, plus background prefetch from lists) and kept
/// in a persisted cache. Favorites and history are never filtered.
/// Main-actor isolated for the same reason as AccountStore: prefetch
/// learned tags in a background task and published them off the main
/// thread, which is one of the three parties in the profile deadlock.
@MainActor
final class BlockTagStore: ObservableObject {
    @Published private(set) var blockedTags: [String] = []
    // Tags/authors learned from album fetches. Deliberately NOT @Published:
    // a detail view records its album here the moment it finishes loading,
    // and publishing on every learn re-rendered the grid underneath while
    // the push transition was still settling — on iOS 27 that tore down the
    // tapped cell's link and popped the just-opened detail straight back.
    // The author page hit it every time because its albums are never in
    // the cache yet. Filtering reads the caches on the next natural
    // render; only the blocked lists themselves stay published.
    private(set) var tagCache: [String: [String]] = [:]
    @Published private(set) var blockedAuthors: [String] = []
    private(set) var authorCache: [String: [String]] = [:]
    private var inFlight: Set<String> = []
    private var persistTask: Task<Void, Never>?
    /// Filter refresh counter for browse views. The caches above stay
    /// unpublished (publishing on every learn tore down navigation on
    /// iOS 27 — the v2.19 bug), but that left grids stale: prefetch could
    /// learn a listed album is blocked and nothing re-ran the filter, so
    /// it stayed visible until an unrelated render. This counter is the
    /// narrow exception: bumped only when learned data makes an album
    /// blocked, and debounced past any push transition (see apply()).
    @Published private(set) var filterVersion = 0
    private var filterBumpTask: Task<Void, Never>?

    private let listKey = "jm.blockedTags.v1"
    private let cacheKey = "jm.tagCache.v1"
    private let authorListKey = "jm.blockedAuthors.v1"
    private let authorCacheKey = "jm.authorCache.v1"

    init() {
        if let arr = UserDefaults.standard.array(forKey: listKey) as? [String] {
            blockedTags = arr
        }
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            tagCache = map
        }
        if let arr = UserDefaults.standard.array(forKey: authorListKey) as? [String] {
            blockedAuthors = arr
        }
        if let data = UserDefaults.standard.data(forKey: authorCacheKey),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            authorCache = map
        }
    }

    func add(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !blockedTags.contains(t) else { return }
        blockedTags.append(t)
        UserDefaults.standard.set(blockedTags, forKey: listKey)
    }

    func remove(_ tag: String) {
        blockedTags.removeAll { $0 == tag }
        UserDefaults.standard.set(blockedTags, forKey: listKey)
    }

    func addAuthor(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !blockedAuthors.contains(t) else { return }
        blockedAuthors.append(t)
        UserDefaults.standard.set(blockedAuthors, forKey: authorListKey)
    }

    func removeAuthor(_ author: String) {
        blockedAuthors.removeAll { $0 == author }
        UserDefaults.standard.set(blockedAuthors, forKey: authorListKey)
    }

    /// Record tags/authors learned from an album detail fetch (empty is
    /// recorded too, so tag-less albums are not refetched forever).
    func remember(albumId: String, tags: [String], authors: [String]) {
        if apply(entries: [(albumId, tags, authors)]) { schedulePersist() }
    }

    /// Merge learned tags/authors into the caches; returns true when
    /// anything actually changed (one publish per batch, not per album).
    private func apply(entries: [(String, [String], [String])]) -> Bool {
        var changed = false
        var becameBlocked = false
        for (id, tags, authors) in entries {
            let entryChanged = tagCache[id] != tags || authorCache[id] != authors
            if tagCache[id] != tags { tagCache[id] = tags }
            if authorCache[id] != authors { authorCache[id] = authors }
            guard entryChanged else { continue }
            changed = true
            // Relevance gate: only albums the new data actually blocks can
            // make an on-screen list stale. Mirrors isBlocked()'s cache
            // branches (exact tag match, case-insensitive author match).
            if !becameBlocked
                && (tags.contains(where: { blockedTags.contains($0) })
                    || authors.contains(where: { author in
                        blockedAuthors.contains(where: {
                            $0.localizedCaseInsensitiveCompare(author) == .orderedSame
                        })
                    })) {
                becameBlocked = true
            }
        }
        // The caches are not @Published (see their declaration), so merging
        // here triggers no view updates at all — except this one nudge when
        // a listed album turned out to be blocked.
        if becameBlocked { scheduleFilterBump() }
        return changed
    }

    /// One debounced filter refresh, delayed past any push transition:
    /// browse views observe blockStore, so bumping filterVersion re-runs
    /// their visible() filtering in place. Ordinary learns (albums that
    /// are not blocked) never schedule this — see the gate in apply().
    private func scheduleFilterBump() {
        filterBumpTask?.cancel()
        filterBumpTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            filterVersion += 1
        }
    }

    /// Persist the caches off the main actor, debounced: bursts of learned
    /// albums (list prefetch) used to JSON-encode the whole cache and write
    /// UserDefaults on the main thread for EVERY album, which visibly
    /// stuttered scrolling after the v2.18 upgrade backfilled author data
    /// for every previously cached album.
    private func schedulePersist() {
        persistTask?.cancel()
        let tagsSnapshot = tagCache
        let authorsSnapshot = authorCache
        let tagsKey = cacheKey
        let authorsKey = authorCacheKey
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(tagsSnapshot) {
                UserDefaults.standard.set(data, forKey: tagsKey)
            }
            if let data = try? JSONEncoder().encode(authorsSnapshot) {
                UserDefaults.standard.set(data, forKey: authorsKey)
            }
        }
    }

    func isBlocked(_ comic: Comic) -> Bool {
        guard !blockedTags.isEmpty || !blockedAuthors.isEmpty else { return false }
        let hay = comic.name + "\n" + comic.author + "\n" + comic.categoryTitle
        for t in blockedTags where hay.localizedCaseInsensitiveContains(t) { return true }
        if let tags = tagCache[comic.id] {
            for t in blockedTags where tags.contains(t) { return true }
        }
        for a in blockedAuthors where comic.author.localizedCaseInsensitiveContains(a) { return true }
        if let authors = authorCache[comic.id] {
            for a in blockedAuthors
            where authors.contains(where: { $0.localizedCaseInsensitiveCompare(a) == .orderedSame }) {
                return true
            }
        }
        return false
    }

    func visible(_ items: [Comic]) -> [Comic] {
        guard !blockedTags.isEmpty || !blockedAuthors.isEmpty else { return items }
        return items.filter { !isBlocked($0) }
    }

    /// Background: learn tags for listed albums whose tags are still
    /// unknown (4 at a time, at most 40 per call). Once known, the
    /// tag-based filter applies to them here and on future visits.
    func prefetch(_ items: [Comic]) {
        guard !blockedTags.isEmpty || !blockedAuthors.isEmpty else { return }
        // Fetch only what an ACTIVE filter still needs: with no blocked
        // authors, a missing authorCache must not trigger fetches (and the
        // reverse) — otherwise every list appearance re-fetches the world.
        let unknown = items.map(\.id).filter { id in
            if inFlight.contains(id) { return false }
            let needTags = !blockedTags.isEmpty && tagCache[id] == nil
            let needAuthors = !blockedAuthors.isEmpty && authorCache[id] == nil
            return needTags || needAuthors
        }
        guard !unknown.isEmpty else { return }
        let batch = Array(unknown.prefix(24))
        batch.forEach { inFlight.insert($0) }
        Task {
            for chunkStart in stride(from: 0, to: batch.count, by: 3) {
                let chunk = Array(batch[chunkStart..<min(chunkStart + 3, batch.count)])
                let results = await withTaskGroup(of: (String, [String]?, [String]?).self) { group in
                    for id in chunk {
                        group.addTask {
                            let d = try? await JMClient.shared.album(id: id)
                            return (id, d?.tags, d?.authors)
                        }
                    }
                    var out: [(String, [String]?, [String]?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                // Remember fetched albums even when their tag/author lists are
                // empty — otherwise they were re-fetched on every appearance.
                // Failures (nil) stay uncached and retry another time.
                // Applied as ONE batch per chunk (see apply/schedulePersist).
                let entries = results.compactMap { (id, tags, authors) -> (String, [String], [String])? in
                    guard let tags, let authors else { return nil }
                    return (id, tags, authors)
                }
                if self.apply(entries: entries) { self.schedulePersist() }
            }
            batch.forEach { self.inFlight.remove($0) }
        }
    }
}

// MARK: - reading stats

/// Local reading statistics: distinct albums/episodes opened in the reader,
/// pages actually reached (per-episode furthest page, so opening a chapter
/// no longer counts its whole page count), and time spent with the reader
/// open. Counted from v2.18 on; nothing is backfilled from earlier reading.
@MainActor
final class ReadingStatsStore: ObservableObject {
    @Published private(set) var albumCount = 0
    @Published private(set) var chapterCount = 0
    @Published private(set) var pagesRead = 0
    @Published private(set) var secondsRead = 0

    private struct Snapshot: Codable {
        var albums: [String] = []
        var chapters: [String] = []
        var pages: Int = 0
        var seconds: Int = 0
        var episodePages: [String: Int] = [:]
    }
    private var snap = Snapshot()
    private let key = "jm.readStats.v2"
    private let legacyKey = "jm.readStats.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snap = s
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            // v1 added a chapter's full page count the moment it was opened,
            // so its page total is inflated and cannot be decomposed; carry
            // over the album/chapter/time counts and restart pages honestly.
            snap.albums = s.albums
            snap.chapters = s.chapters
            snap.seconds = s.seconds
        }
        publish()
    }

    private func publish() {
        albumCount = snap.albums.count
        chapterCount = snap.chapters.count
        pagesRead = snap.pages
        secondsRead = snap.seconds
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Deliberately no publish() here: recording happens from inside the
        // reader (chapter open, every page reached, every 10 s), and
        // publishing re-rendered the reader while its push was still
        // settling — on iOS 27 the just-opened reader popped straight back
        // to the detail view. Recording is silent; display surfaces call
        // flushPublishes() at safe moments (reader exit, stats card appear).
    }

    /// Copy the silently-recorded totals into the @Published display values.
    func flushPublishes() { publish() }

    /// Called when a chapter opens in the reader. Each album and episode
    /// counts once; pages are counted separately as they are reached.
    func recordChapter(albumId: String, episodeId: String) {
        var changed = false
        if !snap.albums.contains(albumId) {
            snap.albums.append(albumId)
            changed = true
        }
        if !snap.chapters.contains(episodeId) {
            snap.chapters.append(episodeId)
            changed = true
        }
        if changed { persist() }
    }

    /// Called as the reader moves through a chapter. Only pages actually
    /// reached count, each at most once per episode: the total grows by how
    /// far past the previous furthest page this position is.
    func recordPage(episodeId: String, pageIndex: Int, chapterPages: Int) {
        guard !episodeId.isEmpty, chapterPages > 0 else { return }
        let reached = min(max(pageIndex + 1, 0), chapterPages)
        let prev = snap.episodePages[episodeId] ?? 0
        guard reached > prev else { return }
        snap.episodePages[episodeId] = reached
        snap.pages += reached - prev
        persist()
    }

    func addSeconds(_ s: Int) {
        guard s > 0 else { return }
        snap.seconds += s
        persist()
    }
}
