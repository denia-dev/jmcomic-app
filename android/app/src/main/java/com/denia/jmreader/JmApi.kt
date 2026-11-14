package com.denia.jmreader

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

// JM Web API — protocol reverse-engineered & verified live 2026-11-01/02.
// Signing: Token = md5(ts + seed); Tokenparam = "<ts>,<jm3_version>".
// Response data = base64(AES-256-ECB/PKCS7(json)), key = Token hex string as UTF-8.
object JmApi {
    private const val SEED = "185Hcomic3PAPP7R"
    private const val DOMAIN_FILE_SECRET = "diosfjckwpqpdfjkvnqQjsik" // public client key, ships in every open JM client
    @Volatile var apiHost = "www.cdnhjk.net"
    @Volatile var imgHost = "cdn-msp3.jmapiproxy3.cc"
    @Volatile var version = "2.1.12"

    @Volatile var authToken: String? = null   // jwt
    @Volatile var authCookie: String? = null  // AVS value ("s" from login)

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val bootstrapMutex = Mutex()
    @Volatile private var bootstrapped = false

    class ApiException(message: String) : Exception(message)

    private fun md5(s: String): String {
        val d = MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8))
        return d.joinToString("") { "%02x".format(it) }
    }

    private fun tokenPair(): Pair<String, String> {
        val ts = (System.currentTimeMillis() / 1000).toString()
        return md5(ts + SEED) to "$ts,$version"
    }

    private fun decrypt(dataB64: String, token: String): String {
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(token.toByteArray(Charsets.UTF_8), "AES"))
        val plain = cipher.doFinal(Base64.decode(dataB64, Base64.DEFAULT))
        return String(plain, Charsets.UTF_8)
    }

    suspend fun bootstrap() {
        if (bootstrapped) return
        selectHost(null)
        bootstrapped = true
    }

    /** Probe the pool hosts (a host that just failed goes last) and keep the
     *  first one that answers /setting. Pool order comes from Lines. */
    private suspend fun selectHost(failedHost: String?) {
        bootstrapMutex.withLock {
            val pool = Lines.orderedApiHosts()
            val ordered = if (failedHost == null) pool
                          else pool.filter { it != failedHost } + failedHost
            for (host in ordered) {
                try {
                    val d = request("GET", "setting", emptyMap(), null, skipBootstrap = true, host = host)
                    apiHost = host
                    Lines.preferredApi = host
                    version = d.optString("jm3_version", version)
                    d.optString("img_host").takeIf { it.isNotEmpty() }?.let { Lines.noteSettingImgHost(it) }
                    return@withLock
                } catch (e: Exception) { /* try next host */ }
            }
        }
    }

    /** Signed GET; returns decrypted `data` as JSONObject (or throws). */
    suspend fun call(path: String, params: Map<String, String> = emptyMap()): JSONObject =
        request("GET", path, params, null)

    /** Signed form POST. */
    suspend fun callForm(path: String, form: Map<String, String>): JSONObject =
        request("POST", path, emptyMap(), form)

    /** Signed GET for endpoints whose decrypted `data` is a bare JSON array
     *  (promote / latest / random_recommend — shapes verified live 2026-11-02). */
    suspend fun callArray(path: String, params: Map<String, String> = emptyMap()): JSONArray {
        val d = requestData("GET", path, params, null, skipBootstrap = false)
        return d as? JSONArray ?: JSONArray()
    }

    private suspend fun request(method: String, path: String, params: Map<String, String>, form: Map<String, String>?, skipBootstrap: Boolean = false, host: String? = null): JSONObject {
        val d = requestData(method, path, params, form, skipBootstrap, host)
        return d as? JSONObject ?: JSONObject()
    }

    private suspend fun requestData(method: String, path: String, params: Map<String, String>, form: Map<String, String>?, skipBootstrap: Boolean = false, host: String? = null): Any {
        if (skipBootstrap) return executeOnce(method, path, params, form, host ?: apiHost)
        bootstrap()
        for (attempt in 0..2) {
            try {
                return executeOnce(method, path, params, form)
            } catch (e: java.io.IOException) {
                // Transport failure (connection reset / timeout / DNS): switch to
                // the other API host and retry instead of surfacing the raw error.
                if (attempt == 2) break
                selectHost(failedHost = apiHost)
            }
        }
        throw ApiException("网络连接失败，请检查网络后重试")
    }

    private suspend fun executeOnce(method: String, path: String, params: Map<String, String>, form: Map<String, String>?, host: String = apiHost): Any {
        return withContext(Dispatchers.IO) {
            val (token, tokenParam) = tokenPair()
            val allParams = mapOf("lang" to "TW") + params
            val url = StringBuilder("https://$host/$path")
            url.append("?")
            url.append(allParams.entries.joinToString("&") { "${it.key}=${java.net.URLEncoder.encode(it.value, "UTF-8")}" })
            // Header set must mirror the verified web-client fingerprint exactly:
            // probes with a plain Android UA (and no Origin/Referer) hang at the API edge.
            val builder = Request.Builder().url(url.toString())
                .header("token", token)
                .header("tokenparam", tokenParam)
                .header("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1")
                .header("Accept", "*/*")
                .header("Origin", "https://jmapp3.cc")
                .header("Referer", "https://jmapp3.cc/")
                .header("Accept-Language", "zh-CN,zh-Hans;q=0.9")
            authToken?.let { builder.header("Authorization", "Bearer $it") }
            authCookie?.let { builder.header("Cookie", "AVS=$it") }
            if (method == "POST") {
                val fb = FormBody.Builder()
                form?.forEach { (k, v) -> fb.add(k, v) }
                builder.post(fb.build())
            }
            client.newCall(builder.build()).execute().use { resp ->
                val body = resp.body?.string() ?: throw ApiException("空响应")
                val env = JSONObject(body)
                val code = env.optInt("code", -1)
                if (code != 200) {
                    val msg = env.optString("errorMsg", "请求失败 ($code)")
                    throw ApiException(msg.ifEmpty { "请求失败 ($code)" })
                }
                val data = env.opt("data") ?: throw ApiException("无数据")
                when (data) {
                    is JSONObject -> data
                    is JSONArray -> data
                    is String -> {
                        if (data.isEmpty()) JSONObject()
                        else try {
                            val text = decrypt(data, token).trim()
                            if (text.startsWith("[")) JSONArray(text) else JSONObject(text)
                        }
                        catch (e: Exception) { JSONObject().put("_raw", data) }
                    }
                    else -> JSONObject().put("_raw", data.toString())
                }
            }
        }
    }

    // ---------- endpoints ----------
    suspend fun promote(): List<Pair<String, List<Album>>> {
        // Live shape: bare array of sections {title, content[]} (verified 2026-11-02).
        val arr = callArray("promote")
        val out = mutableListOf<Pair<String, List<Album>>>()
        for (i in 0 until arr.length()) {
            val sec = arr.optJSONObject(i) ?: continue
            val title = sec.optString("title")
            val items = parseAlbums(sec.optJSONArray("content"))
            if (items.isNotEmpty()) out.add(title to items)
        }
        return out
    }

    suspend fun latest(page: Int): List<Album> = parseAlbums(callArray("latest", mapOf("page" to page.toString())))

    /** order: mr 最新 / mv 最多观看 / tf 最多爱心 / mp 最多图片;
     *  mainTag: 0 全部 / 1 作品 / 2 作者 / 3 标签 / 4 登场人物.
     *  A pure-numeric query answers with redirect_aid instead of results. */
    suspend fun search(query: String, page: Int, order: String = "mr", mainTag: Int = 0): Triple<Int, List<Album>, String?> {
        val d = call("search", mapOf(
            "search_query" to query, "page" to page.toString(),
            "o" to order, "main_tag" to mainTag.toString()))
        val redirect = d.optString("redirect_aid").ifEmpty { null }
        return Triple(d.optInt("total"), parseAlbums(d.optJSONArray("content")), redirect)
    }

    data class Category(val slug: String, val name: String)
    suspend fun categories(): List<Category> {
        val d = call("categories")
        // Live shape: {categories: [{slug, name}...], blocks: [...]} (verified 2026-11-02).
        val arr = d.optJSONArray("categories") ?: return emptyList()
        val out = mutableListOf<Category>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(Category(o.optString("slug"), o.optString("name")))
        }
        return out
    }

    suspend fun categoryFilter(slug: String, page: Int): List<Album> =
        parseAlbums(call("categories/filter", mapOf("c" to slug, "o" to "new", "page" to page.toString())).optJSONArray("content"))

    suspend fun randomRecommend(): List<Album> = parseAlbums(callArray("random_recommend"))

    /** The server's random_recommend returns the same ~30 newest albums
     *  shuffled on every call (verified live 2026-11-14: three calls, one
     *  identical id set), so build our own pool like iOS: a random window
     *  of the latest feed (80 per page), deduped and shuffled. Falls back
     *  to the server list when the feed cannot be read at all. */
    suspend fun randomPool(): List<Album> {
        val start = (1..24).random()
        val seen = HashSet<String>()
        val pool = mutableListOf<Album>()
        for (p in start until start + 3) {
            val items = try { latest(p) } catch (e: Exception) { break }
            for (a in items) if (seen.add(a.id)) pool.add(a)
        }
        if (pool.isEmpty()) return randomRecommend()
        return pool.shuffled().take(36)
    }

    suspend fun album(id: String): JSONObject = call("album", mapOf("id" to id))
    suspend fun chapter(id: String): JSONObject = call("chapter", mapOf("id" to id))

    suspend fun login(username: String, password: String): JSONObject =
        callForm("login", mapOf("username" to username, "password" to password))

    data class Folder(val fid: String, val name: String)

    suspend fun favorites(page: Int, folderId: String = "0"): Triple<Int, List<Album>, List<Folder>> {
        val d = call("favorite", mapOf("page" to page.toString(), "folder_id" to folderId))
        // Live shape: items live under "list", not "content" (verified 2026-11-02);
        // the folder list rides along as "folder_list" [{FID, name}].
        val folders = mutableListOf<Folder>()
        d.optJSONArray("folder_list")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                folders.add(Folder(o.optString("FID"), o.optString("name")))
            }
        }
        return Triple(d.optInt("total"), parseAlbums(d.optJSONArray("list")), folders)
    }

    /** The favorite endpoint is a TOGGLE (verified live 2026-11-05): every
     * POST flips the server-side state and the response `type` reports what
     * actually happened ("add" / "remove"). Returns the state after the call. */
    suspend fun toggleFavorite(aid: String): Boolean {
        val d = callForm("favorite", mapOf("aid" to aid))
        val t = d.optString("type")
        if (t.isEmpty()) throw ApiException("收藏接口返回异常")
        return t == "add"
    }

    suspend fun folderAdd(name: String) {
        callForm("favorite_folder", mapOf("type" to "add", "folder_name" to name))
    }

    suspend fun folderDel(fid: String) {
        callForm("favorite_folder", mapOf("type" to "del", "folder_id" to fid))
    }

    /** A comic lives in exactly ONE folder — this moves it. */
    suspend fun folderMove(fid: String, aid: String) {
        callForm("favorite_folder", mapOf("type" to "move", "folder_id" to fid, "aid" to aid))
    }

    suspend fun daily(userId: String): JSONObject = call("daily", mapOf("user_id" to userId))
    suspend fun dailyCheck(userId: String, dailyId: String): JSONObject =
        callForm("daily_chk", mapOf("user_id" to userId, "daily_id" to dailyId))

    // ---------- images ----------
    fun coverUrl(id: String) = "https://$imgHost/media/albums/${id}_3x4.jpg"
    fun photoUrl(chapterId: String, file: String) = "https://$imgHost/media/photos/$chapterId/$file"

    suspend fun fetchBytes(url: String): ByteArray = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url)
            .header("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw ApiException("图片加载失败 ${resp.code}")
            resp.body?.bytes() ?: throw ApiException("图片为空")
        }
    }

    /** Raw JSON POST for our own worker endpoints (folder registry). */
    suspend fun postJson(url: String, json: String): String? = withContext(Dispatchers.IO) {
        try {
            val body = json.toRequestBody("application/json".toMediaType())
            val req = Request.Builder().url(url).post(body).build()
            client.newCall(req).execute().use { resp -> if (resp.isSuccessful) resp.body?.string() else null }
        } catch (e: Exception) { null }
    }

    /** Milliseconds for a /setting round trip on one host, or null on failure. */
    suspend fun probeApiHost(host: String): Long? {
        val t0 = System.nanoTime()
        return try {
            request("GET", "setting", emptyMap(), null, skipBootstrap = true, host = host)
            (System.nanoTime() - t0) / 1_000_000
        } catch (e: Exception) { null }
    }

    /** The official domain file is base64 AES-256-ECB, key = md5(secret) hex
     *  string — the same construction as the API envelope. Returns
     *  (host, display name) lines, or null when undecodable. */
    fun decryptDomainFile(text: String): List<Pair<String, String>>? {
        return try {
            val cleaned = text.filter { it.isLetterOrDigit() || it == '+' || it == '/' || it == '=' }
            if (cleaned.isEmpty()) return null
            val plain = decrypt(cleaned, md5(DOMAIN_FILE_SECRET))
            val obj = JSONObject(plain)
            val pairs = obj.optJSONArray("jm3_Server")
            if (pairs != null && pairs.length() > 0) {
                val out = mutableListOf<Pair<String, String>>()
                for (i in 0 until pairs.length()) {
                    val p = pairs.optJSONArray(i) ?: continue
                    val host = p.optString(0)
                    if (host.isNotEmpty()) out.add(host to p.optString(1, host))
                }
                if (out.isNotEmpty()) return out
            }
            val servers = obj.optJSONArray("Server")
            if (servers != null && servers.length() > 0) {
                return (0 until servers.length()).map { servers.optString(it) to "线路${it + 1}" }
            }
            null
        } catch (e: Exception) { null }
    }

    // ---------- models ----------
    data class Album(
        val id: String,
        val name: String,
        val author: String,
        val tags: List<String>,
        val totalViews: String,
        val likes: String,
    )

    fun parseAlbums(arr: JSONArray?): List<Album> {
        if (arr == null) return emptyList()
        val out = mutableListOf<Album>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optString("type") == "novel") continue
            val authors = mutableListOf<String>()
            val a = o.opt("author")
            if (a is JSONArray) for (j in 0 until a.length()) authors.add(a.optString(j))
            else if (a is String && a.isNotEmpty()) authors.add(a)
            val tags = mutableListOf<String>()
            val t = o.optJSONArray("tags")
            if (t != null) for (j in 0 until t.length()) tags.add(t.optString(j))
            out.add(Album(
                id = o.optString("id"),
                name = o.optString("name"),
                author = authors.joinToString(" / "),
                tags = tags,
                totalViews = o.optString("total_views"),
                likes = o.optString("likes"),
            ))
        }
        return out
    }

    /** uid lives in the JWT payload's SESSION object. */
    fun uidFromJwt(jwt: String): String {
        return try {
            val payload = jwt.split(".")[1]
            val json = String(Base64.decode(payload, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING), Charsets.UTF_8)
            val session = JSONObject(json).optJSONObject("SESSION") ?: return ""
            session.opt("uid")?.toString() ?: ""
        } catch (e: Exception) { "" }
    }
}
