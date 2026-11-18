import Foundation
import SwiftUI
import CryptoKit

/// 云备份（管理员版专用）：把本机数据（进度/历史、统计、屏蔽名单、
/// 设置、下载分类、线路等）打包成一个 JSON，经 GitHub 接口上传到
/// 私有仓库 denia-dev/jm-backup；重装后可一键恢复。
/// 令牌只存本机 Keychain，不进仓库、不进备份内容本身。
enum CloudBackup {
    static let repo = "denia-dev/jm-backup"
    static let path = "backup.json"
    private static let tokenKey = "jmbackup.token"

    static var token: String? {
        let t = Keychain.get(tokenKey)
        return (t?.isEmpty == false) ? t : nil
    }
    static func setToken(_ t: String?) {
        if let t, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.set(tokenKey, t.trimmingCharacters(in: .whitespaces))
        } else {
            Keychain.remove(tokenKey)
        }
    }

    // MARK: - 快照（UserDefaults 全量 jm.* + 指定附加键）

    private static let extraKeys: Set<String> = [
        "reader.mode", "reader.rtl", "settings.autoCheckIn",
        "line.apiPool.v1", "line.imgPool.v1", "line.apiManual.v1",
        "line.imgManual.v1", "line.lastRefresh.v1",
    ]

    static func snapshot() -> (data: Data, hash: String)? {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var packed: [String: String] = [:]
        for (k, v) in all {
            guard k.hasPrefix("jm.") || extraKeys.contains(k) else { continue }
            guard !k.lowercased().contains("update") else { continue }
            guard let plist = try? PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0) else { continue }
            packed[k] = plist.base64EncodedString()
        }
        let env: [String: Any] = [
            "version": 1,
            "createdAt": Date().timeIntervalSince1970,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "defaults": packed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys]) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, hash)
    }

    @discardableResult
    static func applySnapshot(_ data: Data) -> Bool {
        guard let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let packed = env["defaults"] as? [String: String] else { return false }
        let d = UserDefaults.standard
        for (k, b64) in packed {
            guard let plistData = Data(base64Encoded: b64),
                  let v = try? PropertyListSerialization.propertyList(from: plistData, format: nil) else { continue }
            d.set(v, forKey: k)
        }
        return true
    }

    // MARK: - GitHub 接口

    private static func request(_ method: String, body: [String: Any]? = nil) -> URLRequest? {
        guard let token else { return nil }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("JMReader", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private static func remoteSHA() async -> (sha: String?, error: String?) {
        guard let req = request("GET") else { return (nil, "未设置令牌") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return (nil, nil) }
            guard code == 200 else { return (nil, code == 401 || code == 403 ? "令牌无效或无权限" : "读取云端失败（\(code)）") }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (obj?["sha"] as? String, nil)
        } catch {
            return (nil, "网络错误")
        }
    }

    /// 上传备份。force=false 时内容没变会跳过。返回 nil 表示成功，否则错误说明。
    static func upload(force: Bool) async -> String? {
        guard token != nil else { return "未设置令牌" }
        guard let snap = snapshot() else { return "打包失败" }
        let lastHash = UserDefaults.standard.string(forKey: "backup.lastHash")
        if !force, snap.hash == lastHash { return nil }
        let (sha, err) = await remoteSHA()
        if let err { return err }
        var body: [String: Any] = [
            "message": "JM backup \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
            "content": snap.data.base64EncodedString(),
        ]
        if let sha { body["sha"] = sha }
        guard let req = request("PUT", body: body) else { return "未设置令牌" }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 201 else {
                return (code == 401 || code == 403) ? "令牌无效或无权限" : "上传失败（\(code)）"
            }
        } catch {
            return "网络错误"
        }
        UserDefaults.standard.set(snap.hash, forKey: "backup.lastHash")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastAt")
        return nil
    }

    /// 下载并恢复。成功返回 nil，否则错误说明。
    static func restore() async -> String? {
        guard let req = request("GET") else { return "未设置令牌" }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return "云端还没有备份" }
            guard code == 200 else { return (code == 401 || code == 403) ? "令牌无效或无权限" : "下载失败（\(code)）" }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let b64 = obj["content"] as? String,
                  let raw = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else {
                return "云端备份格式不对"
            }
            guard applySnapshot(raw) else { return "云端备份格式不对" }
            // 恢复后本地与云端一致，记下哈希避免自动备份立刻覆盖
            let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(hash, forKey: "backup.lastHash")
            return nil
        } catch {
            return "网络错误"
        }
    }

    static func autoBackupIfNeeded() async {
        guard ADMIN_BUILD, token != nil else { return }
        guard UserDefaults.standard.bool(forKey: "backup.auto") else { return }
        _ = await upload(force: false)
    }
}

// MARK: - 设置页卡片（仅管理员版显示）

struct BackupSettingsCard: View {
    @AppStorage("backup.auto") private var autoEnabled = true
    @AppStorage("backup.lastAt") private var lastAt: Double = 0
    @State private var tokenInput = ""
    @State private var hasToken = CloudBackup.token != nil
    @State private var busy = false
    @State private var status: String?
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundColor(accentPink)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("云备份（管理员）").foregroundColor(.primary)
                    Text(hasToken ? (lastAt > 0 ? "上次备份：\(DateFormatter.localizedString(from: Date(timeIntervalSince1970: lastAt), dateStyle: .short, timeStyle: .short))" : "尚未备份") : "未设置令牌")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !hasToken {
                Divider().padding(.leading, 52)
                HStack(spacing: 8) {
                    SecureField("粘贴 GitHub 令牌", text: $tokenInput)
                        .font(.subheadline)
                    Button("保存") {
                        CloudBackup.setToken(tokenInput)
                        tokenInput = ""
                        hasToken = CloudBackup.token != nil
                        status = hasToken ? "令牌已保存" : "令牌为空"
                    }
                    .foregroundColor(accentPink)
                    .disabled(tokenInput.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(accentPink).frame(width: 24)
                    Text("自动备份").foregroundColor(.primary)
                    Spacer()
                    Toggle("", isOn: $autoEnabled).labelsHidden().tint(accentPink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().padding(.leading, 52)
                HStack(spacing: 10) {
                    Button {
                        Task { await runBackup() }
                    } label: {
                        Text("立即备份").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(accentPink)
                    Button {
                        confirmRestore = true
                    } label: {
                        Text("从云端恢复").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        CloudBackup.setToken(nil)
                        hasToken = false
                        status = "令牌已清除"
                    } label: {
                        Text("换令牌").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if busy { ProgressView() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .padding(.vertical, 6)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .alert("从云端恢复？", isPresented: $confirmRestore) {
            Button("恢复", role: .destructive) { Task { await runRestore() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("云端备份会覆盖本机当前的进度、历史与设置。恢复完成后请杀掉 App 重新打开。")
        }
    }

    private func runBackup() async {
        busy = true
        defer { busy = false }
        if let err = await CloudBackup.upload(force: true) {
            status = "备份失败：\(err)"
        } else {
            lastAt = UserDefaults.standard.double(forKey: "backup.lastAt")
            status = "备份成功"
        }
    }

    private func runRestore() async {
        busy = true
        defer { busy = false }
        if let err = await CloudBackup.restore() {
            status = "恢复失败：\(err)"
        } else {
            status = "已恢复，请杀掉 App 重新打开"
        }
    }
}
