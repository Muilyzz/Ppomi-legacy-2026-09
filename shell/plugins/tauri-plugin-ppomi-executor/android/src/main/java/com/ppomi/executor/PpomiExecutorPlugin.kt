package com.ppomi.executor

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.Permission
import app.tauri.annotation.PermissionCallback
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import com.ppomi.androidbridge.AndroidExecutor
import com.ppomi.androidbridge.ForegroundHost
import org.json.JSONObject

@InvokeArg
class RequestArgs { lateinit var request: String }

@TauriPlugin(permissions = [
    Permission(alias = "microphone", strings = [Manifest.permission.RECORD_AUDIO]),
    Permission(alias = "notifications", strings = [Manifest.permission.POST_NOTIFICATIONS])
])
class PpomiExecutorPlugin(private val owner: Activity) : Plugin(owner), ForegroundHost {
    override val executorActivity: Activity get() = owner
    private val executor = AndroidExecutor.get(owner.applicationContext)
    private var permissionInvoke: Invoke? = null
    private var permissionResult: ((Boolean) -> Unit)? = null
    private var loadedView: WebView? = null

    override fun load(webView: WebView) {
        loadedView = webView
        executor.attach(this)
        executor.addEventListener(this) { event -> trigger("notification", JSObject(event.toString())) }
        // Keep microphone authorization at the native boundary even if page code asks directly.
        val previous = webView.webChromeClient
        webView.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                val origin = request.origin
                val local = origin.host == "tauri.localhost" || (com.ppomi.androidbridge.BuildConfig.DEBUG &&
                    origin.host in setOf("localhost", "127.0.0.1", "10.0.2.2"))
                val current = webView.url?.let(android.net.Uri::parse)
                val sameOrigin = current != null && origin.scheme == current.scheme && origin.host == current.host && origin.port == current.port
                val onlyAudio = request.resources.isNotEmpty() && request.resources.all { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
                if (webView === loadedView && local && sameOrigin && onlyAudio && executor.active && executor.mode == "voice" &&
                    ContextCompat.checkSelfPermission(owner, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                    request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
                else request.deny()
            }
            override fun onProgressChanged(view: WebView?, progress: Int) { previous?.onProgressChanged(view, progress) }
            override fun onReceivedTitle(view: WebView?, title: String?) { previous?.onReceivedTitle(view, title) }
            override fun onConsoleMessage(message: ConsoleMessage): Boolean = true
        }
    }

    override fun onResume() { executor.attach(this) }
    override fun onStop() { executor.detach(this) }
    override fun onDestroy(activity: AppCompatActivity) {
        permissionResult?.invoke(false)
        permissionResult = null
        permissionInvoke = null
        executor.shutdownIfOwnedBy(this)
        executor.detach(this)
        executor.removeEventListener(this)
        loadedView = null
    }

    @Command
    fun request(invoke: Invoke) {
        val raw = try { invoke.parseArgs(RequestArgs::class.java).request }
            catch (_: Exception) { invoke.reject("invalid_request"); return }
        val request = if (raw.length <= 180_000) runCatching { JSONObject(raw) }.getOrNull() else null
        val startingVoice = request?.optString("method") == "sessionState" &&
            request.optJSONObject("args")?.optBoolean("active") == true &&
            request.optJSONObject("args")?.optString("mode", "voice") == "voice"
        if (startingVoice && permissionInvoke == null) permissionInvoke = invoke
        executor.receive(raw) { response ->
            if (permissionInvoke === invoke) permissionInvoke = null
            invoke.resolve(JSObject(response.toString()))
        }
    }

    override fun requestVoicePermissions(result: (Boolean) -> Unit) {
        if (permissionResult != null) { result(false); return }
        if (hasVoicePermissions()) { result(true); return }
        val invoke = permissionInvoke ?: run { result(false); return }
        permissionResult = result
        val aliases = if (Build.VERSION.SDK_INT >= 33) arrayOf("microphone", "notifications") else arrayOf("microphone")
        requestPermissionForAliases(aliases, invoke, "voicePermissionsResolved")
    }

    @PermissionCallback
    fun voicePermissionsResolved(invoke: Invoke) {
        val result = permissionResult
        permissionResult = null
        result?.invoke(hasVoicePermissions())
    }

    private fun hasVoicePermissions(): Boolean {
        val microphone = ContextCompat.checkSelfPermission(owner, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val notification = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(owner, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return microphone && notification
    }
}
