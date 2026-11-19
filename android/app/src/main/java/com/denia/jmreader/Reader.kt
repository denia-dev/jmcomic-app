package com.denia.jmreader

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.view.HapticFeedbackConstants
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Small in-memory cache of decoded reader pages. The next-chapter
 * preload warms it, and ReaderPage reads through it, so flipping to the
 * next chapter shows its first pages instantly. Capped; eldest evicted. */
object ReaderCache {
    private val map = object : LinkedHashMap<String, Bitmap>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>): Boolean = size > 28
    }
    @Synchronized fun get(chapterId: String, file: String): Bitmap? = map["$chapterId/$file"]
    @Synchronized fun put(chapterId: String, file: String, bmp: Bitmap) { map["$chapterId/$file"] = bmp }
}

/** Chapter-info cache: stepping chapters (above all the preloaded next
 * one) swaps in place without a network round-trip. */
object ReaderDataCache {
    private val map = object : LinkedHashMap<String, JSONObject>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, JSONObject>): Boolean = size > 6
    }
    @Synchronized fun get(id: String): JSONObject? = map[id]
    @Synchronized fun put(id: String, data: JSONObject) { map[id] = data }
}

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

private fun LazyListState.isAtEnd(): Boolean {
    val info = layoutInfo
    val last = info.visibleItemsInfo.lastOrNull() ?: return false
    return last.index >= info.totalItemsCount - 1 &&
        last.offset + last.size <= info.viewportEndOffset + 1
}

@Composable
fun ReaderScreen(dest: ReaderDest, router: Router) {
    // Internal chapter state: stepping chapters swaps in place (like iOS)
    // instead of pop+push, so the pull transition can swap underneath its
    // cover. The reader is still a single destination — back pops it once.
    var cur by remember(dest) { mutableStateOf(dest) }
    val chapterId = cur.chapterId
    var chapter by remember(chapterId) { mutableStateOf<JSONObject?>(ReaderDataCache.get(chapterId)) }
    var error by remember(chapterId) { mutableStateOf<String?>(null) }
    var nextPreview by remember(chapterId) { mutableStateOf<Bitmap?>(null) }
    var nextInfo by remember(chapterId) { mutableStateOf<Pair<String, String>?>(null) }
    val preloadScope = remember { CoroutineScope(SupervisorJob() + Dispatchers.IO) }
    var preloadJob by remember(chapterId) { mutableStateOf<Job?>(null) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var mode by remember { mutableStateOf(Settings.readerMode) }
    var rtl by remember { mutableStateOf(Settings.readerRtl) }
    var pageIdx by remember(chapterId) { mutableIntStateOf(0) }

    // Immersive chrome: bars float over the content; hidden = system bars
    // hidden too. Back restores the bars before it pops (fork's pattern).
    var chromeVisible by remember { mutableStateOf(true) }
    val view = LocalView.current
    val context = LocalContext.current
    LaunchedEffect(chromeVisible) {
        val window = context.findActivity()?.window ?: return@LaunchedEffect
        val controller = WindowInsetsControllerCompat(window, view)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (chromeVisible) controller.show(WindowInsetsCompat.Type.systemBars())
        else controller.hide(WindowInsetsCompat.Type.systemBars())
    }
    DisposableEffect(Unit) {
        onDispose {
            context.findActivity()?.window?.let {
                WindowInsetsControllerCompat(it, view).show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }
    BackHandler(enabled = !chromeVisible) { chromeVisible = true }

    // Pull-to-next-chapter transition state (scroll mode), mirroring iOS
    // build 75/76: the next chapter's first page rises with the pull,
    // covers the screen on a committed release, the chapter swaps
    // underneath, and the cover crossfades away.
    val pullState = remember { mutableFloatStateOf(0f) }
    val coverAlphaState = remember { mutableFloatStateOf(1f) }
    val coverState = remember { mutableStateOf(false) }
    val transState = remember { mutableStateOf(false) }
    var transitionTarget by remember { mutableStateOf<String?>(null) }
    var containerHeightPx by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val pullCapPx = with(density) { 340.dp.toPx() }
    val pullThresholdPx = with(density) { 70.dp.toPx() }

    fun springBackPull() {
        scope.launch {
            Animatable(pullState.value).animateTo(0f, tween(200)) { pullState.value = value }
        }
    }

    fun commitNextChapter() {
        val next = nextInfo ?: return
        if (transState.value) return
        transState.value = true
        coverState.value = true
        transitionTarget = next.first
        view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        scope.launch {
            Animatable(pullState.value).animateTo(
                containerHeightPx.toFloat().coerceAtLeast(1f), tween(220)
            ) { pullState.value = value }
            cur = ReaderDest(next.first, cur.albumTitle, cur.albumId)
            Animatable(1f).animateTo(0f, tween(250)) { coverAlphaState.value = value }
            pullState.value = 0f
            coverAlphaState.value = 1f
            coverState.value = false
            transitionTarget = null
            transState.value = false
        }
    }

    // Release detection: when the scroll settles, a pull past the
    // threshold commits; a shorter pull springs back on its own.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling && !transState.value && mode == "scroll") {
                if (pullState.value >= pullThresholdPx && nextInfo != null) commitNextChapter()
                else if (pullState.value > 0f) springBackPull()
            }
        }
    }

    val pullConnection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                // Dragging back down while pulled: give the pull back
                // before the list itself scrolls.
                if (source == NestedScrollSource.Drag && pullState.value > 0f && available.y > 0f) {
                    val take = minOf(available.y, pullState.value)
                    pullState.value -= take
                    return Offset(0f, take)
                }
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.Drag && !transState.value &&
                    available.y < 0f && listState.isAtEnd()
                ) {
                    pullState.value = minOf(pullState.value + (-available.y) * 0.55f, pullCapPx)
                    return available
                }
                return Offset.Zero
            }
        }
    }

    LaunchedEffect(chapterId) {
        runCatching { listState.scrollToItem(0) }
        var ch = chapter
        if (ch == null) {
            try {
                ch = JmApi.chapter(chapterId)
                ReaderDataCache.put(chapterId, ch)
                chapter = ch
            } catch (e: Exception) { error = e.message; return@LaunchedEffect }
        }
        ReadingStats.recordChapter(
            albumId = cur.albumId.ifEmpty { chapterId },
            chapterId = chapterId)
        // Next-chapter preload (bounded, sequential — the iOS build-40
        // lesson): chapter data + the first 6 pages only, warmed into the
        // caches one at a time instead of a parallel storm. The first
        // page also becomes the pull-transition preview.
        val series = parseSeries(ch, chapterId)
        val idx = series.indexOfFirst { it.first == chapterId }
        val next = if (idx >= 0 && idx < series.size - 1) series[idx + 1] else null
        nextInfo = next
        if (next != null) {
            preloadJob?.cancel()
            preloadJob = preloadScope.launch {
                try {
                    val nch = JmApi.chapter(next.first)
                    ReaderDataCache.put(next.first, nch)
                    val nimgs = nch.optJSONArray("images")
                    val nfiles = (0 until (nimgs?.length() ?: 0)).map { nimgs!!.optString(it) }
                    for ((n, f) in nfiles.take(6).withIndex()) {
                        if (ReaderCache.get(next.first, f) == null) {
                            val bytes = JmApi.fetchPhoto(next.first, f)
                            ReaderCache.put(next.first, f, Descramble.decode(bytes, next.first, f))
                        }
                        if (n == 0) nextPreview = ReaderCache.get(next.first, f)
                    }
                } catch (e: Exception) { /* preload is best-effort */ }
            }
        }
    }
    LaunchedEffect(chapterId) {
        while (true) { delay(10_000); ReadingStats.addSeconds(10) }
    }
    DisposableEffect(chapterId) { onDispose { preloadJob?.cancel() } }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .onSizeChanged { containerHeightPx = it.height }
    ) {
        val ch = chapter
        if (ch == null) {
            Column(Modifier.fillMaxSize()) {
                TopBar(title = cur.albumTitle) { router.pop() }
                if (error != null) ErrorText(error!!) else LoadingBox()
            }
        } else {
            val imagesArr = ch.optJSONArray("images")
            val files = (0 until (imagesArr?.length() ?: 0)).map { imagesArr!!.optString(it) }
            val series = parseSeries(ch, chapterId)
            val curIdx = series.indexOfFirst { it.first == chapterId }
            val scrollPage by remember { derivedStateOf { (listState.firstVisibleItemIndex + 1).coerceIn(1, maxOf(1, files.size)) } }
            val pageNow = if (mode == "page") (pageIdx + 1).coerceIn(1, maxOf(1, files.size)) else scrollPage
            // Reading stats: count pages as they are actually reached
            // (both modes funnel through pageNow), never the whole
            // chapter at open.
            LaunchedEffect(pageNow, chapterId) {
                ReadingStats.recordPage(chapterId, pageNow - 1, files.size)
                ReadHistory.record(cur.albumId, cur.albumTitle, chapterId, pageNow)
            }

            fun stepChapter(delta: Int) {
                val next = curIdx + delta
                if (next !in series.indices) return
                cur = ReaderDest(series[next].first, cur.albumTitle, cur.albumId)
            }

            // Content (full-bleed; the chrome floats over it).
            if (mode == "page" && files.isNotEmpty()) {
                val idx = pageIdx.coerceIn(0, files.size - 1)
                Box(Modifier.fillMaxSize()) {
                    ReaderPage(chapterId, files[idx])
                    Row(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(0.3f).fillMaxHeight().pointerInput(chapterId) {
                            detectTapGestures {
                                pageIdx = (if (rtl) pageIdx + 1 else pageIdx - 1)
                                    .coerceIn(0, maxOf(0, files.size - 1))
                            }
                        })
                        Box(Modifier.weight(0.4f).fillMaxHeight().pointerInput(chapterId) {
                            detectTapGestures { chromeVisible = !chromeVisible }
                        })
                        Box(Modifier.weight(0.3f).fillMaxHeight().pointerInput(chapterId) {
                            detectTapGestures {
                                pageIdx = (if (rtl) pageIdx - 1 else pageIdx + 1)
                                    .coerceIn(0, maxOf(0, files.size - 1))
                            }
                        })
                    }
                }
            } else {
                Box(
                    Modifier.fillMaxSize().pointerInput(chapterId) {
                        detectTapGestures {
                            // Anti-mistouch: a tap landing while the list
                            // is still scrolling/flinging doesn't toggle.
                            if (!listState.isScrollInProgress && !transState.value) {
                                chromeVisible = !chromeVisible
                            }
                        }
                    }
                ) {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize().nestedScroll(pullConnection)
                    ) {
                        itemsIndexed(files, key = { i, f -> "$i-$f" }) { _, file ->
                            ReaderPage(chapterId, file)
                        }
                        item {
                            Column(
                                Modifier.fillMaxWidth().padding(top = 28.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("— 本话完 —", color = Color.Gray, fontSize = 12.sp)
                                Spacer(Modifier.height(96.dp))
                            }
                        }
                    }
                }
            }

            // Top chrome (overlay).
            AnimatedVisibility(
                visible = chromeVisible,
                enter = fadeIn() + slideInVertically { -it },
                exit = fadeOut() + slideOutVertically { -it },
                modifier = Modifier.align(Alignment.TopCenter)
            ) {
                Column(
                    Modifier.fillMaxWidth().background(
                        Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.75f), Color.Transparent))
                    ).windowInsetsPadding(WindowInsets.statusBars)
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(onClick = { router.pop() }) { Text("‹ 返回", color = Pink, fontSize = 15.sp) }
                        Column(Modifier.weight(1f)) {
                            Text(
                                ch.optString("name").ifEmpty { cur.albumTitle }, fontSize = 14.sp,
                                fontWeight = FontWeight.Bold, color = Color.White,
                                maxLines = 1, overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                cur.albumTitle, fontSize = 11.sp, color = Color.White.copy(alpha = 0.65f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis
                            )
                        }
                        Text("$pageNow / ${files.size}", fontSize = 12.sp, color = Color.White.copy(alpha = 0.8f))
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        TextButton(onClick = {
                            mode = if (mode == "page") "scroll" else "page"
                            Settings.updateReaderMode(mode)
                            if (mode == "page") pageIdx = (scrollPage - 1).coerceIn(0, maxOf(0, files.size - 1))
                        }) { Text(if (mode == "page") "翻页模式 · 切回滚动" else "滚动模式 · 切到翻页", color = Pink, fontSize = 12.sp) }
                        Spacer(Modifier.weight(1f))
                        if (mode == "page") {
                            TextButton(onClick = { rtl = !rtl; Settings.updateReaderRtl(rtl) }) {
                                Text(if (rtl) "方向：从右往左" else "方向：从左往右", color = Pink, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }

            // Bottom chrome (overlay): chapter stepping.
            AnimatedVisibility(
                visible = chromeVisible,
                enter = fadeIn() + slideInVertically { it },
                exit = fadeOut() + slideOutVertically { it },
                modifier = Modifier.align(Alignment.BottomCenter)
            ) {
                Box(
                    Modifier.fillMaxWidth().background(
                        Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f)))
                    ).windowInsetsPadding(WindowInsets.navigationBars)
                ) {
                    ChapterNavRow(curIdx, series) { delta -> stepChapter(delta) }
                }
            }
        }

        // Pull-transition overlay (topmost): follows the pull, covers on
        // commit, crossfades away over the new chapter's first page.
        if (mode == "scroll" && (pullState.value > 0f || coverState.value)) {
            val stripPx = pullState.value
            Box(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .height(with(density) { stripPx.toDp() })
                    .clipToBounds()
                    .alpha(coverAlphaState.value)
                    .background(Color.Black)
                    .pointerInput(Unit) {
                        // Swallow stray touches while the transition is up.
                        awaitPointerEventScope {
                            while (true) {
                                awaitPointerEvent().changes.forEach { it.consume() }
                            }
                        }
                    }
            ) {
                nextPreview?.let { bmp ->
                    Image(
                        bmp.asImageBitmap(), contentDescription = null,
                        contentScale = ContentScale.FillWidth,
                        modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter)
                    )
                }
                val next = nextInfo
                if (next != null && (stripPx > with(density) { 60.dp.toPx() } || coverState.value)) {
                    Text(
                        "下一话 · ${next.second}",
                        color = Color.White, fontSize = 12.sp,
                        modifier = Modifier.align(Alignment.TopCenter)
                            .padding(top = if (coverState.value) 54.dp else 10.dp)
                            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 6.dp)
                    )
                }
                if (coverState.value && transitionTarget != null && chapterId != transitionTarget) {
                    CircularProgressIndicator(
                        color = Pink,
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
            }
        }
    }
}

@Composable
private fun ChapterNavRow(curIdx: Int, series: List<Pair<String, String>>, onStep: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(18.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        if (curIdx > 0) {
            OutlinedButton(onClick = { onStep(-1) }) { Text("上一章", color = Pink) }
        } else Spacer(Modifier.width(1.dp))
        if (curIdx >= 0 && curIdx < series.size - 1) {
            Button(
                onClick = { onStep(1) },
                colors = ButtonDefaults.buttonColors(containerColor = Pink)
            ) {
                Text("下一章", color = Color.White)
            }
        }
    }
}

@Composable
private fun ReaderPage(chapterId: String, file: String) {
    var bmp by remember(chapterId, file) { mutableStateOf<Bitmap?>(ReaderCache.get(chapterId, file)) }
    var failed by remember(chapterId, file) { mutableStateOf(false) }
    LaunchedEffect(chapterId, file) {
        if (bmp != null) return@LaunchedEffect
        try {
            val bytes = JmApi.fetchPhoto(chapterId, file)
            val decoded = Descramble.decode(bytes, chapterId, file)
            ReaderCache.put(chapterId, file, decoded)
            bmp = decoded
        } catch (e: Exception) { failed = true }
    }
    val b = bmp
    if (b != null) {
        Image(
            b.asImageBitmap(), contentDescription = null,
            contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth()
        )
    } else {
        Box(Modifier.fillMaxWidth().aspectRatio(0.72f), contentAlignment = Alignment.Center) {
            if (failed) Text("这一页加载失败", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
            else CircularProgressIndicator(color = Pink)
        }
    }
}
