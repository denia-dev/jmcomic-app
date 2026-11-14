package com.denia.jmreader

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ---------------- Settings (mirrors the iOS SettingsView grouping) ----------------
@Composable
fun SettingsScreen(router: Router, account: AccountStore) {
    val context = LocalContext.current
    val settingsScope = rememberCoroutineScope()
    var storageBytes by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(Unit) {
        storageBytes = withContext(Dispatchers.IO) {
            val p = storageParts(context); p.first + p.second
        }
    }
    Column(Modifier.fillMaxSize()) {
        TopBar(title = "设置") { router.pop() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            IosCard(radius = 16.dp, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("自动签到", fontSize = 16.sp)
                        Text("打开个人页时自动完成每日签到", fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(
                        checked = Settings.autoCheckIn,
                        onCheckedChange = { Settings.updateAutoCheckIn(it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = Pink, checkedThumbColor = Color.White),
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
            IosCard(radius = 16.dp, onClick = { router.push(LinesDest) }, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("线路设置", fontSize = 16.sp)
                    Spacer(Modifier.weight(1f))
                    Text(" ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(10.dp))
            IosCard(radius = 16.dp, onClick = { router.push(BlockedTagsDest) }, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("屏蔽标签与作者", fontSize = 16.sp)
                    Spacer(Modifier.weight(1f))
                    if (BlockTags.blockedTags.isNotEmpty() || BlockTags.blockedAuthors.isNotEmpty()) {
                        Text("${BlockTags.blockedTags.size + BlockTags.blockedAuthors.size} 个", fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(" ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(10.dp))
            IosCard(radius = 16.dp, onClick = { router.push(StorageDest) }, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("存储空间", fontSize = 16.sp)
                    Spacer(Modifier.weight(1f))
                    storageBytes?.let {
                        Text(android.text.format.Formatter.formatFileSize(context, it), fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(" ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(10.dp))
            IosCard(radius = 16.dp, onClick = {
                settingsScope.launch { UpdateCheck.check(context, manual = true) }
            }, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("检查更新", fontSize = 16.sp)
                    Spacer(Modifier.weight(1f))
                    val cur = UpdateCheck.currentVersion(context)
                    when {
                        UpdateCheck.checking ->
                            Text("检查中…", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        UpdateCheck.latestVersion == null ->
                            Text("当前 v$cur", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        UpdateCheck.isUpdate(cur) ->
                            Text("有新版 v${UpdateCheck.latestVersion}", fontSize = 12.sp, color = Pink)
                        else ->
                            Text("已是最新", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(" ›", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(24.dp))
            Text("JM Reader Android v${UpdateCheck.currentVersion(context)}", fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.align(Alignment.CenterHorizontally))
        }
    }
}

// ---------------- Lines (API / image host pools, speed test, manual pin) ----------------
@Composable
fun LinesScreen(router: Router) {
    val scope = rememberCoroutineScope()
    var apiLat by remember { mutableStateOf<Map<String, Long?>>(emptyMap()) }
    var imgLat by remember { mutableStateOf<Map<String, Long?>>(emptyMap()) }
    var testingApi by remember { mutableStateOf(false) }
    var testingImg by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }

    fun latText(map: Map<String, Long?>, host: String, testing: Boolean): String {
        if (!map.containsKey(host)) return if (testing) "测速中…" else "未测"
        val v = map[host] ?: return "超时"
        return "$v ms"
    }

    Column(Modifier.fillMaxSize()) {
        TopBar(title = "线路设置") { router.pop() }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text("API 线路", fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Spacer(Modifier.height(8.dp))
            LineRow("自动（推荐）", "", Lines.apiManual.isEmpty()) { Lines.pinApi("") }
            Lines.apiPool.forEach { line ->
                LineRow(line.name, line.host, Lines.apiManual == line.host,
                    latText(apiLat, line.host, testingApi)) { Lines.pinApi(line.host) }
            }
            Spacer(Modifier.height(8.dp))
            Button(onClick = {
                if (testingApi) return@Button
                testingApi = true
                scope.launch {
                    val out = mutableMapOf<String, Long?>()
                    for (line in Lines.apiPool) { out[line.host] = JmApi.probeApiHost(line.host) }
                    apiLat = out
                    testingApi = false
                }
            }, enabled = !testingApi, shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Pink),
                modifier = Modifier.fillMaxWidth()) {
                Text(if (testingApi) "测速中…" else "测速 API 线路", color = Color.White)
            }

            Spacer(Modifier.height(20.dp))
            Text("图片线路", fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Spacer(Modifier.height(8.dp))
            LineRow("自动（推荐）", "", Lines.imgManual.isEmpty()) { Lines.pinImg("") }
            Lines.imgPool.forEach { host ->
                LineRow(host, "", Lines.imgManual == host,
                    latText(imgLat, host, testingImg)) { Lines.pinImg(host) }
            }
            Spacer(Modifier.height(8.dp))
            Button(onClick = {
                if (testingImg) return@Button
                testingImg = true
                scope.launch {
                    val out = mutableMapOf<String, Long?>()
                    for (host in Lines.imgPool) {
                        val t0 = System.nanoTime()
                        out[host] = try {
                            JmApi.fetchBytes("https://$host/media/albums/310311_3x4.jpg")
                            (System.nanoTime() - t0) / 1_000_000
                        } catch (e: Exception) { null }
                    }
                    imgLat = out
                    testingImg = false
                }
            }, enabled = !testingImg, shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Pink),
                modifier = Modifier.fillMaxWidth()) {
                Text(if (testingImg) "测速中…" else "测速图片线路", color = Color.White)
            }

            Spacer(Modifier.height(20.dp))
            OutlinedButton(onClick = {
                if (refreshing) return@OutlinedButton
                refreshing = true
                scope.launch { Lines.refresh(true); refreshing = false }
            }, enabled = !refreshing, shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth()) {
                Text(if (refreshing) "刷新中…" else "刷新线路名单", color = Pink)
            }
            Spacer(Modifier.height(10.dp))
            val last = Lines.lastRefresh
            Text(
                "名单只包含 JM 官方域名（登录信息不会发给第三方镜像）。" +
                    if (last > 0) "上次刷新：" + java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.CHINA)
                        .format(java.util.Date(last)) else "尚未从官方名单刷新过。",
                fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun LineRow(name: String, sub: String, selected: Boolean, lat: String = "", onClick: () -> Unit) {
    IosCard(radius = 14.dp, onClick = onClick, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(name, fontSize = 14.sp, color = if (selected) Pink else MaterialTheme.colorScheme.onSurface,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal)
                if (sub.isNotEmpty()) {
                    Text(sub, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (lat.isNotEmpty()) {
                Text(lat, fontSize = 12.sp,
                    color = if (lat.endsWith("ms")) Pink else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (selected) Text(" ✓", color = Pink, fontSize = 14.sp)
        }
    }
}
