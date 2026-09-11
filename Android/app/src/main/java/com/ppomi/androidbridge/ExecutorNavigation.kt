package com.ppomi.androidbridge

import android.content.Context
import android.content.Intent

/** Return to this APK's installed shell; legacy standalone and Tauri use different launcher classes. */
object ExecutorNavigation {
    @JvmStatic fun conversation(context: Context): Intent =
        (context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java))
            .putExtra("show_voice", true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
}
