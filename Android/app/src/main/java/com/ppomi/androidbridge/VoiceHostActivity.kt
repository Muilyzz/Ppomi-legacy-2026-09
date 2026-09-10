package com.ppomi.androidbridge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

/** 음성 세션이 시작될 수 있는 화면(대화·통화). 보이는 동안 세션 호스트에 붙고, 마이크·알림 권한을 묻는다. */
abstract class VoiceHostActivity : ComponentActivity() {
    private var voicePermissionsResult: ((Boolean) -> Unit)? = null
    private val voicePermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val callback = voicePermissionsResult
        voicePermissionsResult = null
        callback?.invoke(voicePermissions().all { permission ->
            ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        })
    }

    private fun voicePermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 33)
        arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
    else arrayOf(Manifest.permission.RECORD_AUDIO)

    internal fun requestVoicePermissions(result: (Boolean) -> Unit) {
        if (voicePermissionsResult != null) { result(false); return }
        val missing = voicePermissions().filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) result(true)
        else { voicePermissionsResult = result; voicePermissionLauncher.launch(missing.toTypedArray()) }
    }

    override fun onStart() {
        super.onStart()
        VoiceSessionHost.get(applicationContext).attach(this)
    }

    override fun onStop() {
        VoiceSessionHost.get(applicationContext).detach(this)
        super.onStop()
    }

    override fun onDestroy() {
        voicePermissionsResult?.invoke(false)
        voicePermissionsResult = null
        super.onDestroy()
    }
}
