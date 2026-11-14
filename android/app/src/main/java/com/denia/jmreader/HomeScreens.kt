package com.denia.jmreader

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun AlbumCard(album: JmApi.Album, router: Router, modifier: Modifier = Modifier) {
    Column(modifier.clickable { router.push(DetailDest(album.id)) }) {
        CoverImage(album.id, Modifier.fillMaxWidth())
        Text(album.name, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 12.sp, lineHeight = 15.sp,
            modifier = Modifier.padding(top = 4.dp))
        if (album.author.isNotEmpty()) {
            Text(album.author, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
fun PagedGrid(loader: suspend (Int) -> List<JmApi.Album>, router: Router, key: Any) {
    var items by remember(key) { mutableStateOf<List<JmApi.Album>>(emptyList()) }
    var page by remember(key) { mutableIntStateOf(0) }
    var loading by remember(key) { mutableStateOf(false) }
    var error by remember(key) { mutableStateOf<String?>(null) }
    var hasMore by remember(key) { mutableStateOf(true) }
    val gridState = rememberLazyGridState()

    suspend fun load(next: Int) {
        loading = true
        try {
            // Page 1 used to fail silently/vanish on a transient API error
            // (e.g. the search page's recommendations) — retry it twice.
            var got: List<JmApi.Album>? = null
            var lastErr: Exception? = null
            val attempts = if (next == 1) 3 else 1
            for (a in 1..attempts) {
                try { got = loader(next); break }
                catch (e: Exception) { lastErr = e; if (a < attempts) delay(1500L * a) }
            }
            val result = got ?: throw (lastErr ?: Exception("加载失败"))
            items = if (next == 1) result else items + result
            page = next
            if (result.isEmpty()) hasMore = false
        } catch (e: Exception) { error = e.message }
        loading = false
    }
    val scope = rememberCoroutineScope()
    val tagRev = BlockTags.revision
    val shown = remember(items, tagRev) { BlockTags.visible(items) }
    LaunchedEffect(key) { load(1) }
    LaunchedEffect(items) { BlockTags.prefetch(scope, items) }
    LaunchedEffect(shown.size, items.size) {
        // A whole page filtered away: keep paging so the grid can fill.
        if (shown.isEmpty() && items.isNotEmpty() && hasMore && !loading) load(page + 1)
    }
    val shouldLoadMore by remember {
        derivedStateOf {
            val info = gridState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            hasMore && !loading && shown.isNotEmpty() && last >= shown.size - 6
        }
    }
    LaunchedEffect(shouldLoadMore) { if (shouldLoadMore) load(page + 1) }

    when {
        loading && items.isEmpty() -> LoadingBox()
        error != null && items.isEmpty() -> ErrorText(error!!) { error = null; scope.launch { load(1) } }
        else -> LazyVerticalGrid(GridCells.Fixed(3), state = gridState,
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 100.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(shown, key = { it.id }) { AlbumCard(it, router) }
            if (loading) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(3) }) {
                Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Pink) }
            }
        }
    }
}

// ---------------- Home ----------------
private data class Channel(val name: String, val slug: String?) // slug null: 推荐 / latest / random

@Composable
fun HomeScreen(router: Router, goProfile: () -> Unit, goSearch: () -> Unit = {}) {
    var categories by remember { mutableStateOf<List<JmApi.Category>>(emptyList()) }
    LaunchedEffect(Unit) { try { categories = JmApi.categories() } catch (e: Exception) {} }
    val channels = remember(categories) {
        listOf(Channel("推荐", null), Channel("最新", "latest"), Channel("随机", "random")) +
            categories.filter { it.slug.isNotEmpty() }.map { Channel(it.name, it.slug) }
    }
    var selected by remember { mutableIntStateOf(0) }
    val running = DownloadManager.tasks.any { it.state == DownloadManager.State.RUNNING }

    Column(Modifier.fillMaxSize()) {
        // iOS-style header: avatar | glass search capsule | glass download circle
        Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(R.drawable.avatar), contentDescription = null,
                modifier = Modifier.size(40.dp).clip(CircleShape).clickable { goProfile() })
            Spacer(Modifier.width(10.dp))
            Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface,
                border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.weight(1f).clickable { goSearch() }) {
                Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Search, contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("搜索", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.width(10.dp))
            Box {
                Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surface,
                    border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.size(40.dp).clickable { router.push(DownloadsDest) }) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Download, contentDescription = "下载", modifier = Modifier.size(19.dp))
                    }
                }
                if (running) {
                    Box(Modifier.size(9.dp).clip(CircleShape)
                        .align(Alignment.TopEnd)
                        .background(Pink, CircleShape))
                }
            }
        }
        ScrollableChannelRow(channels.map { it.name }, selected) { selected = it }
        val ch = channels.getOrNull(selected) ?: channels.first()
        when {
            ch.slug == null -> RecommendContent(router)
            ch.slug == "latest" -> PagedGrid(loader = { p -> JmApi.latest(p) }, router = router, key = "latest")
            ch.slug == "random" -> PagedGrid(loader = { p -> if (p == 1) JmApi.randomPool() else emptyList() }, router = router, key = "random")
            else -> PagedGrid(loader = { p -> JmApi.categoryFilter(ch.slug, p) }, router = router, key = "cat-${ch.slug}")
        }
    }
}

@Composable
fun ScrollableChannelRow(names: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(names.indices.toList()) { i ->
            val sel = i == selected
            Surface(
                shape = RoundedCornerShape(50),
                color = if (sel) Pink else MaterialTheme.colorScheme.surface,
                border = if (sel) null else androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.clickable { onSelect(i) }
            ) {
                Text(names[i], fontSize = 13.sp,
                    color = if (sel) androidx.compose.ui.graphics.Color.White else MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
            }
        }
    }
}

@Composable
fun RecommendContent(router: Router) {
    val scope = rememberCoroutineScope()
    val tagRev = BlockTags.revision
    var sections by remember { mutableStateOf<List<Pair<String, List<JmApi.Album>>>?>(null) }
    var randoms by remember { mutableStateOf<List<JmApi.Album>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(reload) {
        try {
            sections = JmApi.promote().filter { it.first != "連載更新" }
            randoms = JmApi.randomPool()
        } catch (e: Exception) { error = e.message }
    }
    LaunchedEffect(sections, randoms) {
        sections?.forEach { BlockTags.prefetch(scope, it.second) }
        BlockTags.prefetch(scope, randoms)
    }
    when {
        sections == null && error == null -> LoadingBox()
        error != null -> ErrorText(error!!) { error = null; sections = null; reload++ }
        else -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 10.dp, bottom = 100.dp)) {
            sections?.forEach { (title, albums) ->
                val shownAlbums = BlockTags.visible(albums)
                if (shownAlbums.isNotEmpty()) {
                    Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp))
                    LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(shownAlbums, key = { it.id }) { AlbumCard(it, router, Modifier.width(108.dp)) }
                    }
                }
            }
            val shownRandoms = BlockTags.visible(randoms)
            if (shownRandoms.isNotEmpty()) {
                Text("随机推荐", fontSize = 16.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp))
                Column(Modifier.padding(horizontal = 12.dp)) {
                    shownRandoms.chunked(3).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            row.forEach { AlbumCard(it, router, Modifier.weight(1f)) }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                        Spacer(Modifier.height(12.dp))
                    }
                }
            }
        }
    }
}

// ---------------- Search ----------------
private val SEARCH_TYPES = listOf("全部", "作品", "作者", "标签", "登场人物")
private val SEARCH_ORDERS = listOf("最新" to "mr", "最多观看" to "mv", "最多爱心" to "tf", "最多图片" to "mp")

@Composable
fun OptionChipRow(options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp)) {
        items(options.size) { i ->
            val sel = i == selected
            Surface(
                shape = RoundedCornerShape(50),
                color = if (sel) Pink else MaterialTheme.colorScheme.surface,
                border = if (sel) null else androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.clickable { onSelect(i) }
            ) {
                Text(options[i], fontSize = 13.sp,
                    color = if (sel) Color.White else MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
            }
        }
    }
}

@Composable
fun SearchScreen(router: Router, history: HistoryStore) {
    var query by remember { mutableStateOf("") }
    var submitted by remember { mutableStateOf<String?>(null) }
    var queries by remember { mutableStateOf(history.queries()) }
    var orderIdx by remember { mutableIntStateOf(0) }
    var typeIdx by remember { mutableIntStateOf(0) }
    var redirectAlbum by remember { mutableStateOf<JmApi.Album?>(null) }
    val order = SEARCH_ORDERS[orderIdx].second
    val s0 = submitted

    // Pure-numeric queries: the API answers with redirect_aid — jump straight
    // to that album instead of showing an empty result grid.
    LaunchedEffect(s0, order, typeIdx) {
        redirectAlbum = null
        val query2 = s0 ?: return@LaunchedEffect
        if (query2.isEmpty() || !query2.all { it.isDigit() }) return@LaunchedEffect
        try {
            val (_, _, red) = JmApi.search(query2, 1, order, typeIdx)
            if (red != null) {
                val d = JmApi.album(red)
                val authors = (d.optJSONArray("author")?.let { a ->
                    (0 until a.length()).map { a.optString(it) }.filter { x -> x.isNotEmpty() }
                } ?: emptyList())
                val tagList = (d.optJSONArray("tags")?.let { t ->
                    (0 until t.length()).map { t.optString(it) }
                } ?: emptyList())
                redirectAlbum = JmApi.Album(red, d.optString("name"),
                    authors.joinToString(" / "), tagList,
                    d.optString("total_views"), d.optString("likes"))
            }
        } catch (e: Exception) {}
    }

    Column(Modifier.fillMaxSize().padding(top = 10.dp)) {
        OutlinedTextField(
            value = query, onValueChange = { query = it },
            placeholder = { Text("搜索标题 / 作者") },
            singleLine = true,
            shape = RoundedCornerShape(50),
            colors = OutlinedTextFieldDefaults.colors(
                unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                focusedContainerColor = MaterialTheme.colorScheme.surface,
                unfocusedBorderColor = MaterialTheme.colorScheme.outlineVariant,
                focusedBorderColor = Pink,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
            trailingIcon = {
                TextButton(onClick = {
                    val q = query.trim()
                    if (q.isNotEmpty()) { submitted = q; history.add(q); queries = history.queries() }
                }) { Text("搜索", color = Pink) }
            }
        )
        OptionChipRow(SEARCH_TYPES, typeIdx) { typeIdx = it }
        OptionChipRow(SEARCH_ORDERS.map { it.first }, orderIdx) { orderIdx = it }
        val s = submitted
        val red = redirectAlbum
        if (s != null && red != null) {
            Text("编号直达", fontWeight = FontWeight.Bold, fontSize = 14.sp,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp))
            LazyVerticalGrid(GridCells.Fixed(3), modifier = Modifier.weight(1f).padding(horizontal = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item { AlbumCard(red, router) }
            }
        } else if (s == null) {
            if (queries.isNotEmpty()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("历史", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = { history.clear(); queries = emptyList() }) { Text("清空", fontSize = 12.sp) }
                }
                LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(queries) { q ->
                        Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface,
                            border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                            modifier = Modifier.clickable { query = q; submitted = q }) {
                            Text(q, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                        }
                    }
                }
            }
            Text("同人推荐", fontWeight = FontWeight.Bold, fontSize = 14.sp,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp))
            // A random page per visit (was pinned to page 1 forever, like iOS).
            PagedGrid(loader = { p -> if (p == 1) JmApi.categoryFilter("doujin", (1..60).random()) else emptyList() }, router = router, key = "doujin-rec")
        } else {
            PagedGrid(loader = { p -> JmApi.search(s, p, order, typeIdx).second }, router = router, key = "search-$s-$order-$typeIdx")
        }
    }
}

// ---------------- Categories ----------------
@Composable
fun CategoriesScreen(router: Router) {
    var cats by remember { mutableStateOf<List<JmApi.Category>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { try { cats = JmApi.categories() } catch (e: Exception) { error = e.message } }
    when {
        cats == null && error == null -> LoadingBox()
        error != null -> ErrorText(error!!)
        else -> androidx.compose.foundation.lazy.LazyColumn(Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 100.dp)) {
            items(cats!!.filter { it.slug.isNotEmpty() }, key = { it.slug }) { c ->
                Row(Modifier.fillMaxWidth().clickable { router.push(CategoryDest(c.slug, c.name)) }
                    .padding(horizontal = 16.dp, vertical = 15.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(c.name, fontSize = 15.sp)
                    Spacer(Modifier.weight(1f))
                    Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp), thickness = 0.5.dp)
            }
        }
    }
}

@Composable
fun CategoryPage(dest: CategoryDest, router: Router) {
    Column(Modifier.fillMaxSize()) {
        TopBar(title = dest.name) { router.pop() }
        PagedGrid(loader = { p -> JmApi.categoryFilter(dest.slug, p) }, router = router, key = "catpage-${dest.slug}")
    }
}

@Composable
fun TopBar(title: String, onBack: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) { Text("‹ 返回", color = Pink, fontSize = 15.sp) }
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
