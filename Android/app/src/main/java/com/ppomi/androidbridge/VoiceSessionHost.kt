package com.ppomi.androidbridge

import android.Manifest
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.res.Configuration
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.toArgb
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Application-owned trusted UI. The explicitly started foreground service retains it during control. */
@SuppressLint("SetJavaScriptEnabled")
internal class VoiceSessionHost private constructor(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(32),
        { task -> Thread(task, "ppomi-voice-tools") }, ThreadPoolExecutor.AbortPolicy())
    private val server = VoiceServerClient(context)
    private val workspace = AgentWorkspace(context)
    private val preferences = context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE)
    private var activity = WeakReference<VoiceHostActivity>(null)
    private var webView: WebView? = null
    private val pending = mutableSetOf<String>()
    private var startingId: String? = null
    private var serviceOwner: VoiceForegroundService? = null
    private var previousAudioMode = AudioManager.MODE_NORMAL
    @Volatile private var controlId: String? = null
    @Volatile var active = false
        private set
    @Volatile var mode = "voice"
        private set
    @Volatile private var generation = 0
    var viewGeneration by mutableIntStateOf(0)
        private set

    fun attach(activity: VoiceHostActivity) { this.activity = WeakReference(activity) }
    fun detach(activity: VoiceHostActivity) {
        if (this.activity.get() === activity) this.activity.clear()
        if (!active && startingId != null) stopVoice()
    }
    private fun foregroundActivity(): VoiceHostActivity? = activity.get()?.takeIf {
        !it.isFinishing && it.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    }
    /** Agent server address. The 설정 tab writes it; every bootstrap and request re-reads it. Fixed while a session runs. */
    var agentEndpoint: String
        get() = preferences.getString("endpoint", "") ?: ""
        set(value) {
            check(!active && startingId == null) { "대화를 끝낸 뒤 바꿔 주세요." }
            check(preferences.edit().putString("endpoint", VoiceBridgePolicy.endpoint(value)).commit())
        }

    /**
     * 비서의 단계(docs/ui-tree.md): 사람 차례가 오면 0 톡(페이지 말풍선 + 조용한 알림) → 1분 뒤 재촉(알림 다시) →
     * 3분째 답이 없으면 전화(ring). 차례가 풀리면(null) 모두 취소하고 벨도 내린다. 같은 차례는 다시 시작하지 않는다.
     */
    private var turnId: String? = null
    private var turnReason = ""
    private val nudge = Runnable { TurnNotifier.show(context, turnReason, nudge = true) }
    private val escalate = Runnable { ring(turnReason) }
    fun turn(id: String?, reason: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { turn(id, reason) }; return }
        if (id == turnId) return
        main.removeCallbacks(nudge); main.removeCallbacks(escalate)
        turnId = id
        if (id == null) { TurnNotifier.cancel(context); ring(""); return }
        turnReason = reason
        webView?.evaluateJavascript("window.ppomiNotice?.(${JSONObject.quote(reason)});", null)
        TurnNotifier.show(context, reason, nudge = false)
        main.postDelayed(nudge, NUDGE_MS); main.postDelayed(escalate, CALL_MS)
    }

    /** The person's turn went unanswered (or debug): an OS incoming call (ring, lock screen, 받기/거절) plus the page's banner.
     *  Empty = resolved. A ring nobody answers ends as missed after RING_MS; the 톡 stays in the conversation. */
    private val missed = Runnable {
        PpomiTelecom.connection?.takeIf { it.state == android.telecom.Connection.STATE_RINGING }?.let {
            PpomiTelecom.callEnded(android.telecom.DisconnectCause.MISSED); incomingDismissed()
        }
    }
    fun ring(reason: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { ring(reason) }; return }
        main.removeCallbacks(missed)
        webView?.evaluateJavascript("window.ppomiIncomingCall?.(${JSONObject.quote(reason)});", null)
        if (reason.isEmpty()) {
            PpomiTelecom.connection?.takeIf { it.state == android.telecom.Connection.STATE_RINGING }
                ?.let { PpomiTelecom.callEnded(android.telecom.DisconnectCause.CANCELED) }
            return
        }
        if (PpomiTelecom.ring(context, reason)) main.postDelayed(missed, RING_MS)
    }
    /** 구두 결재: 통화 중 사람이 "승인"/"취소"라고 말하면 차례 띠의 그 버튼과 같다(모델의 말이 아니라 사람의 전사).
     *  잠긴 기기에서는 하지 않는다(잠금 화면에서 결제 승인 금지). */
    fun heard(text: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { heard(text) }; return }
        val id = turnId ?: return
        if (context.getSystemService(KeyguardManager::class.java).isDeviceLocked) return
        val choice = VoiceApproval.choice(text) ?: return
        val runner = LocalTaskRunner.get(context)
        runCatching { if (choice == "승인") runner.approve(id) else runner.cancel(id) }.onSuccess { note("말로 $choice · $turnReason") }
    }
    /** 결재 기록 한 줄을 대화에 남긴다("승인 · 용건"). 버튼이든 말이든. */
    fun note(text: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { note(text) }; return }
        webView?.evaluateJavascript("window.ppomiNotice?.(${JSONObject.quote(text)});", null)
    }
    /** The page's 나중에: same as declining on the OS call screen. */
    fun declineIncoming() { main.post { PpomiTelecom.connection?.takeIf { it.state == android.telecom.Connection.STATE_RINGING }?.reject() } }

    /** The OS call UI answered (CallActivity is in front, maybe over the lock screen): the page starts the call about this
     *  reason. Without a page yet (cold start) the WebView is created unattached and the reason rides on its bootstrap. */
    @Volatile private var pendingAnswer: String? = null
    fun answerIncoming(reason: String) {
        pendingAnswer = reason
        main.post {
            val view = webView ?: obtainView()
            if (VoiceBridgePolicy.trustedEntry(view.url)) {
                view.evaluateJavascript("window.ppomiAnswerCall?.(${JSONObject.quote(reason)});", null); pendingAnswer = null
            }
        }
    }
    /** The OS call UI declined: the page drops its banner too. */
    fun incomingDismissed() { main.post { webView?.evaluateJavascript("window.ppomiIncomingCall?.('');", null) } }

    private fun isDark() = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    /** The WebView outlives the activity: on every attach the current scheme and text scale are pushed into the page. */
    private fun applyAppearance(view: WebView) {
        view.setBackgroundColor(ppomiPalette(context).bg.toArgb())
        val scale = context.resources.configuration.fontScale
        view.evaluateJavascript("document.documentElement.dataset.theme='${if (isDark()) "dark" else "light"}';" +
            "document.documentElement.style.setProperty('--ui-scale','$scale');", null)
    }

    fun obtainView(): WebView {
        check(Looper.myLooper() == Looper.getMainLooper())
        webView?.let { (it.parent as? ViewGroup)?.removeView(it); applyAppearance(it); return it }
        check(WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            "Android System WebView를 업데이트해 주세요."
        }
        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context)).build()
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
                if (view === webView) destroyHost()
                return true
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                val audioOnly = request.resources.isNotEmpty() && request.resources.all { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
                if (webView === view && active && mode == "voice" && request.origin.toString().trimEnd('/') == VoiceBridgePolicy.ORIGIN && audioOnly
                    && ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                    request.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
                else request.deny()
            }
            override fun onConsoleMessage(message: ConsoleMessage): Boolean = true // No transcript/tool logs.
        }
        WebViewCompat.addWebMessageListener(view, "ppomiAgentNative", setOf(VoiceBridgePolicy.ORIGIN)) {
                source, message, origin, isMainFrame, _ ->
            if (source === webView && isMainFrame && origin.toString().trimEnd('/') == VoiceBridgePolicy.ORIGIN
                && VoiceBridgePolicy.trustedEntry(source.url)) receive(message.data ?: "")
        }
        webView = view
        view.loadUrl(VoiceBridgePolicy.ENTRY)
        return view
    }

    private fun receive(raw: String) {
        if (raw.length > 180_000) return
        val request = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val id = request.optString("id")
        if (runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false).not()) return
        if (pending.size >= 32 || !pending.add(id)) return
        val epoch = generation
        val method = request.optString("method")
        val args = request.optJSONObject("args") ?: JSONObject()
        try {
            when (method) {
                "bootstrap" -> reply(id, TaskStore.`object`("platform", "android", "deviceLabel", "뽀미 Android",
                    "answerCall", (pendingAnswer ?: JSONObject.NULL).also { pendingAnswer = null },
                    "uiScale", context.resources.configuration.fontScale.toDouble(), "dark", isDark(),
                    "configured", agentEndpoint.isNotEmpty() && server.configured(), "endpoint", agentEndpoint,
                    "accessibility", BridgeAccessibilityService.getInstance() != null,
                    "controlApps", BridgeAccessPolicy.controlApps(context),
                    "tools", JSONArray(TOOLS)), epoch)
                "sessionState" -> {
                    if (args.opt("active") !is Boolean) throw IllegalArgumentException()
                    if (args.getBoolean("active")) beginSession(id, epoch, args.optString("mode", "voice"))
                    else { reply(id, TaskStore.`object`("active", false), epoch); stopVoice() }
                }
                "declineCall" -> { declineIncoming(); reply(id, TaskStore.`object`("declined", true), epoch) }
                "heard" -> { check(active && mode == "voice"); heard(args.getString("text").take(500)); reply(id, TaskStore.`object`("heard", true), epoch) }
                "setEndpoint" -> {
                    check(foregroundActivity() != null)
                    agentEndpoint = args.getString("endpoint")
                    reply(id, TaskStore.`object`("endpoint", agentEndpoint), epoch)
                }
                "request" -> {
                    val path = args.getString("path")
                    val needsSession = path == "/v1/session" || path == "/v1/responses" || path == "/v1/memories/save"
                    if (needsSession) check(active)
                    else check(foregroundActivity() != null || active)
                    val body = args.getJSONObject("body")
                    worker.execute {
                        try {
                            val result = server.request(agentEndpoint, path, body) { generation == epoch && (!needsSession || active) }
                            main.post { reply(id, result, epoch) }
                        } catch (_: Exception) { main.post { failure(id, "server_request_failed", epoch) } }
                    }
                }
                "executeTool" -> {
                    if (!active) throw VoiceToolErrors.Failure("protected_action")
                    val name = args.getString("name")
                    val toolArgs = args.optJSONObject("args") ?: JSONObject()
                    check(TOOLS.contains(name))
                    worker.execute {
                        try {
                            check(active && generation == epoch)
                            val result = executeTool(name, toolArgs, epoch)
                            main.post { reply(id, result, epoch) }
                        } catch (error: Exception) { main.post { failure(id, VoiceToolErrors.code(error), epoch) } }
                    }
                }
                else -> failure(id, "unsupported_method", epoch)
            }
        } catch (error: Exception) { failure(id, if (method == "executeTool") VoiceToolErrors.code(error) else "invalid_request", epoch) }
    }

    private fun beginSession(id: String, epoch: Int, requestedMode: String) {
        require(requestedMode == "text" || requestedMode == "voice")
        if (active) {
            check(mode == requestedMode)
            reply(id, TaskStore.`object`("active", true, "mode", mode), epoch); return
        }
        check(startingId == null && LocalTaskRunner.actionOwner() == null)
        val foreground = foregroundActivity() ?: throw IllegalStateException()
        mode = requestedMode
        startingId = id
        val start: (Boolean) -> Unit = start@ { granted ->
            if (generation != epoch || startingId != id) return@start
            if (!granted || foregroundActivity() == null) {
                startingId = null
                failure(id, if (requestedMode == "voice") "microphone_or_notification_permission_required" else "session_start_failed", epoch)
            } else {
                try {
                    ContextCompat.startForegroundService(context, Intent(context, VoiceForegroundService::class.java)
                        .setAction(VoiceForegroundService.START))
                } catch (_: Exception) { startingId = null; failure(id, "session_start_failed", epoch) }
            }
        }
        if (requestedMode == "voice") foreground.requestVoicePermissions(start)
        else start(true)
    }

    /** Called after the service enters the foreground type appropriate for this session. */
    fun serviceStarted(service: VoiceForegroundService): Boolean {
        val id = startingId ?: return false
        if (foregroundActivity() == null || LocalTaskRunner.actionOwner() != null) {
            startingId = null; failure(id, "voice_start_failed", generation); return false
        }
        if (mode == "voice") {
            // Audio focus belongs to the OS call (PpomiTelecom): our own request would hear Telecom's focus grab as a
            // LOSS and kill the session. Another real call puts ours on hold, which ends it (PpomiConnection.onHold).
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            previousAudioMode = audio.mode
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        controlId = "voice:" + UUID.randomUUID()
        active = true
        serviceOwner = service
        startingId = null
        if (mode == "voice") PpomiTelecom.callStarted(context)
        reply(id, TaskStore.`object`("active", true, "mode", mode), generation)
        return true
    }

    fun hasPendingStart(): Boolean = startingId != null

    fun serviceDestroyed(service: VoiceForegroundService) {
        if (serviceOwner === service) stopVoice()
    }

    /** A session ends (JS 끊기, notification stop, service death) but the page stays: the call's log survives. */
    fun stopVoice() {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { stopVoice() }; return }
        // JS stop, notification stop, and service destruction can all arrive for the same session.
        if (!active && startingId == null) return
        endSession()
        webView?.let { view ->
            if (VoiceBridgePolicy.trustedEntry(view.url)) runCatching { view.evaluateJavascript("window.ppomiVoiceStop?.();", null) }
        }
        context.stopService(Intent(context, VoiceForegroundService::class.java))
    }

    fun destroyHost() {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { destroyHost() }; return }
        val hadSession = active || startingId != null
        clearHost()
        if (hadSession) context.stopService(Intent(context, VoiceForegroundService::class.java))
    }

    /** Everything a session owns, except the WebView. */
    private fun endSession() {
        if (!active && startingId == null) return
        val owner = controlId
        active = false
        mode = "voice"
        serviceOwner = null
        controlId = null
        BridgeAccessibilityService.getInstance()?.endVoiceControl(owner)
        startingId = null
        generation++
        pending.clear()
        worker.queue.clear()
        server.cancel()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.mode == AudioManager.MODE_IN_COMMUNICATION) audio.mode = previousAudioMode
        PpomiTelecom.callEnded()
    }

    private fun clearHost() {
        val view = webView
        if (view == null && !active && startingId == null) return
        val owner = controlId
        active = false
        mode = "voice"
        serviceOwner = null
        controlId = null
        BridgeAccessibilityService.getInstance()?.endVoiceControl(owner)
        startingId = null
        generation++
        pending.clear()
        worker.queue.clear()
        server.cancel()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.mode == AudioManager.MODE_IN_COMMUNICATION) audio.mode = previousAudioMode
        PpomiTelecom.callEnded()
        webView = null
        if (view != null) {
            if (VoiceBridgePolicy.trustedEntry(view.url))
                runCatching { view.evaluateJavascript("window.ppomiVoiceStop?.();", null) }
            main.postDelayed({
                (view.parent as? ViewGroup)?.removeView(view)
                WebViewCompat.removeWebMessageListener(view, "ppomiAgentNative")
                view.stopLoading(); view.clearHistory(); view.clearCache(true); view.destroy()
                viewGeneration++
            }, 100)
        }
    }

    private fun executeTool(name: String, args: JSONObject, epoch: Int): Any {
        check(active && generation == epoch)
        if (name == "file_list") return workspace.list(args.optString("path", ""))
        if (name == "file_read") return workspace.read(args.getString("path"))
        if (name == "file_write") return workspace.write(args.getString("path"), args.getString("content"))
        if (name == "app_list") return BridgeAccessPolicy.appList(context, args.getString("query"))
        val bridge = BridgeAccessibilityService.getInstance()
        if (name == "device_status" && bridge == null)
            return TaskStore.`object`("connected", false, "accessibility", false, "sessionActive", active,
                "sessionMode", mode, "voiceActive", active && mode == "voice")
        if (bridge == null) throw VoiceToolErrors.Failure("accessibility_required")
        val owner = controlId ?: throw IllegalStateException()
        fun call(operation: String, arguments: JSONObject = JSONObject()): JSONObject {
            check(active && generation == epoch && controlId == owner)
            return bridge.executeLocal(operation, arguments, owner)
        }
        fun awaitForeground(target: String, opened: JSONObject): JSONObject {
            // Launching an activity only queues the transition. Keep the next screen read
            // behind a short stable foreground observation, including on Samsung devices.
            val deadline = SystemClock.elapsedRealtime() + 5000
            var stableSince = 0L
            while (true) {
                val now = SystemClock.elapsedRealtime()
                val visible = call("status").optString("foregroundPackage") == target
                if (visible) {
                    if (stableSince == 0L) stableSince = now
                    if (now - stableSince >= 300) break
                } else stableSince = 0L
                if (now >= deadline) throw VoiceToolErrors.Failure("no_active_screen")
                Thread.sleep(100)
            }
            return opened
        }
        return when (name) {
            "device_status" -> call("status").put("accessibility", true).put("sessionMode", mode).put("sessionActive", active)
            "screen_read" -> call("ui_tree")
            "app_open" -> {
                val target = BridgeAccessPolicy.resolveTarget(context, args.getString("target"))
                if (target == context.packageName) throw VoiceToolErrors.Failure("protected_action")
                awaitForeground(target, call("open_app", TaskStore.`object`("packageName", target)))
            }
            "store_search" -> awaitForeground("com.android.vending", call("store_search", args))
            "ui_tap" -> call("click", TaskStore.`object`("nodeId", args.getString("nodeId")))
            "ui_type" -> call("type_text", TaskStore.`object`("nodeId", args.getString("nodeId"), "text", args.getString("text")))
            "device_back" -> call("back")
            "device_home" -> call("home")
            "ui_scroll" -> {
                val direction = args.getString("direction")
                require(direction == "up" || direction == "down")
                val tree = call("ui_tree")
                val width = tree.getInt("displayWidth"); val height = tree.getInt("displayHeight")
                val start = if (direction == "down") .70 else .30
                val result = call("swipe", TaskStore.`object`("x1", width / 2, "x2", width / 2,
                    "y1", (height * start).toInt(), "y2", (height * (1 - start)).toInt(), "durationMs", 350))
                val gesture = result.getString("gestureId")
                val deadline = System.currentTimeMillis() + 8000
                while (true) {
                    if (!active || generation != epoch) {
                        runCatching { bridge.executeLocal("cancel_gesture", TaskStore.`object`("gestureId", gesture), owner) }
                        throw IllegalStateException()
                    }
                    val status = call("gesture_status", TaskStore.`object`("gestureId", gesture))
                    if (status.optString("state") == "completed") break
                    check(status.optString("state") == "pending" && System.currentTimeMillis() < deadline)
                    Thread.sleep(100)
                }
                TaskStore.`object`("dispatched", true, "screen", call("ui_tree"))
            }
            else -> throw IllegalArgumentException()
        }
    }

    private fun reply(id: String, result: Any, epoch: Int) = send(id, TaskStore.`object`("id", id, "result", result), epoch)
    private fun failure(id: String, code: String, epoch: Int) = send(id, TaskStore.`object`("id", id,
        "error", TaskStore.`object`("code", code, "message", "요청을 완료하지 못했습니다. 연결·권한·입력 범위를 확인해 주세요.")), epoch)
    private fun send(id: String, response: JSONObject, epoch: Int) {
        if (generation != epoch || !pending.remove(id)) return
        val view = webView ?: return
        if (VoiceBridgePolicy.trustedEntry(view.url))
            view.evaluateJavascript("window.ppomiAgentReceive?.(${response});", null)
    }
    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked",
        mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))

    companion object {
        @Volatile private var instance: VoiceSessionHost? = null
        val TOOLS = listOf("device_status", "screen_read", "app_list", "app_open", "store_search", "ui_tap", "ui_type", "ui_scroll",
            "device_back", "device_home", "file_list", "file_read", "file_write")
        fun get(context: Context): VoiceSessionHost = instance ?: synchronized(this) {
            instance ?: VoiceSessionHost(context.applicationContext).also { instance = it; PpomiTelecom.register(context.applicationContext) }
        }
        @JvmStatic fun hasActiveControl() = instance?.active == true
        @JvmStatic fun isControlOwner(owner: String?) = owner != null && instance?.let { it.active && it.controlId == owner } == true
    }
}

private const val NUDGE_MS = 60_000L
private const val CALL_MS = 180_000L
private const val RING_MS = 45_000L

/** 조용한 알림(벨 아님): "뽀미 · 용건". 누르면 대화(차례 띠)로 간다. 재촉은 같은 알림을 다시 울린다. */
internal object TurnNotifier {
    private const val CHANNEL = "turn"
    private const val ID = 43
    fun show(context: Context, reason: String, nudge: Boolean) {
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "사람 차례", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 13, Intent(context, MainActivity::class.java).putExtra("show_voice", true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(if (nudge) "뽀미 · 아직 기다려요" else "뽀미").setContentText(reason).setContentIntent(open).setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER).setVisibility(Notification.VISIBILITY_PRIVATE).build()
        runCatching { notifications.notify(ID, notification) }
    }
    fun cancel(context: Context) { context.getSystemService(NotificationManager::class.java).cancel(ID) }
}

/** 구두 결재의 판정: "승인" 또는 "취소/거절" 하나만 들어 있을 때 고른다. 둘 다면 되묻는 쪽이 안전하고, "네"만으로는 고르지 않는다. */
internal object VoiceApproval {
    fun choice(text: String): String? {
        val yes = "승인" in text; val no = "취소" in text || "거절" in text
        return if (yes == no) null else if (yes) "승인" else "취소"
    }
}
