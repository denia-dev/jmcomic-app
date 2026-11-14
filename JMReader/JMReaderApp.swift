import SwiftUI

@main
struct JMReaderApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var library = LibraryStore()
    @StateObject private var history = SearchHistory()
    @StateObject private var account = AccountStore()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var blockStore = BlockTagStore()
    @StateObject private var readingStats = ReadingStatsStore()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $appState.selectedTab) {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house.fill") }
                    .tag(0)
                CategoriesView()
                    .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                    .tag(2)
                FavoritesView()
                    .tabItem { Label("个人", systemImage: "person.fill") }
                    .tag(3)
                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(1)
            }
            .tint(accentPink)
            .tabMinimizeOnScroll()
            .task(id: account.username) {
                await AutoCheckIn.runIfNeeded(account: account)
                await LineStore.shared.refreshIfStale()
            }
            .task { await updater.checkOnLaunch() }
            .alert("有新版本 v\(updater.latestVersion ?? "")", isPresented: $updater.showPrompt) {
                Button("去更新") {
                    if let url = updater.latestURL {
                        UIApplication.shared.open(url)
                    }
                    updater.showPrompt = false
                }
                Button("忽略此版本") { updater.ignoreCurrent() }
                Button("稍后", role: .cancel) { updater.showPrompt = false }
            } message: {
                Text("当前版本 v\(updater.currentVersion)，新版本已发布。点「去更新」打开下载页，下载后重新签名安装即可。")
            }
            .environmentObject(appState)
            .environmentObject(library)
            .environmentObject(history)
            .environmentObject(account)
            .environmentObject(downloads)
            .environmentObject(blockStore)
            .environmentObject(readingStats)
            .environmentObject(updater)
        }
    }
}
