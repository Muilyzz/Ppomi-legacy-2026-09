package com.ppomi.androidbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Debug only (DUMP-gated in the debug manifest). DEBUG_RING rings now; DEBUG_TURN walks the 톡 → 재촉 → 전화 ladder
 *  (--es id X --es reason '…'; no id = resolved). */
class DebugRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!BuildConfig.DEBUG) return
        val host = VoiceSessionHost.get(context.applicationContext)
        when (intent.action) {
            "com.ppomi.androidbridge.DEBUG_TURN" -> host.turn(intent.getStringExtra("id"), intent.getStringExtra("reason").orEmpty())
            "com.ppomi.androidbridge.DEBUG_HEARD" -> host.heard(intent.getStringExtra("text").orEmpty())
            else -> host.ring(intent.getStringExtra("reason").orEmpty())
        }
    }
}
