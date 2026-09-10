package com.ppomi.androidbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * 뽀미의 통화를 OS 전화로 등록한다(self-managed). 벨·잠금 화면·받기/거절·오디오 경로·다른 전화와의 충돌은 OS가 맡고,
 * 소리 자체는 지금의 WebRTC 세션이 그대로 낸다. 트리거는 사람 차례(로컬)뿐이고 푸시는 아직 없다(docs/ui-tree.md).
 * 화면은 CallActivity(전화 모드) 하나가 `call` 상태를 보고 그린다.
 */
internal object PpomiTelecom {
    const val EXTRA_REASON = "reason"
    private const val ACCOUNT = "ppomi"
    @Volatile var connection: PpomiConnection? = null
        private set
    /** 통화 화면이 보는 상태. null = 통화 없음. 울리는 중 → 받으면 startedAt 부터 통화 중. */
    data class CallUi(val reason: String, val ringing: Boolean, val speaker: Boolean = false, val startedAt: Long = 0,
                      val connected: Boolean = false)   // connected = 세션이 살아 소리가 오간다(그 전엔 "연결 중")
    var call by mutableStateOf<CallUi?>(null)
        private set

    private fun handle(context: Context) = PhoneAccountHandle(ComponentName(context, PpomiConnectionService::class.java), ACCOUNT)
    private fun telecom(context: Context) = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

    fun register(context: Context) {
        runCatching {
            telecom(context).registerPhoneAccount(PhoneAccount.builder(handle(context), "뽀미")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED).build())
        }
    }

    /** 사람 차례가 왔다: OS에 걸려온 통화로 올린다. 이미 통화 중이거나 울리는 중이면 그대로 둔다. */
    fun ring(context: Context, reason: String): Boolean {
        if (connection != null) return false
        register(context)
        val handle = handle(context)
        if (!telecom(context).isIncomingCallPermitted(handle)) return false
        // This bundle arrives as-is in onCreateIncomingConnection's request.extras (Telecom wraps it itself).
        return runCatching { telecom(context).addNewIncomingCall(handle, Bundle().apply { putString(EXTRA_REASON, reason) }) }.isSuccess
    }

    /** 세션이 열렸다: 받은 통화면 활성으로, 아니면 나가는 통화로 OS에 등록한다. */
    fun callStarted(context: Context) {
        connection?.let {
            if (it.state == Connection.STATE_RINGING) it.activate()
            update { ui -> ui.copy(connected = true, startedAt = SystemClock.elapsedRealtime()) }
            return
        }
        register(context)
        val handle = handle(context)
        if (!telecom(context).isOutgoingCallPermitted(handle)) return
        val extras = Bundle().apply { putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle) }
        runCatching { telecom(context).placeCall(Uri.fromParts("ppomi", "call", null), extras) }
    }

    fun callEnded(cause: Int = DisconnectCause.LOCAL) {
        val current = connection ?: return
        connection = null
        call = null
        IncomingCallNotifier.cancel(current.context)
        current.setDisconnected(DisconnectCause(cause))
        current.destroy()
    }

    internal fun attach(current: PpomiConnection) {
        connection = current
        call = CallUi(current.reason, ringing = current.state == Connection.STATE_RINGING)
    }
    internal fun update(change: (CallUi) -> CallUi) { call = call?.let(change) }
}

class PpomiConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val reason = request?.extras?.getString(PpomiTelecom.EXTRA_REASON).orEmpty()
        return PpomiConnection(applicationContext, reason).also { it.setRinging(); PpomiTelecom.attach(it) }
    }
    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest?): Connection {
        val connection = PpomiConnection(applicationContext, "")
        // placeCall is asynchronous: if the session already ended, do not leave an orphan call in Telecom.
        if (!VoiceSessionHost.get(applicationContext).active) {
            connection.setDisconnected(DisconnectCause(DisconnectCause.CANCELED)); connection.destroy(); return connection
        }
        PpomiTelecom.attach(connection); connection.activate()
        PpomiTelecom.update { it.copy(connected = true) }   // the session was already live when placeCall ran
        return connection
    }
}

internal class PpomiConnection(val context: Context, val reason: String) : Connection() {
    init {
        connectionProperties = PROPERTY_SELF_MANAGED
        audioModeIsVoip = true
        setCallerDisplayName("뽀미", TelecomManager.PRESENTATION_ALLOWED)
        setAddress(Uri.fromParts("ppomi", "call", null), TelecomManager.PRESENTATION_ALLOWED)
    }
    /** self-managed: 수신 화면은 앱이 그린다. 잠금 화면 위 전체 화면 알림(벨소리 채널) → CallActivity 받기/거절. */
    override fun onShowIncomingCallUi() { IncomingCallNotifier.show(context, reason) }
    override fun onAnswer() = answer()
    override fun onAnswer(videoState: Int) = answer()
    fun answer() {
        activate()
        IncomingCallNotifier.cancel(context)
        VoiceSessionHost.get(context).answerIncoming(reason)
    }
    /** 통화가 살아났다(받았거나 걸었다): OS에 활성으로 알리고 전화 모드 화면을 연다. */
    fun activate() {
        setActive()
        PpomiTelecom.update { it.copy(ringing = false, startedAt = SystemClock.elapsedRealtime()) }
        context.startActivity(Intent(context, CallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    /** 수화기 ↔ 스피커. 경로는 OS가 바꾸고, 결과는 onCallAudioStateChanged 로 돌아온다. */
    @Suppress("DEPRECATION")
    fun setSpeaker(on: Boolean) = setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_WIRED_OR_EARPIECE)
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onCallAudioStateChanged(state: CallAudioState) {
        PpomiTelecom.update { it.copy(speaker = state.route == CallAudioState.ROUTE_SPEAKER) }
    }
    override fun onReject() = reject()
    override fun onReject(rejectReason: Int) = reject()
    fun reject() {
        VoiceSessionHost.get(context).incomingDismissed()
        PpomiTelecom.callEnded(DisconnectCause.REJECTED)
    }
    /** OS 통화 UI나 다른 전화가 끊었다: 세션도 끝난다. */
    override fun onDisconnect() {
        PpomiTelecom.callEnded(DisconnectCause.LOCAL)
        VoiceSessionHost.get(context).stopVoice()
    }
    override fun onAbort() { PpomiTelecom.callEnded(DisconnectCause.CANCELED) }
    /** Another real call took over: ours ends rather than waiting on hold. */
    override fun onHold() { PpomiTelecom.callEnded(DisconnectCause.LOCAL); VoiceSessionHost.get(context).stopVoice() }
}

internal object IncomingCallNotifier {
    private const val CHANNEL = "incoming_call"
    private const val ID = 42
    const val ANSWER = "com.ppomi.androidbridge.CALL_ANSWER"
    const val DECLINE = "com.ppomi.androidbridge.CALL_DECLINE"

    fun show(context: Context, reason: String) {
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "걸려온 통화", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val answer = PendingIntent.getBroadcast(context, 10, Intent(context, CallActionReceiver::class.java).setAction(ANSWER), flags)
        val decline = PendingIntent.getBroadcast(context, 11, Intent(context, CallActionReceiver::class.java).setAction(DECLINE), flags)
        val screen = PendingIntent.getActivity(context, 12, Intent(context, CallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), flags)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentTitle("뽀미가 부릅니다").setContentText(reason)
            .setCategory(Notification.CATEGORY_CALL).setOngoing(true).setFullScreenIntent(screen, true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setStyle(Notification.CallStyle.forIncomingCall(Person.Builder().setName("뽀미").setImportant(true).build(), decline, answer))
        } else {
            builder.addAction(Notification.Action.Builder(null, "거절", decline).build())
                .addAction(Notification.Action.Builder(null, "받기", answer).build())
        }
        runCatching { notifications.notify(ID, builder.build()) }
    }
    fun cancel(context: Context) { context.getSystemService(NotificationManager::class.java).cancel(ID) }
}

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            IncomingCallNotifier.ANSWER -> PpomiTelecom.connection?.answer()
            IncomingCallNotifier.DECLINE -> PpomiTelecom.connection?.reject()
        }
    }
}
