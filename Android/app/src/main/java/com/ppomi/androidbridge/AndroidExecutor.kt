package com.ppomi.androidbridge

import android.app.Activity
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Trusted native UI owner. Both the standalone activity and Tauri implement this permission/lifecycle boundary. */
interface ForegroundHost {
    val executorActivity: Activity
    fun requestVoicePermissions(result: (Boolean) -> Unit)
}

/** Application-owned native executor; neither a WebView nor a server is required for its dispatcher. */
class AndroidExecutor private constructor(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue(32),
        { task -> Thread(task, "ppomi-voice-tools") }, ThreadPoolExecutor.AbortPolicy())
    private val server = VoiceServerClient(context)
    private val workspace = AgentWorkspace(context)
    private val preferences = context.getSharedPreferences("voice_settings", Context.MODE_PRIVATE)
    private val ownership = ExecutorOwnership<ForegroundHost>()
    private val pending = mutableMapOf<String, (JSONObject) -> Unit>()
    private val listeners = mutableMapOf<Any, (JSONObject) -> Unit>()
    private var startingId: String? = null
    private var startingHost = WeakReference<ForegroundHost>(null)
    private var serviceOwner: VoiceForegroundService? = null
    private var previousAudioMode = AudioManager.MODE_NORMAL
    @Volatile private var controlId: String? = null
    @Volatile var active = false
        private set
    @Volatile var mode = "voice"
        private set
    @Volatile private var generation = 0
    fun attach(host: ForegroundHost) {
        if (!ownership.owns(host) && startingId != null) stopVoice()
        ownership.attach(host)
    }
    fun detach(host: ForegroundHost) {
        if (!ownership.detach(host)) return
        if (!active && startingId != null) stopVoice()
    }
    private fun foregroundActivity(): ForegroundHost? = ownership.foreground()?.takeIf {
        val current = it.executorActivity
        !current.isFinishing && !current.isDestroyed &&
            (current as? androidx.lifecycle.LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true
    }
    fun addEventListener(owner: Any, listener: (JSONObject) -> Unit) { listeners[owner] = listener }
    fun removeEventListener(owner: Any) { listeners.remove(owner) }
    private fun emit(event: String, payload: Any = JSONObject.NULL) {
        val notification = TaskStore.`object`("event", event, "payload", payload)
        listeners.values.toList().forEach { listener -> runCatching { listener(notification) } }
    }
    /** Product constant; only the debug DUMP-gated provisioning activity can set an override. */
    val agentEndpoint: String
        get() = if (BuildConfig.DEBUG) {
            preferences.getString("endpoint_override", null)?.let {
                runCatching { VoiceBridgePolicy.endpoint(it) }.getOrNull()
            } ?: VoiceBridgePolicy.DEFAULT_AGENT_ENDPOINT
        } else VoiceBridgePolicy.DEFAULT_AGENT_ENDPOINT

    /**
     * 비서의 단계(docs/ui-tree.md): 사람 차례가 오면 0 톡(페이지 말풍선 + 조용한 알림) → 1분 뒤 재촉(알림 다시) →
     * 3분째 답이 없으면 전화(ring). 차례가 풀리면(null) 모두 취소하고 벨도 내린다. 같은 차례는 다시 시작하지 않는다.
     */
    private var turnId: String? = null
    private var turnReason = ""
    private var turnApprovalVisible = false
    private val nudge = Runnable { turnId?.takeIf { !turnApprovalVisible }?.let { TurnNotifier.show(context, it, turnReason, nudge = true) } }
    private val escalate = Runnable { if (turnId != null && !turnApprovalVisible) ring(turnReason) }
    @JvmOverloads
    fun turn(id: String?, reason: String, approvalVisible: Boolean = false) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { turn(id, reason, approvalVisible) }; return }
        val newTurn = id != turnId
        val visibilityChanged = approvalVisible != turnApprovalVisible
        turnReason = if (id == null) "" else reason
        if (!newTurn && !visibilityChanged) return
        main.removeCallbacks(nudge); main.removeCallbacks(escalate)
        turnId = id
        turnApprovalVisible = approvalVisible
        TurnNotifier.cancel(context)
        ring("") // Only an unanswered ring is cancelled; an active voice call keeps running.
        if (id == null) return
        if (newTurn) emit("notice", reason)
        // Keep turnId available to speech approval while its native buttons are visible.
        if (approvalVisible) return
        if (newTurn) TurnNotifier.show(context, id, reason, nudge = false)
        // Schedule once when a pending turn is first hidden, including returning to the background.
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
        emit("incomingCall", reason)
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
        val id = LocalTaskRunner.get(context).activeTask()?.takeIf { it.optString("state") == "waiting_approval" }?.optString("id") ?: return
        if (context.getSystemService(KeyguardManager::class.java).isDeviceLocked) return
        val choice = VoiceApproval.choice(text) ?: return
        val runner = LocalTaskRunner.get(context)
        runCatching { if (choice == "승인") runner.approve(id) else runner.cancel(id) }.onSuccess { note("말로 $choice · $turnReason") }
    }
    /** 결재 기록 한 줄을 대화에 남긴다("승인 · 용건"). 버튼이든 말이든. */
    fun note(text: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { note(text) }; return }
        emit("notice", text)
    }
    /** The page's 나중에: same as declining on the OS call screen. */
    fun declineIncoming() { main.post { PpomiTelecom.connection?.takeIf { it.state == android.telecom.Connection.STATE_RINGING }?.reject() } }

    /** Deliver the answered-call reason to the shell, retaining it for a cold-start bootstrap. */
    @Volatile private var pendingAnswer: String? = null
    fun answerIncoming(reason: String) {
        main.post {
            pendingAnswer = reason
            emit("answerCall", reason)
            // Cold starts and the lock-screen call view return to the installed shell.
            context.startActivity(ExecutorNavigation.conversation(context))
        }
    }
    /** The OS call UI declined: the page drops its banner too. */
    fun incomingDismissed() { main.post { emit("incomingCall", "") } }

    /** Only trusted UI adapters may call this entry; tools never dispatch UI management methods. */
    fun receive(raw: String, callback: (JSONObject) -> Unit) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { receive(raw, callback) }; return }
        val request = if (raw.length <= 180_000) runCatching { JSONObject(raw) }.getOrNull() else null
        val id = request?.optString("id").orEmpty()
        if (request == null || runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false).not()) {
            callback(errorResponse(id, "invalid_request")); return
        }
        if (pending.size >= 32 || pending.containsKey(id)) {
            callback(errorResponse(id, "request_in_progress")); return
        }
        pending[id] = callback
        val epoch = generation
        val method = request.optString("method")
        val args = request.optJSONObject("args") ?: JSONObject()
        try {
            when (method) {
                "executorStatus" -> reply(id, status(), epoch)
                "answerApproval" -> { requireUser(); reply(id, answerApproval(args), epoch) }
                "openSettings", "openRecords", "openControlApps" -> {
                    val host = requireUser()
                    check(!active && startingId == null && LocalTaskRunner.actionOwner() == null)
                    host.executorActivity.startActivity(Intent(context, MainActivity::class.java)
                        .putExtra("executor_settings", true)
                        .putExtra("executor_section", if (method == "openRecords") 1 else 2)
                        .putExtra("executor_control_apps", method == "openControlApps"))
                    reply(id, TaskStore.`object`("opened", true), epoch)
                }
                "accountingReport" -> {
                    requireUser()
                    val archive = args.getJSONObject("archive").toString()
                    worker.execute {
                        try { val report = JSONObject(SharedAccounting.report(archive)); main.post { reply(id, report, epoch) } }
                        catch (_: Exception) { main.post { failure(id, "accounting_failed", epoch) } }
                        catch (_: LinkageError) { main.post { failure(id, "accounting_unavailable", epoch) } }
                    }
                }
                "bootstrap" -> reply(id, TaskStore.`object`("platform", "android", "deviceLabel", "뽀미 Android",
                    "answerCall", (pendingAnswer ?: JSONObject.NULL).also { pendingAnswer = null },
                    "uiScale", context.resources.configuration.fontScale.toDouble(), "dark", context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES,
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
        startingHost = WeakReference(foreground)
        val start: (Boolean) -> Unit = start@ { granted ->
            if (generation != epoch || startingId != id) return@start
            if (!granted || startingHost.get() !== foreground || foregroundActivity() !== foreground) {
                startingId = null
                startingHost.clear()
                failure(id, if (requestedMode == "voice") "microphone_or_notification_permission_required" else "session_start_failed", epoch)
            } else {
                try {
                    ContextCompat.startForegroundService(context, Intent(context, VoiceForegroundService::class.java)
                        .setAction(VoiceForegroundService.START))
                } catch (_: Exception) { startingId = null; startingHost.clear(); failure(id, "session_start_failed", epoch) }
            }
        }
        if (requestedMode == "voice") foreground.requestVoicePermissions(start)
        else start(true)
    }

    /** Called after the service enters the foreground type appropriate for this session. */
    fun serviceStarted(service: VoiceForegroundService): Boolean {
        val id = startingId ?: return false
        if (foregroundActivity() == null || foregroundActivity() !== startingHost.get() || LocalTaskRunner.actionOwner() != null) {
            startingId = null; startingHost.clear(); failure(id, "voice_start_failed", generation); return false
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
        startingHost.clear()
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
        emit("voiceStop")
        context.stopService(Intent(context, VoiceForegroundService::class.java))
    }

    /** Late teardown from a replaced activity must not stop its successor's requests or session. */
    fun shutdownIfOwnedBy(host: ForegroundHost): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (!ownership.owns(host)) return false
        stopVoice()
        cancelPending()
        return true
    }

    private fun cancelPending() {
        generation++
        val abandoned = pending.toMap()
        pending.clear()
        worker.queue.clear()
        server.cancel()
        abandoned.forEach { (id, callback) -> runCatching { callback(errorResponse(id, "session_ended")) } }
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
        startingHost.clear()
        cancelPending()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.mode == AudioManager.MODE_IN_COMMUNICATION) audio.mode = previousAudioMode
        PpomiTelecom.callEnded()
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
    private fun errorResponse(id: String, code: String) = TaskStore.`object`("id", id,
        "error", TaskStore.`object`("code", code, "message", "요청을 완료하지 못했습니다. 연결·권한·입력 범위를 확인해 주세요."))
    private fun failure(id: String, code: String, epoch: Int) = send(id, errorResponse(id, code), epoch)
    private fun send(id: String, response: JSONObject, epoch: Int) {
        if (generation != epoch) return
        pending.remove(id)?.invoke(response)
    }
    private fun requireUser(): ForegroundHost {
        check(!context.getSystemService(KeyguardManager::class.java).isDeviceLocked)
        return foregroundActivity() ?: throw IllegalStateException()
    }
    private fun approval(task: JSONObject?): JSONObject? {
        if (task == null || task.optString("state") != "waiting_approval") return null
        val events = task.optJSONArray("events") ?: return null
        val eventId = events.optJSONObject(events.length() - 1)?.optString("id") ?: return null
        val details = task.optJSONObject("approval") ?: return null
        return TaskStore.`object`("id", eventId, "text", details.optString("title", task.optString("summary")),
            "options", JSONArray(listOf("승인", "취소")))
    }
    fun status(): JSONObject {
        val current = LocalTaskRunner.get(context).activeTask()
        val requested = approval(current)
        turn(current?.optString("id")?.takeIf { requested != null }, requested?.optString("text").orEmpty(), turnApprovalVisible)
        return TaskStore.`object`("platform", "android", "active", active, "mode", mode,
            "approval", requested ?: JSONObject.NULL, "accessibility", BridgeAccessibilityService.getInstance() != null,
            "capabilities", TaskStore.`object`("deviceControl", BridgeSession.supported(), "voice", true,
                "accounting", true, "settings", true, "records", true, "controlApps", true))
    }
    private fun answerApproval(args: JSONObject): JSONObject {
        val runner = LocalTaskRunner.get(context)
        synchronized(runner) {
            val task = runner.activeTask() ?: throw IllegalStateException()
            val requested = approval(task) ?: throw IllegalStateException()
            check(args.getString("id") == requested.getString("id"))
            val choice = args.getString("choice")
            require(choice == "승인" || choice == "취소")
            if (choice == "승인") runner.approve(task.getString("id")) else runner.cancel(task.getString("id"))
            note("$choice · ${requested.getString("text")}")
            turn(null, "")
            return TaskStore.`object`("accepted", true)
        }
    }
    companion object {
        @Volatile private var instance: AndroidExecutor? = null
        val TOOLS = listOf("device_status", "screen_read", "app_list", "app_open", "store_search", "ui_tap", "ui_type", "ui_scroll",
            "device_back", "device_home", "file_list", "file_read", "file_write")
        fun get(context: Context): AndroidExecutor = instance ?: synchronized(this) {
            instance ?: AndroidExecutor(context.applicationContext).also {
                instance = it; BridgeSession.configure(context.applicationContext, null); PpomiTelecom.register(context.applicationContext)
            }
        }
        @JvmStatic fun hasActiveControl() = instance?.active == true
        @JvmStatic fun isControlOwner(owner: String?) = owner != null && instance?.let { it.active && it.controlId == owner } == true
    }
}

private const val NUDGE_MS = 60_000L
private const val CALL_MS = 180_000L
private const val RING_MS = 45_000L

/** 조용한 알림(벨 아님): 누르면 해당 작업 기록과 승인 띠를 연다. */
internal object TurnNotifier {
    private const val CHANNEL = "turn"
    private const val ID = 43
    fun show(context: Context, taskId: String, reason: String, nudge: Boolean) {
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "사람 차례", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 13, Intent(context, MainActivity::class.java).putExtra("task_id", taskId)
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
