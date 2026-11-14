import Foundation
import SwiftUI
import Combine
import UIKit

// MARK: - minimal PDF writer (one image per page, streamed page by page)

enum PdfWriter {
    /// entries are (label, JPEG file on disk) in reading order; images are loaded one at a time.
    static func write(entries: [(name: String, file: URL)], to url: URL) throws {
        guard let first = entries.first,
              let firstImg = UIImage(contentsOfFile: first.file.path) else {
            throw NSError(domain: "PdfWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可写入的页面"])
        }
        UIGraphicsBeginPDFContextToFile(url.path, CGRect(origin: .zero, size: firstImg.size), nil)
        defer { UIGraphicsEndPDFContext() }
        for e in entries {
            guard let img = UIImage(contentsOfFile: e.file.path) else { continue }
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: img.size), nil)
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }
}

// MARK: - completed downloads store

struct DownloadedRecord: Codable, Identifiable {
    var albumId: String
    var title: String
    var chapters: Int
    var pages: Int
    var bytes: Int64
    var fileName: String
    var date: Double
    var id: String { albumId }
    var fileURL: URL { DownloadedStore.documents.appendingPathComponent(fileName) }
}

final class DownloadedStore: ObservableObject {
    @Published private(set) var records: [DownloadedRecord] = []
    private let storeURL: URL
    /// JM category per downloaded album, kept OUT of downloads.json so old
    /// libraries decode untouched; filled at download time ("" = 未分类).
    private(set) var categoryMap: [String: String] = [:]
    private let categoryKey = "jm.dlCategories.v1"
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    init() {
        storeURL = Self.documents.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([DownloadedRecord].self, from: data) {
            records = list
        }
        if let data = UserDefaults.standard.data(forKey: categoryKey),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            categoryMap = map
        }
    }

    func category(for albumId: String) -> String { categoryMap[albumId] ?? "" }

    func setCategory(_ category: String, for albumId: String) {
        guard !category.isEmpty, categoryMap[albumId] != category else { return }
        categoryMap[albumId] = category
        if let d = try? JSONEncoder().encode(categoryMap) {
            UserDefaults.standard.set(d, forKey: categoryKey)
        }
        objectWillChange.send()
    }

    func record(for albumId: String) -> DownloadedRecord? { records.first { $0.albumId == albumId } }

    func add(_ r: DownloadedRecord) {
        records.removeAll { $0.albumId == r.albumId }
        records.insert(r, at: 0)
        persist()
    }

    func delete(_ r: DownloadedRecord) {
        try? FileManager.default.removeItem(at: r.fileURL)
        records.removeAll { $0.albumId == r.albumId }
        if categoryMap[r.albumId] != nil {
            categoryMap[r.albumId] = nil
            if let d = try? JSONEncoder().encode(categoryMap) {
                UserDefaults.standard.set(d, forKey: categoryKey)
            }
        }
        persist()
    }

    /// On-disk footprint of the downloaded PDFs, for the storage page.
    static func diskUsage() -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for url in entries where url.pathExtension.lowercased() == "pdf" {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                bytes += Int64(size)
                files += 1
            }
        }
        return (bytes, files)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: storeURL, options: .atomic) }
    }
}

// MARK: - download jobs

final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let albumId: String
    let title: String
    var category: String = ""
    enum State { case queued, working, done, failed, cancelled }
    @Published var state: State = .queued
    @Published var totalPages = 0
    @Published var donePages = 0
    @Published var bytes: Int64 = 0
    @Published var speedBps: Double = 0
    @Published var phase: String = "排队中"

    init(albumId: String, title: String) {
        self.albumId = albumId
        self.title = title
    }

    var fraction: Double { totalPages > 0 ? Double(donePages) / Double(totalPages) : 0 }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    let store = DownloadedStore()
    private var running = false
    private var currentTask: Task<Void, Never>?
    private var currentJobId: UUID?
    private var cancellables = Set<AnyCancellable>()

    init() {
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func job(for albumId: String) -> DownloadJob? {
        jobs.first { $0.albumId == albumId && ($0.state == .queued || $0.state == .working) }
    }

    func enqueue(albumId: String, title: String, category: String = "") {
        if job(for: albumId) != nil { return }
        jobs.removeAll { $0.albumId == albumId && $0.state != .done }
        let j = DownloadJob(albumId: albumId, title: title)
        j.category = category
        jobs.append(j)
        pump()
    }

    func cancel(_ job: DownloadJob) {
        if job.id == currentJobId {
            job.state = .cancelled
            currentTask?.cancel()
        } else {
            job.state = .cancelled
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled || $0.state == .failed }
    }

    private func pump() {
        guard !running, let next = jobs.first(where: { $0.state == .queued }) else { return }
        running = true
        currentJobId = next.id
        currentTask = Task { [weak self] in
            await self?.run(next)
            self?.running = false
            self?.currentJobId = nil
            self?.pump()
        }
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(60)).isEmpty ? "comic" : String(cleaned.prefix(60))
    }

    private func run(_ job: DownloadJob) async {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("jm-dl-\(job.albumId)-\(job.id.uuidString)")
        job.state = .working
        job.phase = "获取章节列表…"
        do {
            let album = try await JMClient.shared.album(id: job.albumId)
            if job.category.isEmpty { job.category = album.categoryTitle }
            let chapters: [ChapterRef] = album.chapters.isEmpty
                ? [ChapterRef(id: album.id, name: album.name, sort: 1)]
                : album.chapters
            var plan: [(chapter: ChapterRef, images: [String])] = []
            for ch in chapters {
                if Task.isCancelled { throw CancellationError() }
                let cd = try await JMClient.shared.chapter(id: ch.id)
                plan.append((ch, cd.images))
            }
            job.totalPages = plan.reduce(0) { $0 + $1.images.count }
            guard job.totalPages > 0 else {
                job.state = .failed
                job.phase = "没有可下载的页面"
                return
            }
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            var entries: [(name: String, file: URL)] = []
            var samples: [(Date, Int64)] = [(Date(), 0)]
            let multi = plan.count > 1

            for (ci, item) in plan.enumerated() {
                job.phase = multi ? "下载 \(item.chapter.name)（\(ci + 1)/\(plan.count)）" : "下载中…"
                let files = item.images
                var idx = 0
                while idx < files.count {
                    if Task.isCancelled { throw CancellationError() }
                    let batch = Array(files[idx..<min(idx + 3, files.count)])
                    let base = idx
                    let chapId = item.chapter.id
                    let results: [(Int, URL?)] = await withTaskGroup(of: (Int, URL?).self) { group in
                        for (off, file) in batch.enumerated() {
                            let pageIndex = base + off
                            group.addTask {
                                let stem = (file as NSString).deletingPathExtension
                                let num = ImagePipe.splitNum(chapterId: chapId, stem: stem)
                                guard let data = await ImagePipe.shared.loadJPEG(
                                    path: ImagePipe.pagePath(chapterId: chapId, file: file),
                                    scrambleNum: num) else { return (pageIndex, nil) }
                                let dest = tmp.appendingPathComponent("\(ci)-\(pageIndex).jpg")
                                do { try data.write(to: dest); return (pageIndex, dest) }
                                catch { return (pageIndex, nil) }
                            }
                        }
                        var collected: [(Int, URL?)] = []
                        for await r in group { collected.append(r) }
                        return collected
                    }
                    for (pageIndex, fileURL) in results.sorted(by: { $0.0 < $1.0 }) {
                        job.donePages += 1
                        if let fileURL {
                            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                            job.bytes += size
                            let name = multi
                                ? String(format: "%03d-%@/%05d.jpg", ci + 1, Self.sanitize(item.chapter.name), pageIndex + 1)
                                : String(format: "%05d.jpg", pageIndex + 1)
                            entries.append((name, fileURL))
                        }
                        let now = Date()
                        samples.append((now, job.bytes))
                        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
                        if let first = samples.first, samples.count > 1 {
                            let dt = now.timeIntervalSince(first.0)
                            if dt > 0.5 { job.speedBps = Double(job.bytes - first.1) / dt }
                        }
                    }
                    idx += batch.count
                }
            }

            if Task.isCancelled { throw CancellationError() }
            job.phase = "打包中…"
            job.speedBps = 0
            let fileName = "\(job.albumId) - \(Self.sanitize(job.title)).pdf"
            let dest = DownloadedStore.documents.appendingPathComponent(fileName)
            try? fm.removeItem(at: dest)
            try PdfWriter.write(entries: entries, to: dest)
            let totalBytes = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            store.add(DownloadedRecord(albumId: job.albumId, title: job.title,
                                        chapters: plan.count, pages: entries.count,
                                        bytes: totalBytes, fileName: fileName,
                                        date: Date().timeIntervalSince1970))
            store.setCategory(job.category, for: job.albumId)
            job.state = .done
            job.phase = "完成"
        } catch is CancellationError {
            job.state = .cancelled
            job.phase = "已取消"
        } catch {
            if Task.isCancelled {
                job.state = .cancelled
                job.phase = "已取消"
            } else {
                job.state = .failed
                job.phase = "下载失败，检查网络后重试"
            }
        }
    }
}

// MARK: - downloads screen

struct DownloadsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var downloads: DownloadManager

    private func fmtSize(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    private func fmtSpeed(_ s: Double) -> String {
        if s <= 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file) + "/s"
    }

    var embedded = false

    private var listView: some View {
        List {
                if !downloads.jobs.isEmpty {
                    Section("下载队列") {
                        ForEach(downloads.jobs) { job in
                            JobRow(job: job, fmtSpeed: fmtSpeed)
                        }
                    }
                }
                Section {
                    if downloads.store.records.isEmpty {
                        Text("还没有已下载的漫画\n在任意漫画详情页点「下载」就会存到这里")
                            .foregroundColor(.secondary).font(.subheadline)
                    } else {
                        ForEach(downloads.store.records) { rec in
                            HStack(spacing: 12) {
                                RemoteImage(path: ImagePipe.coverPath(albumId: rec.albumId))
                                    .frame(width: 40, height: 54).clipped().cornerRadius(6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rec.title).font(.subheadline).fontWeight(.semibold).lineLimit(2)
                                    Text("\(rec.chapters) 话 · \(rec.pages) 页 · \(fmtSize(rec.bytes))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                ShareLink(item: rec.fileURL) {
                                    Image(systemName: "square.and.arrow.up").foregroundColor(accentPink)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                            .background {
                                if rec.fileURL.pathExtension.lowercased() == "pdf" {
                                    NavigationLink(destination: LocalPdfView(url: rec.fileURL, title: rec.title)) {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { downloads.store.delete(downloads.store.records[i]) }
                        }
                    }
                } header: {
                    Text("已下载")
                } footer: {
                    Text("点已下载的条目即可在 App 里直接打开阅读（PDF）；文件也保存在「文件」App → 我的 iPhone → JM Reader 里。左滑可删除。")
                }
            }
            .tabMinimizeOnScroll()
            .navigationTitle("下载")
                                    .toolbar {
                if downloads.jobs.contains(where: { $0.state == .done || $0.state == .failed || $0.state == .cancelled }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除记录") { downloads.clearFinished() }
                    }
                }
            }
    }

    var body: some View {
        if embedded {
            listView
        } else {
            NavigationStack { listView.withDestinations() }
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: DownloadJob
    var fmtSpeed: (Double) -> String
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                Spacer()
                switch job.state {
                case .queued, .working:
                    Button("取消") { downloads.cancel(job) }.font(.caption)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed:
                    Button("重试") { downloads.enqueue(albumId: job.albumId, title: job.title) }.font(.caption)
                case .cancelled:
                    Text("已取消").font(.caption).foregroundColor(.secondary)
                }
            }
            if job.state == .working || job.state == .queued {
                ProgressView(value: job.fraction)
                    .tint(accentPink)
                HStack {
                    Text(job.phase).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(job.donePages)/\(job.totalPages) 页 · \(fmtSpeed(job.speedBps))")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text(job.phase).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
