package com.denia.jmreader

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Update prompt (mirrors the iOS UpdateChecker): compares the installed
 *  version against the repo's latest PUBLISHED GitHub release — public
 *  repo, plain unauthenticated GET; drafts never appear in that endpoint,
 *  so only formal releases prompt. Version numbers follow the project's
 *  decimal scheme (…2.19 -> 2.2), so a Double compare is exact for them. */
object UpdateCheck {
    var latestVersion by mutableStateOf<String?>(null)
        private set
    var latestUrl by mutableStateOf<String?>(null)
        private set
    var checking by mutableStateOf(false)
        private set
    var showPrompt by mutableStateOf(false)

    private const val PREFS = "jm.updatecheck"
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    fun currentVersion(context: Context): String =
        try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
        } catch (e: Exception) { "0" }

    fun isUpdate(current: String): Boolean {
        val l = latestVersion?.toDoubleOrNull() ?: return false
        val c = current.toDoubleOrNull() ?: return false
        return l > c
    }

    /** Silent launch check, throttled to once per 6 hours; the prompt
     *  fires at most once per version (「忽略此版本」 is remembered). */
    suspend fun checkOnLaunch(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val last = prefs.getLong("lastCheck", 0L)
        if (System.currentTimeMillis() - last < 6 * 3600_000L && latestVersion != null) return
        check(context, manual = false)
    }

    suspend fun check(context: Context, manual: Boolean) {
        if (checking) return
        checking = true
        try {
            val body = withContext(Dispatchers.IO) {
                val req = Request.Builder()
                    .url("https://api.github.com/repos/denia-dev/jmcomic-app/releases/latest")
                    .header("Accept", "application/vnd.github+json")
                    .build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    resp.body?.string()
                }
            } ?: return
            val obj = JSONObject(body)
            val tag = obj.optString("tag_name")
            val url = obj.optString("html_url")
            if (tag.isEmpty() || url.isEmpty()) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit().putLong("lastCheck", System.currentTimeMillis()).apply()
            latestVersion = tag.removePrefix("v")
            latestUrl = url
            if (isUpdate(currentVersion(context))) {
                val ignored = prefs.getString("ignored", null)
                if (manual || ignored != latestVersion) showPrompt = true
            }
        } catch (e: Exception) {
            // Offline / GitHub unreachable: stay silent, retry next launch.
        } finally {
            checking = false
        }
    }

    fun ignore(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString("ignored", latestVersion).apply()
        showPrompt = false
    }

    fun openRelease(context: Context) {
        val url = latestUrl ?: return
        try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) { }
        showPrompt = false
    }
}

@Composable
fun UpdatePromptDialog(context: Context) {
    AlertDialog(
        onDismissRequest = { UpdateCheck.showPrompt = false },
        title = { Text("有新版本 v${UpdateCheck.latestVersion ?: ""}") },
        text = {
            Text("当前版本 v${UpdateCheck.currentVersion(context)}，新版本已发布。点「去更新」打开下载页，下载新版 APK 覆盖安装即可。")
        },
        confirmButton = {
            TextButton(onClick = { UpdateCheck.openRelease(context) }) { Text("去更新") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = { UpdateCheck.ignore(context) }) { Text("忽略此版本") }
                TextButton(onClick = { UpdateCheck.showPrompt = false }) { Text("稍后") }
            }
        },
    )
}
