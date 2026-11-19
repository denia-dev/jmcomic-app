package com.denia.jmreader

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject

/** API / image host pools (mirror of the iOS LineStore). Pools hold ONLY
 * official JM domains — requests carry the login token, so third-party
 * mirrors never enter. Sources, in order: built-in snapshot; JM's official
 * domain-distribution file (refreshed at most every 6h); our own fallback
 * list, merge-only. A manual pin beats the automatic order. */
object Lines {
    data class Line(val host: String, val name: String)

    val BUILTIN_API = listOf(
        Line("www.cdnhjk.net", "线路1"),
        Line("www.cdnutc.cc", "线路2"),
        Line("www.cdngwc.net", "线路3"),
        Line("www.cdngwc.club", "线路4"),
        Line("www.cdnutc.me", "线路5"),
    )
    val BUILTIN_IMG = listOf(
        "cdn-msp2.jmapiproxy1.cc", "cdn-msp3.jmapiproxy1.cc", "cdn-msp3.jmapiproxy3.cc",
        "cdn-msp.jmapiproxy1.cc", "cdn-msp.jmapiproxy2.cc", "cdn-msp2.jmapiproxy2.cc",
        "cdn-msp3.jmapiproxy2.cc", "cdn-msp.jmapinodeudzn.net", "cdn-msp3.jmapinodeudzn.net",
    )
    private val DOMAIN_FILE_URLS = listOf(
        "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c03.tos-cn-beijing.bytepluses.com.cn/newsvr-2025.txt",
    )
    private const val FALLBACK_LIST_URL = "https://my-modules.peimingliang8.workers.dev/jm/domains.json"

    private var prefs: SharedPreferences? = null
    var apiPool by mutableStateOf(BUILTIN_API)
        private set
    var imgPool by mutableStateOf(BUILTIN_IMG)
        private set
    var apiManual by mutableStateOf("")
        private set
    var imgManual by mutableStateOf("")
        private set
    var lastRefresh by mutableLongStateOf(0L)
        private set
    @Volatile var preferredApi: String = ""

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.getSharedPreferences("jm.lines", Context.MODE_PRIVATE)
        prefs = p
        try {
            val arr = JSONArray(p.getString("apiPool", "[]") ?: "[]")
            val lines = (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                val h = o.optString("host")
                if (h.isEmpty()) null else Line(h, o.optString("name", h))
            }
            if (lines.isNotEmpty()) apiPool = lines
        } catch (e: Exception) {}
        try {
            val arr = JSONArray(p.getString("imgPool", "[]") ?: "[]")
            val hosts = (0 until arr.length()).map { arr.optString(it) }.filter { it.isNotEmpty() }
            if (hosts.isNotEmpty()) imgPool = hosts
        } catch (e: Exception) {}
        apiManual = p.getString("apiManual", "") ?: ""
        imgManual = p.getString("imgManual", "") ?: ""
        lastRefresh = p.getLong("lastRefresh", 0L)
    }

    private fun persist() {
        val p = prefs ?: return
        val arr = JSONArray()
        apiPool.forEach { arr.put(JSONObject().put("host", it.host).put("name", it.name)) }
        p.edit()
            .putString("apiPool", arr.toString())
            .putString("imgPool", JSONArray(imgPool).toString())
            .putString("apiManual", apiManual)
            .putString("imgManual", imgManual)
            .putLong("lastRefresh", lastRefresh)
            .apply()
    }

    fun orderedApiHosts(): List<String> {
        val hosts = apiPool.map { it.host }
        val out = mutableListOf<String>()
        if (apiManual.isNotEmpty() && hosts.contains(apiManual)) out.add(apiManual)
        if (preferredApi.isNotEmpty() && hosts.contains(preferredApi) && !out.contains(preferredApi)) out.add(preferredApi)
        hosts.forEach { if (!out.contains(it)) out.add(it) }
        return out
    }

    fun orderedImgHosts(): List<String> {
        if (imgManual.isEmpty() || !imgPool.contains(imgManual)) return imgPool
        return listOf(imgManual) + imgPool.filter { it != imgManual }
    }

    fun currentImgHost(): String = orderedImgHosts().firstOrNull() ?: BUILTIN_IMG[0]

    fun pinApi(host: String) {
        apiManual = host
        preferredApi = ""
        persist()
    }

    fun pinImg(host: String) {
        imgManual = host
        persist()
        JmApi.imgHost = currentImgHost()
    }

    /** A host that just served an image moves to the front of the pool, so
     *  one unreachable front host stops breaking every image. A manual pin
     *  is the user's own choice and is left alone. */
    fun promoteImgHost(host: String) {
        if (imgManual.isNotEmpty() || !imgPool.contains(host)) return
        if (imgPool.firstOrNull() == host) { JmApi.imgHost = host; return }
        imgPool = listOf(host) + imgPool.filter { it != host }
        persist()
        JmApi.imgHost = currentImgHost()
    }

    /** /setting reports an official image host; adopt it into the pool. */
    fun noteSettingImgHost(host: String) {
        val h = host.removePrefix("https://").removePrefix("http://").trimEnd('/')
        if (h.isEmpty() || imgPool.contains(h)) return
        imgPool = listOf(h) + imgPool
        persist()
        if (imgManual.isEmpty()) JmApi.imgHost = currentImgHost()
    }

    /** Refresh pools from the official domain file; the fallback list only
     * ever adds hosts. Throttled to once per 6 hours unless forced. */
    suspend fun refresh(force: Boolean): Boolean {
        if (!force && System.currentTimeMillis() - lastRefresh < 6 * 3600 * 1000L) return false
        var changed = false
        for (url in DOMAIN_FILE_URLS) {
            try {
                val text = String(JmApi.fetchBytes(url), Charsets.UTF_8)
                val lines = JmApi.decryptDomainFile(text)
                if (!lines.isNullOrEmpty()) {
                    apiPool = lines.map { Line(it.first, it.second) }
                    changed = true
                    break
                }
            } catch (e: Exception) { /* try the next mirror */ }
        }
        try {
            val obj = JSONObject(String(JmApi.fetchBytes(FALLBACK_LIST_URL), Charsets.UTF_8))
            val apiArr = obj.optJSONArray("api_hosts")
            if (apiArr != null) {
                val extra = (0 until apiArr.length()).map { apiArr.optString(it) }
                    .filter { it.isNotEmpty() && apiPool.none { l -> l.host == it } }
                if (extra.isNotEmpty()) { apiPool = apiPool + extra.map { Line(it, it) }; changed = true }
            }
            val imgArr = obj.optJSONArray("img_hosts")
            if (imgArr != null) {
                val extra = (0 until imgArr.length()).map { imgArr.optString(it) }
                    .filter { it.isNotEmpty() && !imgPool.contains(it) }
                if (extra.isNotEmpty()) { imgPool = imgPool + extra; changed = true }
            }
        } catch (e: Exception) {}
        lastRefresh = System.currentTimeMillis()
        persist()
        if (imgManual.isEmpty()) JmApi.imgHost = currentImgHost()
        return changed
    }
}
