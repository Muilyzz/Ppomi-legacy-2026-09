package com.ppomi.androidbridge

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Debug-only, OS-permission-gated setup. MainActivity ignores all setup extras. */
class DebugProvisioningActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        var accepted = false
        try {
            val host = AndroidExecutor.get(applicationContext)
            check(BuildConfig.DEBUG && !host.active && !host.hasPendingStart() && LocalTaskRunner.actionOwner() == null)
            val token = intent.getStringExtra("bridge_token")
            val shared = intent.getStringExtra("ssot_config")
            val rawEndpoint = intent.getStringExtra("configure_agent_endpoint")
            // Every existing setup command changes one credential store. Refuse
            // mixed requests so a later validation error cannot leave a partial import.
            require(listOf(token, shared, rawEndpoint).count { it != null } == 1)
            if (token != null) require(BridgePolicy.validToken(token))
            if (shared != null) SupabaseSettings.validate(shared)
            val endpoint = rawEndpoint?.let { VoiceBridgePolicy.endpoint(it) }
            when {
                token != null -> BridgeSession.configure(applicationContext, token)
                shared != null -> SharedTaskController.get(applicationContext).configure(shared)
                endpoint != null -> check(getSharedPreferences("voice_settings", MODE_PRIVATE)
                    .edit().putString("endpoint_override", endpoint).commit())
            }
            accepted = true
            setResult(RESULT_OK)
        } catch (_: Exception) {
            // Intent values, credentials, and platform error details are never logged.
            setResult(RESULT_CANCELED)
        } finally {
            intent.removeExtra("bridge_token")
            intent.removeExtra("ssot_config")
            intent.removeExtra("configure_agent_endpoint")
            if (accepted) startActivity(ExecutorNavigation.conversation(this)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            finish()
        }
    }
}
