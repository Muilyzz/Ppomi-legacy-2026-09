package com.ppomi.androidbridge

import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import kotlinx.coroutines.delay

/**
 * 전화 모드(카카오톡 보이스톡처럼). 잠금 화면 위에서 울리고(거절·받기), 받으면 잠금을 풀지 않고 그대로 통화 화면이 된다
 * (스피커 · 대화 보기 · 끊기). 귀에 대면 근접 센서로 화면을 꺼서 뺨이 누르지 않는다. 걸 때도 같은 화면이 열린다.
 * 상태는 PpomiTelecom.call 하나. 승인·선택은 여기 없다: 대화 보기(잠금 해제)로 간다.
 */
class CallActivity : VoiceHostActivity() {
    private val proximity by lazy {
        (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "ppomi:call").apply { setReferenceCounted(false) }
    }
    private var near = false   // 통화 중이고 수화기로 듣는 중: 귀에 댈 수 있는 상태

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true); setTurnScreenOn(true)
        setContent { PpomiTheme {
            val call = PpomiTelecom.call
            if (call == null) { LaunchedEffect(Unit) { finish() }; return@PpomiTheme }
            SideEffect { near = !call.ringing && !call.speaker; updateProximity() }
            val connection = PpomiTelecom.connection
            if (call.ringing) IncomingScreen(call.reason, onAnswer = { connection?.answer() }, onDecline = { connection?.reject() })
            else CallScreen(call, onSpeaker = { connection?.setSpeaker(!call.speaker) }, onOpen = ::openConversation,
                onEnd = { VoiceSessionHost.get(applicationContext).stopVoice() })
        } }
    }

    override fun onResume() {
        super.onResume()
        if (PpomiTelecom.call == null) finish()   // answered or declined elsewhere
        updateProximity()
    }
    override fun onPause() { updateProximity(); super.onPause() }

    /** 화면이 앞에 있고 귀에 댈 수 있을 때만 근접 센서를 켠다(스피커·벨 울림·다른 화면에선 끄지 않는다). */
    private fun updateProximity() {
        if (near && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) proximity.acquire() else proximity.release()
    }

    /** 대화(승인·선택)는 잠금을 푼 뒤에만 연다. */
    private fun openConversation() {
        val open = {
            startActivity(Intent(this, MainActivity::class.java).putExtra("show_voice", true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard.isKeyguardLocked) keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() { open() }
        }) else open()
    }
}

@Composable
private fun IncomingScreen(reason: String, onAnswer: () -> Unit, onDecline: () -> Unit) {
    Column(Modifier.fillMaxSize().background(palette.bg).padding(32.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("뽀미가 부릅니다", color = palette.fg, fontSize = 24.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(12.dp))
        Text(reason, color = palette.fg2, fontSize = 16.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(48.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            OutlinedButton(onClick = onDecline) { Text("거절") }
            Button(onClick = onAnswer, colors = accentButton) { Text("받기") }
        }
    }
}

@Composable
private fun CallScreen(call: PpomiTelecom.CallUi, onSpeaker: () -> Unit, onOpen: () -> Unit, onEnd: () -> Unit) {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(call.startedAt) { while (true) { delay(1000); now = SystemClock.elapsedRealtime() } }
    val seconds = ((now - call.startedAt) / 1000).coerceAtLeast(0)
    Column(Modifier.fillMaxSize().background(palette.bg).padding(32.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("뽀미", color = palette.fg, fontSize = 24.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(12.dp))
        Text(if (call.connected) "통화 중 · %d:%02d".format(seconds / 60, seconds % 60) else "연결 중", color = palette.fg2, fontSize = 16.sp)
        if (call.reason.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            Text(call.reason, color = palette.fg2, fontSize = 16.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(48.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            if (call.speaker) Button(onClick = onSpeaker, colors = accentButton) { Text("스피커") }
            else OutlinedButton(onClick = onSpeaker) { Text("스피커") }
            OutlinedButton(onClick = onOpen) { Text("대화 보기") }
            Button(onClick = onEnd, colors = ButtonDefaults.buttonColors(containerColor = palette.bad, contentColor = palette.bg)) { Text("끊기") }
        }
    }
}
