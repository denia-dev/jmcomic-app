package com.denia.jmreader

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var pdfUri by mutableStateOf<android.net.Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Immersive top: transparent status bar, the wallpaper gradient runs
        // edge to edge; content keeps its own status-bar inset padding.
        enableEdgeToEdge()
        if (savedInstanceState == null && intent?.action == android.content.Intent.ACTION_VIEW) {
            pdfUri = intent.data
        }
        setContent { JmApp(pdfUri) { pdfUri = null } }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        // A launcher (MAIN) entry must clear any stale external-PDF state,
        // otherwise the app would keep reopening that PDF instead of its own UI.
        pdfUri = if (intent.action == android.content.Intent.ACTION_VIEW) intent.data else null
    }
}

/** Copies a PDF handed to us by the system (e.g. tapped in the Files app) to a local
 *  file, then hands it to the viewer via [onReady]; the Uri itself is consumed at once. */
@Composable
fun ExternalPdfOpener(uri: android.net.Uri, onReady: (java.io.File) -> Unit, onFail: () -> Unit) {
    val context = LocalContext.current
    LaunchedEffect(uri) {
        val dest = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                val out = java.io.File(context.cacheDir, "opened-external.pdf")
                val input = context.contentResolver.openInputStream(uri) ?: error("no stream")
                input.use { inp -> out.outputStream().use { o -> inp.copyTo(o) } }
                out
            }.getOrNull()
        }
        if (dest != null) onReady(dest) else onFail()
    }
    Box(Modifier.fillMaxSize())
}

// Display order: 首页 / 分类 / 个人 / 搜索 (same as the iOS app)
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun JmApp(externalPdf: android.net.Uri? = null, onExternalPdfDone: () -> Unit = {}) {
    val context = LocalContext.current
    val account = remember { AccountStore(context).apply { syncApi() } }
    val library = remember { LibraryStore(context) }
    val history = remember { HistoryStore(context) }
    remember { BlockTags.init(context); ReadingStats.init(context); RemovedFavs.init(context); ReadHistory.init(context); LocalBooks.init(context) }
    remember { Lines.init(context) }
    remember { Settings.init(context) }
    remember { FolderRegistry.init(context) }
    LaunchedEffect(Unit) {
        JmApi.imgHost = Lines.currentImgHost()
        launch { Lines.refresh(false) }
    }
    LaunchedEffect(Unit) { UpdateCheck.checkOnLaunch(context) }
    val router = remember { Router() }
    val pagerState = rememberPagerState(pageCount = { 4 })
    val scope = rememberCoroutineScope()
    val tab = pagerState.currentPage

    BackHandler(enabled = router.stack.isNotEmpty()) { router.pop() }
    BackHandler(enabled = router.stack.isEmpty() && tab != 0) {
        scope.launch { pagerState.animateScrollToPage(0) }
    }

    var viewingExternal by remember { mutableStateOf<java.io.File?>(null) }
    JmTheme {
        if (UpdateCheck.showPrompt) UpdatePromptDialog(context)
        if (viewingExternal != null) {
            PdfViewerScreen(viewingExternal!!) { viewingExternal = null }
            return@JmTheme
        }
        if (externalPdf != null) {
            ExternalPdfOpener(externalPdf,
                onReady = { f -> viewingExternal = f; onExternalPdfDone() },
                onFail = { onExternalPdfDone() })
            return@JmTheme
        }
        // Liquid glass tab bar (:liquidglass module, QmDeve library). The bar
        // floats over a reserved 92dp strip: page content still never slides
        // underneath it (the strip is empty space over the wallpaper
        // gradient), and the glass samples the recorded scene behind it.
        val wallpaper = rememberGlassBackdrop()
        val scene = rememberGlassBackdrop()
        CompositionLocalProvider(LocalGlassBackdrop provides wallpaper) {
        Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().glassBackdrop(scene)) {
            Box(Modifier.fillMaxSize().glassBackdrop(wallpaper)) { GlassWallpaper() }
            Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f).fillMaxWidth()
                .windowInsetsPadding(androidx.compose.foundation.layout.WindowInsets.statusBars)) {
                val top = router.stack.lastOrNull()
                if (top == null) {
                    HorizontalPager(state = pagerState) { page ->
                        when (page) {
                            0 -> HomeScreen(router,
                                goProfile = { scope.launch { pagerState.animateScrollToPage(2) } },
                                goSearch = { scope.launch { pagerState.animateScrollToPage(3) } })
                            1 -> BookshelfScreen(router)
                            2 -> ProfileScreen(router, account, library)
                            else -> SearchScreen(router, history)
                        }
                    }
                } else {
                    when (top) {
                        is DetailDest -> DetailScreen(top, router, account, library)
                        is ReaderDest -> ReaderScreen(top, router)
                        is AuthorDest -> AuthorScreen(top, router)
                        is CategoryDest -> CategoryPage(top, router)
                        is LocalComicDest -> LocalReaderHost(top, router)
                        is LocalNovelDest -> LocalReaderHost(top, router)
                        DownloadsDest -> DownloadsScreen(router)
                        BlockedTagsDest -> BlockedTagsScreen(router)
                        StorageDest -> StorageScreen(router)
                        SettingsDest -> SettingsScreen(router, account)
                        LinesDest -> LinesScreen(router)
                    }
                }
            }
                if (router.stack.isEmpty()) {
                    androidx.compose.foundation.layout.Spacer(Modifier.height(92.dp))
                }
            }
        }
        if (router.stack.isEmpty()) {
            LiquidGlassBottomBar(
                selectedPage = tab,
                pagePosition = pagerState.currentPage + pagerState.currentPageOffsetFraction,
                backdrop = scene,
                onSelect = { page -> scope.launch { pagerState.animateScrollToPage(page) } },
                modifier = Modifier.align(Alignment.BottomCenter)
                    .padding(horizontal = 20.dp, vertical = 18.dp),
            )
        }
        }
        }
    }
}
