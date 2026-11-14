import Foundation

// The JM API mixes JSON strings and numbers for the same fields; these helpers tame that.
func anyString(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func anyInt(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) ?? 0 }
    return 0
}
func anyStringList(_ v: Any?) -> [String] {
    if let a = v as? [Any] { return a.map { anyString($0) }.filter { !$0.isEmpty } }
    if let s = v as? String { return s.split(separator: " ").map(String.init) }
    return []
}

struct Comic: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var author: String
    var categoryTitle: String

    init(id: String, name: String, author: String, categoryTitle: String = "") {
        self.id = id; self.name = name; self.author = author; self.categoryTitle = categoryTitle
    }

    init(dict d: [String: Any]) {
        id = anyString(d["id"])
        name = anyString(d["name"])
        author = anyString(d["author"])
        if let c = d["category"] as? [String: Any] { categoryTitle = anyString(c["title"]) }
        else { categoryTitle = "" }
    }

    var coverURLString: String { ImagePipe.coverURLString(albumId: id) }
}

/// One curated shelf from the `promote` endpoint (used by the Recommend channel).
struct PromoSection: Identifiable {
    var id: String
    var title: String
    var items: [Comic]

    init?(dict d: [String: Any]) {
        let type = anyString(d["type"])
        if type == "novels" { return nil }
        let raw = (d["content"] as? [Any]) ?? []
        let items = raw.compactMap { ($0 as? [String: Any]).map(Comic.init(dict:)) }
            .filter { !$0.id.isEmpty && !$0.name.isEmpty }
        guard items.count >= 4 else { return nil }
        id = anyString(d["id"]) + "-" + anyString(d["title"])
        title = anyString(d["title"])
        self.items = items
    }
}

/// One cloud favorites folder (`folder_list` entry in the favorite response).
struct FavFolder: Identifiable, Codable, Hashable {
    var id: String   // FID; "0" is the default folder
    var name: String
}

struct JMCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var slug: String
    var totalAlbums: String

    init(dict d: [String: Any]) {
        id = anyString(d["id"])
        name = anyString(d["name"])
        slug = anyString(d["slug"])
        totalAlbums = anyString(d["total_albums"])
    }
}

struct ChapterRef: Identifiable, Hashable {
    var id: String      // photo/chapter id
    var name: String
    var sort: Int
}

struct AlbumDetail {
    var id: String
    var name: String
    var categoryTitle: String
    var authors: [String]
    var tags: [String]
    var works: [String]
    var actors: [String]
    var description: String
    var totalViews: String
    var likes: String
    var totalPhotos: Int
    var isFavorite: Bool
    var chapters: [ChapterRef]   // empty for one-shots

    init(dict d: [String: Any]) {
        id = anyString(d["id"])
        name = anyString(d["name"])
        if let c = d["category"] as? [String: Any] { categoryTitle = anyString(c["title"]) }
        else { categoryTitle = "" }
        authors = anyStringList(d["author"])
        tags = anyStringList(d["tags"])
        works = anyStringList(d["works"])
        actors = anyStringList(d["actors"])
        description = anyString(d["description"])
        totalViews = anyString(d["total_views"])
        likes = anyString(d["likes"])
        totalPhotos = anyInt(d["total_photos"])
        isFavorite = anyInt(d["is_favorite"]) != 0
        var chs: [ChapterRef] = []
        if let series = d["series"] as? [Any] {
            for case let s as [String: Any] in series {
                chs.append(ChapterRef(id: anyString(s["id"]),
                                      name: anyString(s["name"]),
                                      sort: anyInt(s["sort"])))
            }
        }
        chapters = chs.sorted { $0.sort < $1.sort }
    }

    /// Chapter id to open when the user taps "start reading" with no progress.
    var firstChapterId: String { chapters.first?.id ?? id }
}

struct ChapterData {
    var id: String
    var name: String
    var images: [String]   // file names like "00001.webp"
    var series: [ChapterRef]

    init(dict d: [String: Any]) {
        id = anyString(d["id"])
        name = anyString(d["name"])
        images = anyStringList(d["images"])
        var chs: [ChapterRef] = []
        if let series = d["series"] as? [Any] {
            for case let s as [String: Any] in series {
                chs.append(ChapterRef(id: anyString(s["id"]),
                                      name: anyString(s["name"]),
                                      sort: anyInt(s["sort"])))
            }
        }
        series = chs.sorted { $0.sort < $1.sort }
    }
}

// MARK: - daily check-in

struct DailyDay: Identifiable {
    let date: String
    let signed: Bool?
    let bonus: Bool
    var id: String { date }
}

struct DailyInfo {
    let dailyId: Int
    let eventName: String
    let progress: String
    let threeCoin: String
    let sevenCoin: String
    let makeupUsed: Int
    let makeupLimit: Int
    let weeks: [[DailyDay]]

    init(dict: [String: Any]) {
        dailyId = (dict["daily_id"] as? NSNumber)?.intValue ?? 0
        eventName = dict["event_name"] as? String ?? "每日签到"
        progress = dict["currentProgress"] as? String ?? ""
        threeCoin = dict["three_days_coin"] as? String ?? "30"
        sevenCoin = dict["seven_days_coin"] as? String ?? "500"
        makeupUsed = (dict["makeup_used"] as? NSNumber)?.intValue ?? 0
        makeupLimit = (dict["makeup_limit"] as? NSNumber)?.intValue ?? 0
        var parsed: [[DailyDay]] = []
        if let record = dict["record"] as? [[Any]] {
            for week in record {
                var days: [DailyDay] = []
                for raw in week {
                    guard let d = raw as? [String: Any] else { continue }
                    let signed: Bool?
                    if d["signed"] is NSNull { signed = nil }
                    else if let b = d["signed"] as? Bool { signed = b }
                    else { signed = nil }
                    days.append(DailyDay(date: d["date"] as? String ?? "",
                                         signed: signed,
                                         bonus: d["bonus"] as? Bool ?? false))
                }
                if !days.isEmpty { parsed.append(days) }
            }
        }
        weeks = parsed
    }

    var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "dd"
        return f.string(from: Date())
    }
    var todaySigned: Bool {
        weeks.flatMap { $0 }.first { $0.date == todayString }?.signed == true
    }
    var signedCount: Int {
        weeks.flatMap { $0 }.filter { $0.signed == true }.count
    }
}
