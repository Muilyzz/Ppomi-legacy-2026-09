package com.ppomi.androidbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Retains a user-started text or voice session across app switches; never auto-restarts. */
class VoiceForegroundService : Service() {
    private lateinit var host: AndroidExecutor
    override fun onCreate() {
        super.onCreate()
        host = AndroidExecutor.get(this)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "진행 중인 음성 대화", NotificationManager.IMPORTANCE_LOW))
        notifications.createNotificationChannel(NotificationChannel(TEXT_CHANNEL, "진행 중인 텍스트 대화", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != START || !host.hasPendingStart()) { host.stopVoice(); stopSelf(); return START_NOT_STICKY }
        val voice = host.mode == "voice"
        // A voice session is an OS call: the notification returns to the call screen, text sessions to the conversation.
        val open = PendingIntent.getActivity(this, 1, if (voice) Intent(this, CallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            else ExecutorNavigation.conversation(this).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 2, Intent(this, VoiceForegroundService::class.java)
            .setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, if (voice) CHANNEL else TEXT_CHANNEL)
            .setSmallIcon(if (voice) android.R.drawable.ic_btn_speak_now else android.R.drawable.ic_dialog_info)
            .setContentTitle(if (voice) "뽀미 통화 중" else "뽀미 텍스트 대화 중")
            .setContentText(if (voice) "누르면 통화 화면" else "요청한 앱 작업을 이어갑니다. 누르면 대화로 돌아갑니다.")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, if (voice) "끊기" else "대화 종료", stop).build()).build()
        try {
            val type = if (voice) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                else if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, type)
            else startForeground(NOTIFICATION_ID, notification)
            if (!host.serviceStarted(this)) { host.stopVoice(); stopSelf() }
        } catch (_: Exception) { host.stopVoice(); stopSelf() }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { host.serviceDestroyed(this); stopSelf(); super.onTaskRemoved(rootIntent) }
    override fun onDestroy() {
        host.serviceDestroyed(this)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object {
        const val START = "com.ppomi.androidbridge.VOICE_START"
        const val STOP = "com.ppomi.androidbridge.VOICE_STOP"
        private const val CHANNEL = "ppomi_active_voice"
        private const val TEXT_CHANNEL = "ppomi_active_text"
        private const val NOTIFICATION_ID = 7103
    }
}
