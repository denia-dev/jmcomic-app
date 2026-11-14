package com.denia.jmreader

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import coil.imageLoader
import org.json.JSONObject
import java.io.File

// ---------------- Profile / 个人 ----------------
@Composable
fun ProfileScreen(router: Router, account: AccountStore, library: LibraryStore) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var loggedIn by remember { mutableStateOf(account.isLoggedIn) }
    var stats by remember { mutableStateOf(account.stats) }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
        .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("个人", fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { router.push(SettingsDest) }) {
                Icon(androidx.compose.material.icons.Icons.Default.Settings, contentDescription = "设置", tint = Pink)
            }
        }
        Spacer(Modifier.height(8.dp))
        if (!loggedIn) {
            Text("登录 JM 账号", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(user, { user = it }, label = { Text("用户名") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(pass, { pass = it }, label = { Text("密码") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            Button(onClick = {
                busy = true; msg = null
                scope.launch {
                    try {
                        val d = JmApi.login(user.trim(), pass)
                        account.saveLogin(d, user.trim())
                        stats = account.stats
                        loggedIn = true
                    } catch (e: Exception) { msg = e.message }
                    busy = false
                }
            }, enabled = !busy && user.isNotBlank() && pass.isNotEmpty(),
                colors = ButtonDefaults.buttonColors(containerColor = Pink), modifier = Modifier.fillMaxWidth()) {
                Text(if (busy) "登录中…" else "登录", color = Color.White)
            }
            msg?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
            Spacer(Modifier.height(20.dp))
            Text("未登录时收藏保存在本机，登录后可同步云端收藏。", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.avatar), contentDescription = null,
                    modifier = Modifier.size(50.dp).clip(CircleShape))
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(account.username ?: "", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Text("已登录", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { account.logout(); stats = null; loggedIn = false }) { Text("退出", color = Pink) }
            }
            stats?.let { st ->
                IosCard(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp), radius = 20.dp) {
                    Column(Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("LV ${st.level}", fontWeight = FontWeight.Bold, color = Pink, fontSize = 16.sp)
                            Spacer(Modifier.width(12.dp))
                            Box(Modifier.weight(1f).height(8.dp).clip(RoundedCornerShape(4.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)) {
                                val frac = if (st.nextLevelExp > 0) (st.exp.toFloat() / st.nextLevelExp).coerceIn(0f, 1f) else 0f
                                Box(Modifier.fillMaxWidth(frac).fillMaxHeight().clip(RoundedCornerShape(4.dp)).background(Pink))
                            }
                            Spacer(Modifier.width(12.dp))
                            Text("${st.exp}/${st.nextLevelExp}", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Spacer(Modifier.height(14.dp))
                        Row {
                            listOf("经验值" to "${st.exp}", "J Coins" to "${st.coin}", "可收藏数量" to "${st.favCount}/${st.favMax}").forEach { (lb, v) ->
                                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                                    Text(lb, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(v, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Pink,
                                        modifier = Modifier.padding(top = 2.dp))
                                }
                            }
                        }
                    }
                }
            }
            if (stats == null) {
                // exp / level / coin only arrive with the login response; a
                // session kept alive across updates may have none cached.
                IosCard(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp), radius = 20.dp) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("账号数据未同步", fontWeight = FontWeight.Bold)
                            Text("经验、等级、金币在登录时同步，重新登录一次即可显示",
                                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = { account.logout(); stats = null; loggedIn = false }) {
                            Text("重新登录", color = Pink)
                        }
                    }
                }
            }
            CheckinCard(account)
        }

        ReadingStatsCard()
        Spacer(Modifier.height(18.dp))
        FavoritesSection(router, account, library, loggedIn, onCloudTotal = { stats = account.stats })
    }
}

@Composable
fun ReadingStatsCard() {
    fun fmtSeconds(s: Int): String = when {
        s < 3600 -> "${s / 60} 分钟"
        s % 3600 / 60 == 0 -> "${s / 3600} 小时"
        else -> "${s / 3600} 小时 ${s % 3600 / 60} 分"
    }
    IosCard(radius = 18.dp, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("阅读统计", fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            Row {
                listOf("读过" to "${ReadingStats.albumCount} 本", "章节" to "${ReadingStats.chapterCount} 话",
                    "页数" to "${ReadingStats.pagesRead}", "时长" to fmtSeconds(ReadingStats.secondsRead)).forEach { (lb, v) ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(lb, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(v, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Pink,
                            modifier = Modifier.padding(top = 2.dp))
                    }
                }
            }
            Text("从这版开始统计，本机记录", fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
fun CheckinCard(account: AccountStore) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<JSONObject?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    suspend fun reload() {
        try { data = JmApi.daily(account.userId) } catch (e: Exception) { note = e.message }
    }
    LaunchedEffect(Unit) { reload() }
    val d = data ?: return
    val dailyId = d.optString("daily_id")
    val record = d.optJSONArray("record")
    val todayStr = remember { java.text.SimpleDateFormat("dd", java.util.Locale.US).format(java.util.Date()) }
    var todaySigned = false
    var todayIndex = -1
    if (record != null) {
        for (w in 0 until record.length()) {
            val week = record.optJSONArray(w) ?: continue
            for (i in 0 until week.length()) {
                val day = week.optJSONObject(i) ?: continue
                if (day.optString("date") == todayStr) {
                    todayIndex = w * 7 + i
                    todaySigned = day.optBoolean("signed", false)
                }
            }
        }
    }
    // Auto check-in (Settings toggle, once per day): claim the day first so a
    // failure never loops, then check in and refresh the card.
    LaunchedEffect(d) {
        val fullToday = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date())
        if (!todaySigned && Settings.autoCheckIn && Settings.autoCheckinDay != fullToday && dailyId.isNotEmpty()) {
            Settings.autoCheckinDay = fullToday
            try {
                val r = JmApi.dailyCheck(account.userId, dailyId)
                val m = r.optString("msg")
                note = if (m.isEmpty()) "今日已自动签到" else "今日已自动签到：$m"
                reload()
            } catch (e: Exception) { /* manual button remains available */ }
        }
    }
    IosCard(radius = 18.dp, modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("每日签到", fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(8.dp))
                Text(d.optString("event_name"), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Button(onClick = {
                    if (todaySigned || busy) return@Button
                    busy = true
                    scope.launch {
                        try {
                            val r = JmApi.dailyCheck(account.userId, dailyId)
                            note = r.optString("msg").ifEmpty { "签到成功" }
                            reload()
                        } catch (e: Exception) { note = e.message }
                        busy = false
                    }
                }, enabled = !todaySigned && !busy,
                    colors = ButtonDefaults.buttonColors(containerColor = Pink),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp)) {
                    Text(if (todaySigned) "已签到" else "签到", color = Color.White, fontSize = 13.sp)
                }
            }
            Text("连签 3 天 +${d.optString("three_days_coin")} 金币 · 7 天 +${d.optString("seven_days_coin")} 金币 · 补签 ${d.optString("makeup_used")}/${d.optString("makeup_limit")}",
                fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 6.dp))
            if (record != null) {
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    for (w in 0 until record.length()) {
                        val week = record.optJSONArray(w) ?: continue
                        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            for (i in 0 until week.length()) {
                                val day = week.optJSONObject(i)
                                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                                    if (day == null) { Text("") } else {
                                        val signed = if (day.isNull("signed")) null else day.optBoolean("signed")
                                        val isToday = day.optString("date") == todayStr
                                        Surface(shape = RoundedCornerShape(8.dp),
                                            color = when {
                                                signed == true -> Pink
                                                isToday -> MaterialTheme.colorScheme.surface
                                                else -> Color.Transparent
                                            },
                                            border = if (isToday && signed != true) androidx.compose.foundation.BorderStroke(1.5.dp, Pink) else null,
                                            modifier = Modifier.size(30.dp)) {
                                            Box(contentAlignment = Alignment.Center) {
                                                Text(
                                                    when {
                                                        day.optBoolean("bonus") -> "★"
                                                        signed == true -> "✓"
                                                        else -> day.optString("date").trimStart('0')
                                                    },
                                                    fontSize = 11.sp,
                                                    color = if (signed == true) Color.White else MaterialTheme.colorScheme.onSurface)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            note?.let { Text(it, fontSize = 12.sp, color = Pink, modifier = Modifier.padding(top = 8.dp)) }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FavoritesSection(router: Router, account: AccountStore, library: LibraryStore, loggedIn: Boolean, onCloudTotal: () -> Unit = {}) {
    // Keyed on loggedIn: composed while logged out (fresh install), the tab
    // must still flip to cloud once the login lands — an unkeyed remember
    // kept it stuck on the (empty) local tab and cloud favorites never showed.
    var tab by remember(loggedIn) { mutableIntStateOf(if (loggedIn) 0 else 1) } // 0 cloud, 1 local
    var query by remember { mutableStateOf("") }
    var cloud by remember { mutableStateOf<List<JmApi.Album>>(emptyList()) }
    var cloudTotal by remember { mutableIntStateOf(0) }
    var local by remember { mutableStateOf(library.localFavorites()) }
    var folders by remember { mutableStateOf<List<JmApi.Folder>>(listOf(JmApi.Folder("0", "默认收藏"))) }
    var folderId by remember { mutableStateOf("0") }
    var cloudReload by remember { mutableIntStateOf(0) }
    val context = LocalContext.current
    var moveMode by remember { mutableStateOf(false) }
    var selectMode by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var pendingMove by remember { mutableStateOf<JmApi.Album?>(null) }
    var confirmDelete by remember { mutableStateOf<JmApi.Folder?>(null) }
    var showCreate by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val username = account.username ?: ""

    LaunchedEffect(loggedIn, folderId, cloudReload) {
        local = library.localFavorites()
        if (loggedIn) {
            FolderRegistry.syncFromCloud(account)
            try {
                val (total, first, serverFolders) = JmApi.favorites(1, folderId)
                cloudTotal = total
                folders = FolderRegistry.visible(username, serverFolders)
                if (folders.none { it.fid == folderId }) folderId = "0"
                account.syncFavCount(total)
                onCloudTotal()
                // Publish page 1 immediately, then append page by page. The old
                // all-or-nothing loop discarded EVERYTHING when one of the ~20
                // serial page requests failed on a flaky direct connection
                // (426 favorites = 22 pages), and its 15-page cap silently
                // truncated big collections to 300 items.
                var all = first.filter { !RemovedFavs.contains(it.id) }
                cloud = all
                var page = 2
                var incomplete = false
                while (all.size < total && page <= 100) {
                    var more: List<JmApi.Album>? = null
                    for (attempt in 0..1) {
                        try { more = JmApi.favorites(page, folderId).second; break }
                        catch (e: Exception) {
                            if (attempt == 1) incomplete = true else delay(400)
                        }
                    }
                    val m = more ?: break
                    if (m.isEmpty()) break
                    all = all + m.filter { !RemovedFavs.contains(it.id) }
                    cloud = all
                    page++
                }
                if (incomplete) msg = "部分收藏没加载完，点「云端」标签可继续重试"
            } catch (e: Exception) { msg = "云端收藏加载失败，点「云端」标签可重试" }
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("我的收藏", fontWeight = FontWeight.Bold, fontSize = 16.sp)
        Spacer(Modifier.width(12.dp))
        if (loggedIn) {
            FilterChip(selected = tab == 0, onClick = { if (tab == 0) cloudReload++ else tab = 0 }, label = { Text("云端 $cloudTotal") },
                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Pink, selectedLabelColor = Color.White))
            Spacer(Modifier.width(6.dp))
        }
        FilterChip(selected = tab == 1, onClick = { tab = 1 }, label = { Text("本地 ${local.size}") },
            colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Pink, selectedLabelColor = Color.White))
        Spacer(Modifier.weight(1f))
        if (loggedIn && tab == 0) {
            TextButton(onClick = { moveMode = !moveMode; if (moveMode) selectMode = false }) {
                Text(if (moveMode) "完成" else "整理", color = Pink, fontSize = 13.sp)
            }
        }
        TextButton(onClick = {
            selectMode = !selectMode
            if (selectMode) moveMode = false
            selectedIds = emptySet()
        }) {
            Text(if (selectMode) "取消" else "批量下载", color = Pink, fontSize = 13.sp)
        }
    }
    if (loggedIn && tab == 0) {
        // Folder chips: tap to switch, long-press to delete (default folder excluded).
        androidx.compose.foundation.lazy.LazyRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 4.dp)) {
            items(folders.size) { i ->
                val f = folders[i]
                val sel = f.fid == folderId
                Surface(
                    shape = RoundedCornerShape(50),
                    color = if (sel) Pink else MaterialTheme.colorScheme.surface,
                    border = if (sel) null else androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.combinedClickable(
                        onClick = { folderId = f.fid },
                        onLongClick = { if (f.fid != "0") confirmDelete = f },
                    )
                ) {
                    Text(f.name, fontSize = 13.sp,
                        color = if (sel) Color.White else MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
                }
            }
            item {
                Surface(
                    shape = RoundedCornerShape(50),
                    color = MaterialTheme.colorScheme.surface,
                    border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.clickable { showCreate = true }
                ) {
                    Text("+ 新建", fontSize = 13.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp))
                }
            }
        }
        Text("长按收藏夹可删除；点「整理」后点任意收藏可移动到其他收藏夹",
            fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    OutlinedTextField(query, { query = it }, placeholder = { Text("搜收藏（标题/作者）") }, singleLine = true,
        shape = RoundedCornerShape(50),
        colors = OutlinedTextFieldDefaults.colors(
            unfocusedContainerColor = MaterialTheme.colorScheme.surface,
            focusedContainerColor = MaterialTheme.colorScheme.surface,
            unfocusedBorderColor = MaterialTheme.colorScheme.outlineVariant,
            focusedBorderColor = Pink,
        ),
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
    msg?.let { Text(it, fontSize = 12.sp, color = Pink, modifier = Modifier.padding(bottom = 6.dp)) }
    val source = if (tab == 0 && loggedIn) cloud else local
    val filtered = if (query.isBlank()) source else source.filter {
        it.name.contains(query, true) || it.author.contains(query, true)
    }
    if (filtered.isEmpty()) {
        Text("没有匹配的收藏", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
    } else {
        LazyVerticalGrid(GridCells.Fixed(3), modifier = Modifier.heightIn(max = 2000.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
            userScrollEnabled = false) {
            items(filtered, key = { it.id }) { album ->
                Box {
                    AlbumCard(album, router)
                    if (moveMode && tab == 0 && loggedIn) {
                        Box(Modifier.matchParentSize().clickable { pendingMove = album })
                    }
                    if (selectMode) {
                        Box(Modifier.matchParentSize().clickable {
                            selectedIds = if (selectedIds.contains(album.id)) selectedIds - album.id else selectedIds + album.id
                        })
                        if (selectedIds.contains(album.id)) {
                            Surface(shape = CircleShape, color = Pink,
                                modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(20.dp)) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text("✓", color = Color.White, fontSize = 12.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (selectMode) {
        Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("已选 ${selectedIds.size} 本", fontSize = 13.sp)
            Spacer(Modifier.weight(1f))
            Button(onClick = {
                val chosen = filtered.filter { selectedIds.contains(it.id) }
                chosen.forEach { DownloadManager.enqueue(context, it) }
                msg = "已把 ${chosen.size} 本加入下载，去下载页看进度"
                selectMode = false
                selectedIds = emptySet()
            }, enabled = selectedIds.isNotEmpty(),
                colors = ButtonDefaults.buttonColors(containerColor = Pink)) {
                Text("下载已选", color = Color.White, fontSize = 13.sp)
            }
        }
    }

    if (showCreate) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showCreate = false },
            title = { Text("新建收藏夹") },
            text = {
                OutlinedTextField(name, { name = it }, placeholder = { Text("收藏夹名称") }, singleLine = true)
            },
            confirmButton = {
                TextButton(enabled = name.isNotBlank(), onClick = {
                    val n = name.trim()
                    showCreate = false
                    scope.launch {
                        try { JmApi.folderAdd(n) } catch (e: Exception) {}
                        // The new folder's FID only appears via folder_list, and
                        // propagation between JM's hosts can lag — poll briefly.
                        for (i in 0 until 5) {
                            try {
                                val (_, _, serverFolders) = JmApi.favorites(1)
                                if (serverFolders.any { it.name == n }) break
                            } catch (e: Exception) {}
                            kotlinx.coroutines.delay(1200)
                        }
                        cloudReload++
                    }
                }) { Text("新建", color = Pink) }
            },
            dismissButton = { TextButton(onClick = { showCreate = false }) { Text("取消") } },
        )
    }

    confirmDelete?.let { f ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("删除收藏夹「${f.name}」？") },
            text = { Text("JM 官方的删除接口目前异常，删除会通过云端名单同步，在所有设备上隐藏这个收藏夹。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = null
                    FolderRegistry.addTombstone(username, f.fid)
                    scope.launch {
                        FolderRegistry.reportDeleted(account, f.fid)
                        try { JmApi.folderDel(f.fid) } catch (e: Exception) {}
                    }
                    if (folderId == f.fid) folderId = "0"
                    cloudReload++
                }) { Text("删除", color = Pink) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("取消") } },
        )
    }

    pendingMove?.let { album ->
        AlertDialog(
            onDismissRequest = { pendingMove = null },
            title = { Text("移动「${album.name}」到") },
            text = {
                Column {
                    folders.filter { it.fid != folderId }.forEach { f ->
                        TextButton(onClick = {
                            pendingMove = null
                            scope.launch {
                                try {
                                    JmApi.folderMove(f.fid, album.id)
                                    msg = "已移动到「${f.name}」"
                                    cloudReload++
                                } catch (e: Exception) { msg = "移动失败：${e.message}" }
                            }
                        }) { Text(f.name, color = Pink) }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { pendingMove = null }) { Text("取消") } },
        )
    }
}

// ---------------- Detail ----------------
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DetailScreen(dest: DetailDest, router: Router, account: AccountStore, library: LibraryStore) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var detail by remember { mutableStateOf<JSONObject?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var fav by remember { mutableStateOf(library.isFavorite(dest.id)) }
    var tagsExpanded by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }
    var showFolderPick by remember { mutableStateOf(false) }
    var pickFolders by remember { mutableStateOf<List<JmApi.Folder>>(listOf(JmApi.Folder("0", "默认收藏"))) }

    LaunchedEffect(dest.id) {
        try {
            val dd = JmApi.album(dest.id)
            detail = dd
            val t = dd.optJSONArray("tags")
            val tl = mutableListOf<String>()
            if (t != null) for (i in 0 until t.length()) tl.add(t.optString(i))
            val al = mutableListOf<String>()
            val aa = dd.opt("author")
            if (aa is org.json.JSONArray) for (i in 0 until aa.length()) al.add(aa.optString(i))
            else if (aa is String && aa.isNotEmpty()) al.add(aa)
            BlockTags.remember(dest.id, tl, al)
            if (account.isLoggedIn) {
                val cf = dd.optInt("is_favorite") != 0
                if (cf) RemovedFavs.clear(dest.id)
                fav = cf
            }
        } catch (e: Exception) { error = e.message }
        if (!account.isLoggedIn) fav = library.isFavorite(dest.id)
    }
    Column(Modifier.fillMaxSize()) {
        TopBar(title = "详情") { router.pop() }
        val d = detail
        when {
            d == null && error == null -> LoadingBox()
            error != null -> ErrorText(error!!)
            d != null -> {
                val name = d.optString("name")
                val authors = mutableListOf<String>()
                val a = d.opt("author")
                if (a is org.json.JSONArray) for (i in 0 until a.length()) authors.add(a.optString(i))
                else if (a is String && a.isNotEmpty()) authors.add(a)
                val tags = mutableListOf<String>()
                val t = d.optJSONArray("tags"); if (t != null) for (i in 0 until t.length()) tags.add(t.optString(i))
                val chapters = parseSeries(d, dest.id)
                val albumModel = JmApi.Album(dest.id, name, authors.joinToString(" / "), tags, d.optString("total_views"), d.optString("likes"))
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
                    Row {
                        CoverImage(dest.id, Modifier.width(120.dp))
                        Spacer(Modifier.width(14.dp))
                        Column {
                            Text(name, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text("浏览 ${d.optString("total_views")} · 点赞 ${d.optString("likes")}", fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text("章节 ${chapters.size}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (authors.isNotEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        Text("作者", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            authors.forEach { au ->
                                Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface,
                                    border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                                    modifier = Modifier.combinedClickable(
                                        onClick = { router.push(AuthorDest(au)) },
                                        onLongClick = { BlockTags.addAuthor(au); toast = "已屏蔽作者「$au」，列表里将不再显示" })) {
                                    Text(au, fontSize = 13.sp, color = Pink, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                                }
                            }
                        }
                    }
                    if (tags.isNotEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        Text("标签", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        val shown = if (tagsExpanded) tags else tags.take(8)
                        FlowRowTags(shown) { tag -> BlockTags.add(tag); toast = "已屏蔽标签「$tag」，列表里将不再显示" }
                        if (tags.size > 8) {
                            TextButton(onClick = { tagsExpanded = !tagsExpanded }) {
                                Text(if (tagsExpanded) "收起" else "展开全部 ${tags.size} 个", color = Pink, fontSize = 12.sp)
                            }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(onClick = { if (chapters.isNotEmpty()) router.push(ReaderDest(chapters.first().first, name, dest.id)) },
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Pink)) { Text("开始阅读", color = Color.White) }
                        OutlinedButton(onClick = {
                            if (fav && account.isLoggedIn) {
                                scope.launch {
                                    try {
                                        val now = JmApi.toggleFavorite(dest.id)
                                        fav = now
                                        if (!now) {
                                            RemovedFavs.add(dest.id)
                                            library.removeFavorite(dest.id)
                                            toast = "已取消收藏"
                                        } else toast = "已收藏"
                                    } catch (e: Exception) { toast = "操作失败：${e.message}" }
                                }
                            }
                            else if (fav) { library.removeFavorite(dest.id); fav = false; toast = "已取消本地收藏" }
                            else if (account.isLoggedIn) {
                                scope.launch {
                                    try {
                                        val (_, _, serverFolders) = JmApi.favorites(1)
                                        pickFolders = FolderRegistry.visible(account.username ?: "", serverFolders)
                                    } catch (e: Exception) {}
                                    showFolderPick = true
                                }
                            } else {
                                library.addFavorite(albumModel); fav = true
                                toast = "已收藏"
                            }
                        }, shape = RoundedCornerShape(14.dp)) { Text(if (fav) "已收藏" else "收藏", color = Pink) }
                        OutlinedButton(onClick = { DownloadManager.enqueue(context, albumModel); toast = "已加入下载，去下载页看进度" },
                            shape = RoundedCornerShape(14.dp)) {
                            Text("下载", color = Pink)
                        }
                    }
                    toast?.let { Text(it, color = Pink, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp)) }
                    if (showFolderPick) {
                        AlertDialog(
                            onDismissRequest = { showFolderPick = false },
                            title = { Text("收藏到") },
                            text = {
                                Column {
                                    pickFolders.forEach { f ->
                                        TextButton(onClick = {
                                            showFolderPick = false
                                            library.addFavorite(albumModel); fav = true
                                            scope.launch {
                                                try {
                                                    // Toggle endpoint: if the server already
                                                    // had it, the first call removes it — flip back.
                                                    var nowFav = JmApi.toggleFavorite(dest.id)
                                                    if (!nowFav) nowFav = JmApi.toggleFavorite(dest.id)
                                                    if (nowFav) { RemovedFavs.clear(dest.id); fav = true }
                                                    if (f.fid != "0") JmApi.folderMove(f.fid, dest.id)
                                                    toast = "已收藏到「${f.name}」"
                                                } catch (e: Exception) { toast = "云端收藏失败：${e.message}" }
                                            }
                                        }) { Text(f.name, color = Pink) }
                                    }
                                }
                            },
                            confirmButton = {},
                            dismissButton = { TextButton(onClick = { showFolderPick = false }) { Text("取消") } },
                        )
                    }
                    Spacer(Modifier.height(18.dp))
                    Text("章节", fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    Spacer(Modifier.height(8.dp))
                    IosCard(radius = 18.dp, modifier = Modifier.fillMaxWidth()) {
                        Column {
                            chapters.forEachIndexed { idx, (cid, cname) ->
                                Row(Modifier.fillMaxWidth().clickable { router.push(ReaderDest(cid, name, dest.id)) }
                                    .padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Text(cname.ifEmpty { "第 ${idx + 1} 话" }, fontSize = 14.sp)
                                    Spacer(Modifier.weight(1f))
                                    Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                if (idx < chapters.lastIndex) {
                                    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp), thickness = 0.5.dp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FlowRowTags(tags: List<String>, onLongPress: (String) -> Unit = {}) {
    var x = 0f
    Column {
        var row = mutableListOf<String>()
        val rows = mutableListOf<List<String>>()
        // simple chunking: 4 per row is fine for display purposes
        tags.chunked(4).forEach { rows.add(it) }
        rows.forEach { r ->
            Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                r.forEach { tag ->
                    Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface,
                        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                        modifier = Modifier.combinedClickable(onClick = {}, onLongClick = { onLongPress(tag) })) {
                        Text(tag, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp))
                    }
                }
            }
        }
    }
}

// ---------------- Author works ----------------
@Composable
fun AuthorScreen(dest: AuthorDest, router: Router) {
    Column(Modifier.fillMaxSize()) {
        TopBar(title = dest.name) { router.pop() }
        PagedGrid(loader = { p ->
            val (_, all, _) = JmApi.search(dest.name, p)
            all.filter { it.author.contains(dest.name) }
        }, router = router, key = "author-${dest.name}")
    }
}

// ---------------- Downloads page ----------------
@Composable
fun DownloadsScreen(router: Router) {
    val context = LocalContext.current
    var viewing by remember { mutableStateOf<File?>(null) }
    if (viewing != null) {
        PdfViewerScreen(viewing!!) { viewing = null }
        return
    }
    var files by remember { mutableStateOf(DownloadManager.files(context)) }
    LaunchedEffect(DownloadManager.tasks.map { it.state }) { files = DownloadManager.files(context) }
    Column(Modifier.fillMaxSize()) {
        TopBar(title = "下载") { router.pop() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            if (DownloadManager.tasks.isNotEmpty()) {
                Text("任务", fontWeight = FontWeight.Bold)
                DownloadManager.tasks.forEach { t ->
                    Column(Modifier.padding(vertical = 8.dp)) {
                        Text(t.title, fontSize = 14.sp, maxLines = 1)
                        Text(when (t.state) {
                            DownloadManager.State.RUNNING -> "下载中 ${t.done}/${t.total} 页"
                            DownloadManager.State.DONE -> "已完成（也在系统下载/JMReader 里）"
                            DownloadManager.State.FAILED -> "失败" + (t.error?.let { "：$it" } ?: "")
                        }, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (t.state == DownloadManager.State.FAILED) {
                            TextButton(onClick = { DownloadManager.enqueue(context, t.album) }) { Text("继续", color = Pink) }
                        }
                        if (t.state == DownloadManager.State.RUNNING && t.total > 0) {
                            LinearProgressIndicator(progress = { t.done.toFloat() / t.total }, color = Pink,
                                modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
                        }
                    }
                    HorizontalDivider(thickness = 0.5.dp)
                }
                Spacer(Modifier.height(14.dp))
            }
            Text("已下载", fontWeight = FontWeight.Bold)
            if (files.isEmpty()) Text("暂无", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp))
            files.forEach { f ->
                Row(
                    Modifier.fillMaxWidth()
                        .clickable(enabled = f.extension == "pdf") { viewing = f }
                        .padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(f.name, fontSize = 13.sp, maxLines = 1)
                        Text("%.1f MB".format(f.length() / 1048576.0), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TextButton(onClick = { DownloadManager.share(context, f) }) { Text("分享", color = Pink) }
                    TextButton(onClick = { f.delete(); files = DownloadManager.files(context) }) { Text("删除") }
                }
                HorizontalDivider(thickness = 0.5.dp)
            }
        }
    }
}

// ---------------- Blocked tags ----------------
@Composable
fun BlockedTagsScreen(router: Router) {
    var input by remember { mutableStateOf("") }
    var authorInput by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        TopBar(title = "屏蔽标签与作者") { router.pop() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text("屏蔽标签", fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(input, { input = it }, placeholder = { Text("输入要屏蔽的标签") },
                    singleLine = true, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { BlockTags.add(input); input = "" }, enabled = input.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(containerColor = Pink)) {
                    Text("添加", color = Color.White)
                }
            }
            Spacer(Modifier.height(14.dp))
            if (BlockTags.blockedTags.isEmpty()) {
                Text("还没有屏蔽任何标签。在漫画详情页长按标签也可以快速屏蔽。",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                BlockTags.blockedTags.forEach { tag ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(tag, fontSize = 14.sp)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { BlockTags.remove(tag) }) { Text("取消屏蔽", color = Pink, fontSize = 12.sp) }
                    }
                    HorizontalDivider(thickness = 0.5.dp)
                }
            }
            Spacer(Modifier.height(20.dp))
            Text("屏蔽作者", fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(authorInput, { authorInput = it }, placeholder = { Text("输入要屏蔽的作者") },
                    singleLine = true, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { BlockTags.addAuthor(authorInput); authorInput = "" }, enabled = authorInput.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(containerColor = Pink)) {
                    Text("添加", color = Color.White)
                }
            }
            Spacer(Modifier.height(10.dp))
            if (BlockTags.blockedAuthors.isEmpty()) {
                Text("还没有屏蔽任何作者。在漫画详情页长按作者也可以快速屏蔽。",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                BlockTags.blockedAuthors.forEach { au ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(au, fontSize = 14.sp)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { BlockTags.removeAuthor(au) }) { Text("取消屏蔽", color = Pink, fontSize = 12.sp) }
                    }
                    HorizontalDivider(thickness = 0.5.dp)
                }
            }
            Spacer(Modifier.height(14.dp))
            Text("在首页、分类、搜索等列表中，命中屏蔽标签或屏蔽作者的作品会直接隐藏；作品的真实标签与作者会随着浏览自动记录，之后按标签/作者过滤。收藏与历史不受影响。",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ---------------- Storage / 存储空间 ----------------

/** (image-cache bytes, downloaded-books bytes, downloaded-book count). Call off the main thread. */
fun storageParts(context: android.content.Context): Triple<Long, Long, Int> {
    val img = runCatching { context.imageLoader.diskCache?.size ?: 0L }.getOrDefault(0L)
    val dir = File(context.filesDir, "Downloads")
    var dl = 0L
    var count = 0
    dir.listFiles()?.forEach { f ->
        if (f.isFile && (f.extension.equals("pdf", true) || f.extension.equals("cbz", true))) {
            dl += f.length(); count++
        }
    }
    return Triple(img, dl, count)
}

@Composable
fun StorageScreen(router: Router) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var imgBytes by remember { mutableStateOf(0L) }
    var dlBytes by remember { mutableStateOf(0L) }
    var dlCount by remember { mutableStateOf(0) }
    var confirm by remember { mutableStateOf(false) }
    var cleared by remember { mutableStateOf(false) }

    suspend fun reload() {
        val p = withContext(Dispatchers.IO) { storageParts(context) }
        imgBytes = p.first; dlBytes = p.second; dlCount = p.third
    }
    LaunchedEffect(Unit) { reload() }

    fun fmt(b: Long) = android.text.format.Formatter.formatFileSize(context, b)

    Column(Modifier.fillMaxSize()) {
        TopBar(title = "存储空间") { router.pop() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            IosCard(radius = 20.dp, modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(vertical = 18.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("总占用", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(fmt(imgBytes + dlBytes), fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Pink)
                }
            }
            Spacer(Modifier.height(14.dp))
            IosCard(radius = 20.dp, modifier = Modifier.fillMaxWidth()) {
                Column {
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("图片缓存", fontWeight = FontWeight.Bold)
                            Text("看过的封面与漫画页", fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(fmt(imgBytes), fontWeight = FontWeight.Bold)
                    }
                    HorizontalDivider(Modifier.padding(horizontal = 14.dp))
                    Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("已下载漫画", fontWeight = FontWeight.Bold)
                            Text("$dlCount 本（在下载页左滑删除）", fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(fmt(dlBytes), fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            Button(
                onClick = { confirm = true },
                enabled = imgBytes > 0 && !cleared,
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Pink),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (cleared) "已清理" else "清理图片缓存", color = Color.White)
            }
            Spacer(Modifier.height(10.dp))
            Text("图片缓存清掉不影响收藏与已下载漫画，下次打开会重新下载。",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("清理图片缓存？") },
            text = { Text("将清掉 ${fmt(imgBytes)} 图片缓存，已下载的漫画不受影响。") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = false
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            runCatching { context.imageLoader.diskCache?.clear() }
                            runCatching { context.imageLoader.memoryCache?.clear() }
                        }
                        cleared = true
                        reload()
                    }
                }) { Text("清理", color = Pink) }
            },
            dismissButton = {
                TextButton(onClick = { confirm = false }) { Text("取消") }
            },
        )
    }
}
