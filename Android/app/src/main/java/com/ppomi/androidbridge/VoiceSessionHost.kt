package com.ppomi.androidbridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceError
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.toArgb
import androidx.core.content.ContextCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.lang.ref.WeakReference
import java.util.UUID

/** Legacy trusted WebView adapter. AndroidExecutor owns native work independently of this view. */
@SuppressLint("SetJavaScriptEnabled")
internal class VoiceSessionHost private constructor(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val executor = AndroidExecutor.get(context)
    private val familyUpdates = FamilyWebUpdates.get(context)
    private var updateBootstrapped = false
    private var webView: WebView? = null
    private var viewOwner = WeakReference<ForegroundHost>(null)
    var viewGeneration by mutableIntStateOf(0)
        private set
    val active get() = executor.active
    val mode get() = executor.mode
    val agentEndpoint get() = executor.agentEndpoint
    init { executor.addEventListener(this) { event ->
        val name = event.getString("event")
        val payload = event.opt("payload") ?: JSONObject.NULL
        val script = when (name) {
            "notice" -> "window.ppomiNotice?.(${JSONObject.quote(payload.toString())});"
            "incomingCall" -> "window.ppomiIncomingCall?.(${JSONObject.quote(payload.toString())});"
            "answerCall" -> "window.ppomiAnswerCall?.(${JSONObject.quote(payload.toString())});"
            "voiceStop" -> "window.ppomiVoiceStop?.();"
            else -> null
        }
        if (script != null) webView?.takeIf { VoiceBridgePolicy.trustedEntry(it.url) }?.evaluateJavascript(script, null)
    } }
    fun attach(activity: VoiceHostActivity) = executor.attach(activity)
    fun detach(activity: VoiceHostActivity) = executor.detach(activity)
    @JvmOverloads fun turn(id: String?, reason: String, approvalVisible: Boolean = false) = executor.turn(id, reason, approvalVisible)
    fun ring(reason: String) = executor.ring(reason)
    fun heard(text: String) = executor.heard(text)
    fun note(text: String) = executor.note(text)
    fun declineIncoming() = executor.declineIncoming()
    fun incomingDismissed() = executor.incomingDismissed()
    fun answerIncoming(reason: String) = executor.answerIncoming(reason)
    fun stopVoice() = executor.stopVoice()
    fun hasPendingStart() = executor.hasPendingStart()

    /** Refresh native configuration after an idle settings change without replacing the conversation document. */
    fun refreshBootstrap() {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { refreshBootstrap() }; return }
        val view = webView ?: return
        if (active || executor.hasPendingStart() || familyUpdates.startupFailed || !VoiceBridgePolicy.trustedEntry(view.url)) return
        runCatching { view.evaluateJavascript("window.ppomiVoiceRefresh?.();", null) }
    }

    private fun isDark() = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private fun updateStartupFailed(renderNotice: Boolean = true) {
        if (!familyUpdates.failedStartup()) return
        val notice = "새 화면을 시작하지 못했어요. 앱을 완전히 종료한 뒤 다시 열면 이전 화면으로 복구됩니다."
        Toast.makeText(context, notice, Toast.LENGTH_LONG).show()
        // The readiness gate prevents a trial from starting work before this point. Never replace active work.
        if (renderNotice && !active && !executor.hasPendingStart()) webView?.let { view ->
            updateBootstrapped = false
            WebViewCompat.removeWebMessageListener(view, "ppomiAgentNative")
            view.stopLoading()
            view.webViewClient = WebViewClient()
            view.settings.javaScriptEnabled = false
            view.loadDataWithBaseURL(null, "<!doctype html><meta charset=utf-8><p>$notice</p>", "text/html", "UTF-8", null)
        }
    }
    /** The WebView outlives the activity: on every attach the current scheme and text scale are pushed into the page. */
    private fun applyAppearance(view: WebView) {
        view.setBackgroundColor(ppomiPalette(context).bg.toArgb())
        val scale = context.resources.configuration.fontScale
        view.evaluateJavascript("document.documentElement.dataset.theme='${if (isDark()) "dark" else "light"}';" +
            "document.documentElement.style.setProperty('--ui-scale','$scale');", null)
    }

    @JvmOverloads fun obtainView(owner: ForegroundHost? = null): WebView {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (owner != null) viewOwner = WeakReference(owner)
        webView?.let { (it.parent as? ViewGroup)?.removeView(it); applyAppearance(it); return it }
        if (familyUpdates.startupFailed) {
            // A destroyed failed host stays a static recovery notice for the rest of this process.
            return WebView(context).also { view ->
                view.setBackgroundColor(ppomiPalette(context).bg.toArgb())
                view.loadDataWithBaseURL(null, "<!doctype html><meta charset=utf-8><p>앱을 완전히 종료한 뒤 다시 열면 이전 화면으로 복구됩니다.</p>", "text/html", "UTF-8", null)
                webView = view
            }
        }
        check(WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            "Android System WebView를 업데이트해 주세요."
        }
        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", familyUpdates.pathHandler(context)).build()
        val view = WebView(context)
        WebView.setWebContentsDebuggingEnabled(false)
        view.setBackgroundColor(ppomiPalette(context).bg.toArgb())
        view.settings.apply {
            textZoom = 100 // The system font scale reaches the page once, via bootstrap uiScale → --ui-scale.
            javaScriptEnabled = true
            domStorageEnabled = false
            databaseEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
            mediaPlaybackRequiresUserGesture = false // Native explicit session start gates audio capture.
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            setGeolocationEnabled(false)
        }
        if (Build.VERSION.SDK_INT < 33 && WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK)) {
            // Below Android 13 the page's prefers-color-scheme only follows the system with force dark on.
            val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
            @Suppress("DEPRECATION")
            WebSettingsCompat.setForceDark(view.settings, if (dark) WebSettingsCompat.FORCE_DARK_ON else WebSettingsCompat.FORCE_DARK_OFF)
            @Suppress("DEPRECATION")
            if (WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK_STRATEGY))
                WebSettingsCompat.setForceDarkStrategy(view.settings, WebSettingsCompat.DARK_STRATEGY_WEB_THEME_DARKENING_ONLY)
        }
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) { updateBootstrapped = false }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (request.isForMainFrame && VoiceBridgePolicy.trustedEntry(request.url.toString())) return false
                // 답변 속 링크(http/https)는 바깥 브라우저로; 페이지는 떠나지 않는다.
                val scheme = request.url.scheme?.lowercase()
                if (request.isForMainFrame && request.hasGesture() && (scheme == "https" || scheme == "http")) {
                    try { context.startActivity(Intent(Intent.ACTION_VIEW, request.url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
                }
                return true
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                val url = request.url.toString()
                if (VoiceBridgePolicy.bundledAsset(url) && request.method == "GET") {
                    val response = loader.shouldInterceptRequest(request.url) ?: return denied()
                    response.responseHeaders = (response.responseHeaders ?: emptyMap()) + mapOf(
                        "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff",
                        "Content-Security-Policy" to "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src https://api.openai.com wss://api.openai.com/v1/realtime; img-src 'self' data:; font-src 'self'; media-src blob:; frame-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'")
                    return response
                }
                if (!request.isForMainFrame && VoiceBridgePolicy.realtimeSignaling(url, request.method)) return null
                if (!request.isForMainFrame && VoiceBridgePolicy.realtimeWebSocket(url, request.method)) return null
                return denied()
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                updateStartupFailed(renderNotice = false)
                if (view === webView) destroyHost()
                return true
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) updateStartupFailed()
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                val audioOnly = request.resources.isNotEmpty() && request.resources.all { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
                if (webView === view && executor.active && executor.mode == "voice" && request.origin.toString().trimEnd('/') == VoiceBridgePolicy.ORIGIN && audioOnly
                    && ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                    request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
                else request.deny()
            }
            override fun onConsoleMessage(message: ConsoleMessage): Boolean = true // No transcript/tool logs.
        }
        WebViewCompat.addWebMessageListener(view, "ppomiAgentNative", setOf(VoiceBridgePolicy.ORIGIN)) {
                source, message, origin, isMainFrame, _ ->
            if (source === webView && isMainFrame && origin.toString().trimEnd('/') == VoiceBridgePolicy.ORIGIN
                && VoiceBridgePolicy.trustedEntry(source.url)) receive(message.data ?: "") { response ->
                if (source === webView && VoiceBridgePolicy.trustedEntry(source.url))
                    source.evaluateJavascript("window.ppomiAgentReceive?.(${response});", null)
            }
        }
        webView = view
        updateBootstrapped = false
        view.loadUrl(VoiceBridgePolicy.ENTRY)
        if (familyUpdates.trial) main.postDelayed({ updateStartupFailed() }, 30_000)
        familyUpdates.checkInBackground()
        return view
    }

    private fun receive(raw: String, callback: (JSONObject) -> Unit) {
        val request = if (raw.length <= 180_000) runCatching { JSONObject(raw) }.getOrNull() else null
        val id = request?.optString("id").orEmpty()
        val method = request?.optString("method")
        val args = request?.optJSONObject("args") ?: JSONObject()
        if (method == "bootstrap" || method == "updateReady" || method == "sessionState") {
            try {
                check(runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false))
                if (method == "bootstrap") check(!familyUpdates.startupFailed)
                if (method == "sessionState" && args.optBoolean("active")) check(familyUpdates.canStartSession)
                if (method == "updateReady") {
                    check(updateBootstrapped)
                    check(args.length() == 1 && args.opt("bridgeVersion") is Int && args.getInt("bridgeVersion") == 1)
                    familyUpdates.ready()
                    callback(TaskStore.`object`("id", id, "result", JSONObject()))
                    return
                }
            } catch (_: Exception) {
                callback(TaskStore.`object`("id", id, "error", TaskStore.`object`("code", "invalid_request",
                    "message", "요청을 완료하지 못했습니다. 연결·권한·입력 범위를 확인해 주세요.")))
                return
            }
        }
        executor.receive(raw) { response ->
            if (method == "bootstrap") response.optJSONObject("result")?.let { bootstrap ->
                bootstrap.put("nativeBuild", FamilyWebPackage.NATIVE_BUILD).put("bridgeVersion", FamilyWebPackage.BRIDGE_VERSION)
                    .put("webRelease", familyUpdates.release).put("capabilities", JSONArray(listOf("agent.v1")))
                updateBootstrapped = true
            }
            callback(response)
        }
    }

    @JvmOverloads fun destroyHost(owner: ForegroundHost? = viewOwner.get()) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { destroyHost(owner) }; return }
        // A newer legacy activity may already have reused this same WebView.
        if (owner != null && viewOwner.get() != null && viewOwner.get() !== owner) return
        if (owner != null) executor.shutdownIfOwnedBy(owner)
        val view = webView ?: return
        webView = null
        updateBootstrapped = false
        viewOwner.clear()
        main.postDelayed({
            (view.parent as? ViewGroup)?.removeView(view)
            WebViewCompat.removeWebMessageListener(view, "ppomiAgentNative")
            view.stopLoading(); view.clearHistory(); view.clearCache(true); view.destroy()
            viewGeneration++
        }, 100)
    }
    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked",
        mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))
    companion object {
        @Volatile private var instance: VoiceSessionHost? = null
        val TOOLS get() = AndroidExecutor.TOOLS
        fun get(context: Context): VoiceSessionHost = instance ?: synchronized(this) {
            instance ?: VoiceSessionHost(context.applicationContext).also { instance = it }
        }
        @JvmStatic fun hasActiveControl() = AndroidExecutor.hasActiveControl()
        @JvmStatic fun isControlOwner(owner: String?) = AndroidExecutor.isControlOwner(owner)
    }
}
