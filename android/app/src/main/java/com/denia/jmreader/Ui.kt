package com.denia.jmreader

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.MediaStore
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import coil.compose.AsyncImage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

val Pink = Color(0xFFFF2E88)
val Blue = Color(0xFF0091FF)

@Composable
fun JmTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(
        primary = Pink, secondary = Blue,
        background = Color(0xFF0E0E12), surface = Color(0xFF17171D), surfaceVariant = Color(0xFF22222A),
        outlineVariant = Color(0xFF2A2A33),
    ) else lightColorScheme(
        primary = Pink, secondary = Blue,
        background = Color(0xFFF2F2F7), surface = Color.White, surfaceVariant = Color(0xFFEFEFF4),
        outlineVariant = Color(0xFFE2E2E8),
    )
    MaterialTheme(colorScheme = scheme, content = content)
}

/** iOS-style glass card: surface fill, hairline border, large radius. */
@Composable
fun IosCard(modifier: Modifier = Modifier, radius: androidx.compose.ui.unit.Dp = 20.dp,
            onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    androidx.compose.material3.Surface(
        shape = RoundedCornerShape(radius),
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = if (onClick != null) modifier.clickable { onClick() } else modifier,
    ) { content() }
}

// ---------- navigation ----------
sealed interface Dest
data class DetailDest(val id: String) : Dest
data class ReaderDest(val chapterId: String, val albumTitle: String, val albumId: String = "") : Dest
data class AuthorDest(val name: String) : Dest
data class CategoryDest(val slug: String, val name: String) : Dest
data class LocalComicDest(val bookId: String) : Dest
data class LocalNovelDest(val bookId: String) : Dest
object DownloadsDest : Dest
object BlockedTagsDest : Dest
object StorageDest : Dest
object SettingsDest : Dest
object LinesDest : Dest

class Router {
    val stack = mutableStateListOf<Dest>()
    fun push(d: Dest) { stack.add(d) }
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
}

// ---------- shared bits ----------
@Composable
fun CoverImage(id: String, modifier: Modifier = Modifier) {
    // Walk the image-host pool on failure instead of dying with the front
    // host; the host that answers gets promoted for every later image.
    val hosts = Lines.orderedImgHosts()
    var idx by remember(id) { mutableStateOf(0) }
    val host = hosts.getOrNull(idx) ?: JmApi.imgHost
    AsyncImage(
        model = "https://$host/media/albums/${id}_3x4.jpg",
        contentDescription = null,
        contentScale = ContentScale.Crop,
        onSuccess = { Lines.promoteImgHost(host) },
        onError = { if (idx < hosts.size - 1) idx++ },
        modifier = modifier
            .aspectRatio(3f / 4f)
            .clip(RoundedCornerShape(10.dp))
    )
}

@Composable
fun LoadingBox() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Pink)
    }
}

@Composable
fun ErrorText(msg: String, onRetry: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(msg, color = MaterialTheme.colorScheme.error)
        if (onRetry != null) {
            TextButton(onClick = onRetry) { Text("重试", color = Pink) }
        }
    }
}

// ---------- downloads (pages staged to disk first, then streamed into a PDF) ----------
object DownloadManager {
    enum class State { RUNNING, DONE, FAILED }
    class Task(val album: JmApi.Album, state0: State, done0: Int, total0: Int) {
        val albumId: String = album.id
        val title: String = album.name
        var state by androidx.compose.runtime.mutableStateOf(state0)
        var done by androidx.compose.runtime.mutableIntStateOf(done0)
        var total by androidx.compose.runtime.mutableIntStateOf(total0)
        var error by androidx.compose.runtime.mutableStateOf<String?>(null)
    }
    val tasks = mutableStateListOf<Task>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private const val META_PREFS = "jm.downloadMeta"

    private fun meta(context: Context): SharedPreferences =
        context.getSharedPreferences(META_PREFS, Context.MODE_PRIVATE)

    fun albumIdOf(context: Context, file: File): String =
        meta(context).getString(file.name, null)?.let { runCatching { JSONObject(it).optString("albumId") }.getOrNull() }
            ?.takeIf { it.isNotEmpty() } ?: file.name.substringBefore('_')

    fun titleOf(context: Context, file: File): String =
        meta(context).getString(file.name, null)?.let { runCatching { JSONObject(it).optString("title") }.getOrNull() }
            ?.takeIf { it.isNotEmpty() } ?: file.name.substringAfter('_', file.name).substringBeforeLast('.')

    fun categoryOf(context: Context, file: File): String =
        meta(context).getString(file.name, null)?.let { runCatching { JSONObject(it).optString("category") }.getOrNull() } ?: ""

    fun saveMeta(context: Context, file: File, albumId: String, title: String) {
        val old = meta(context).getString(file.name, "{}") ?: "{}"
        val obj = runCatching { JSONObject(old) }.getOrDefault(JSONObject())
        obj.put("albumId", albumId)
        obj.put("title", title)
        meta(context).edit().putString(file.name, obj.toString()).apply()
    }

    fun setCategory(context: Context, file: File, category: String) {
        val old = meta(context).getString(file.name, "{}") ?: "{}"
        val obj = runCatching { JSONObject(old) }.getOrDefault(JSONObject())
        obj.put("category", category)
        meta(context).edit().putString(file.name, obj.toString()).apply()
    }

    fun forgetMeta(context: Context, fileName: String) {
        meta(context).edit().remove(fileName).apply()
    }

    fun dir(context: Context): File = File(context.filesDir, "Downloads").apply { mkdirs() }
    private fun stagingDir(context: Context, albumId: String): File =
        File(dir(context), ".staging-$albumId").apply { mkdirs() }
    private fun pageFile(stage: File, idx: Int) = File(stage, "%05d.jpg".format(idx))

    fun files(context: Context): List<File> {
        val result = dir(context).listFiles { f -> f.isFile && (f.extension == "pdf" || f.extension == "cbz") }
            ?.sortedByDescending { it.lastModified() } ?: emptyList()
        val liveNames = result.mapTo(HashSet()) { it.name }
        val stale = meta(context).all.keys.filter { it !in liveNames }
        if (stale.isNotEmpty()) meta(context).edit().also { edit -> stale.forEach(edit::remove) }.apply()
        return result
    }

    fun share(context: Context, file: File) {
        val uri: Uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = if (file.extension == "pdf") "application/pdf" else "application/vnd.comicbook+zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "分享文件").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Best effort: also drop a copy into the system Downloads folder (Android 10+). */
    private fun exportToDownloads(context: Context, file: File) {
        if (Build.VERSION.SDK_INT < 29) return
        try {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/JMReader")
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return
            var ok = false
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { it.copyTo(out) }
                }
                ok = true
            } catch (e: Exception) { /* fall through to cleanup */ }
            if (!ok) runCatching { resolver.delete(uri, null, null) }
        } catch (e: Exception) { /* export is best-effort; the in-app copy is authoritative */ }
    }

    fun enqueue(context: Context, album: JmApi.Album) {
        val existing = tasks.firstOrNull { it.albumId == album.id }
        if (existing?.state == State.RUNNING) return
        val task = existing ?: Task(album, State.RUNNING, 0, 0).also { tasks.add(0, it) }
        task.state = State.RUNNING
        task.error = null
        val appCtx = context.applicationContext
        scope.launch {
            try {
                val detail = JmApi.album(album.id)
                val chapters = parseSeries(detail, album.id)
                val chapterImages: List<List<String>> = coroutineScope {
                    chapters.map { (cid, _) ->
                        async {
                            val ch = JmApi.chapter(cid)
                            val imgs = ch.optJSONArray("images")
                            (0 until (imgs?.length() ?: 0)).map { imgs!!.optString(it) }
                        }
                    }.awaitAll()
                }
                val pages = mutableListOf<Pair<String, String>>()
                chapters.zip(chapterImages).forEach { (ref, files) ->
                    files.forEach { pages.add(ref.first to it) }
                }
                val stage = stagingDir(appCtx, album.id)
                val counter = AtomicInteger(pages.indices.count { pageFile(stage, it).let { f -> f.exists() && f.length() > 0 } })
                withContext(Dispatchers.Main) { task.total = pages.size; task.done = counter.get() }
                // Stage 1: fetch + descramble each page to a JPEG on disk (8-way parallel,
                // 3 attempts per page with a short backoff). Pages already on disk are
                // skipped, so a failed or killed download resumes where it stopped
                // instead of starting over.
                val sem = Semaphore(8)
                coroutineScope {
                    pages.mapIndexed { idx, (cid, f) ->
                        async {
                            val out = pageFile(stage, idx)
                            if (out.exists() && out.length() > 0) return@async
                            sem.withPermit {
                                var lastErr: Exception? = null
                                var ok = false
                                var attempt = 0
                                while (!ok && attempt < 3) {
                                    attempt++
                                    try {
                                        val bytes = JmApi.fetchPhoto(cid, f)
                                        val bmp = Descramble.decode(bytes, cid, f)
                                        out.outputStream().buffered().use { bmp.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                                        if (!bmp.isRecycled) bmp.recycle()
                                        ok = true
                                    } catch (e: Exception) {
                                        lastErr = e
                                        if (!ok && attempt < 3) kotlinx.coroutines.delay(300L * attempt)
                                    }
                                }
                                if (!ok) throw lastErr ?: IllegalStateException("page failed")
                            }
                            val n = counter.incrementAndGet()
                            withContext(Dispatchers.Main) { task.done = n }
                        }
                    }.awaitAll()
                }
                // Stage 2: assemble the PDF one page at a time from disk, so a long book
                // no longer sits in memory as raw bitmaps before anything is written.
                val outFile = File(dir(appCtx), "${album.id}_${album.name.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(40)}.pdf")
                val doc = android.graphics.pdf.PdfDocument()
                try {
                    for (idx in pages.indices) {
                        val bmp = BitmapFactory.decodeFile(pageFile(stage, idx).absolutePath)
                            ?: throw IllegalStateException("bad page $idx")
                        val info = android.graphics.pdf.PdfDocument.PageInfo.Builder(bmp.width, bmp.height, idx + 1).create()
                        val page = doc.startPage(info)
                        page.canvas.drawBitmap(bmp, 0f, 0f, null)
                        doc.finishPage(page)
                        bmp.recycle()
                    }
                    outFile.outputStream().buffered().use { doc.writeTo(it) }
                } finally {
                    doc.close()
                }
                exportToDownloads(appCtx, outFile)
                saveMeta(appCtx, outFile, album.id, album.name)
                stage.deleteRecursively()
                withContext(Dispatchers.Main) { task.state = State.DONE }
            } catch (e: Exception) {
                // Staged pages stay on disk: tapping 继续 resumes from them.
                withContext(Dispatchers.Main) {
                    task.error = e.message ?: e.javaClass.simpleName
                    task.state = State.FAILED
                }
            }
        }
    }
}

/** album.series -> ordered (chapterId, name) list; falls back to the album itself as a single chapter. */
fun parseSeries(detail: JSONObject, albumId: String): List<Pair<String, String>> {
    val arr = detail.optJSONArray("series")
    val out = mutableListOf<Triple<String, String, Int>>()
    if (arr != null) {
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val sort = o.optInt("sort", i + 1)
            val raw = o.optString("name").trim()
            // Live payload shape: series names are "" for some chapters and a
            // bare episode number ("9", "10") for others — never a full label,
            // so build the display label here instead of showing the raw value.
            val label = when {
                raw.isEmpty() -> "第 $sort 话"
                raw.all { it.isDigit() } -> "第 $raw 话"
                else -> raw
            }
            out.add(Triple(o.optString("id"), label, sort))
        }
    }
    val sorted = out.sortedBy { it.third }.map { it.first to it.second }.filter { it.first.isNotEmpty() }
    return if (sorted.isEmpty()) listOf(albumId to detail.optString("name")) else sorted
}
