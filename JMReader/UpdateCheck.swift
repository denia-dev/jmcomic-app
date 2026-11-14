import Foundation
import SwiftUI

/// Update prompt: compares the running build against the repo's latest
/// PUBLISHED release on GitHub (public repo, plain unauthenticated GET;
/// drafts never appear in that endpoint, so only formal releases prompt).
/// A tap on 「去更新」 opens the release page in the browser, where the
/// user downloads and re-signs the new IPA as usual.
///
/// Version numbers follow the project's decimal scheme (…2.19 -> 2.2),
/// so a Double compare is exact for them.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestURL: URL?
    @Published private(set) var checking = false
    @Published var showPrompt = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var hasUpdate: Bool {
        guard let latest = latestVersion,
              let l = Double(latest), let c = Double(currentVersion) else { return false }
        return l > c
    }

    private let lastCheckKey = "jm.update.lastCheck.v1"
    private let ignoredKey = "jm.update.ignoredVersion.v1"

    /// Silent launch check, throttled to once per 6 hours. The prompt
    /// fires at most once per version unless the user asks manually:
    /// 「忽略此版本」 is remembered per version.
    func checkOnLaunch() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last < 6 * 3600, latestVersion != nil { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        if checking { return }
        checking = true
        defer { checking = false }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/denia-dev/jmcomic-app/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlStr = obj["html_url"] as? String,
              let url = URL(string: urlStr)
        else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestURL = url
        if hasUpdate {
            let ignored = UserDefaults.standard.string(forKey: ignoredKey)
            if manual || ignored != latestVersion { showPrompt = true }
        }
    }

    func ignoreCurrent() {
        if let v = latestVersion {
            UserDefaults.standard.set(v, forKey: ignoredKey)
        }
        showPrompt = false
    }
}
