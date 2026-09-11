package com.ppomi.androidbridge

import org.json.JSONObject

internal data class WorkbenchSnapshot(
    val tasks: List<TaskSnapshot> = emptyList(),
    val active: TaskSnapshot? = null,
    val connected: Boolean = false,
    val supported: Boolean = true,
    val settings: AgentSettingsSnapshot = AgentSettingsSnapshot(),
    val shared: SharedSnapshot = SharedSnapshot(),
    val controlWindow: ControlWindowSnapshot? = null,
    val chatControl: Boolean = false,
    val lastOpened: ControlAppSnapshot? = null,
    val popupStatus: String = ""
)
/** The target app's window in screen pixels; the workbench keeps its own content out of this rectangle. */
internal data class ControlWindowSnapshot(val packageName: String, val label: String, val bounds: android.graphics.Rect) {
    companion object {
        fun from(value: JSONObject?): ControlWindowSnapshot? = value?.let {
            ControlWindowSnapshot(it.optString("packageName"), it.optString("label"),
                android.graphics.Rect(it.optInt("left"), it.optInt("top"), it.optInt("right"), it.optInt("bottom")))
        }
    }
}
internal data class ControlAppSnapshot(val packageName: String, val label: String)
internal data class SharedSnapshot(
    val configured: Boolean = false, val online: Boolean = false, val busy: Boolean = false,
    val deviceId: String = "", val deviceName: String = "", val workspaceName: String = "",
    val lastUpdated: String = "", val error: String = "", val devices: List<String> = emptyList(),
    val runs: List<SharedRunSnapshot> = emptyList(), val documents: List<SharedDocumentSnapshot> = emptyList()
) {
    companion object {
        fun from(value: JSONObject): SharedSnapshot {
            val context = value.optJSONObject("context")
            val local = value.optJSONArray("localRuns")?.objects().orEmpty().associateBy { it.optString("id") }
            return SharedSnapshot(value.optBoolean("configured"), value.optBoolean("online"), value.optBoolean("busy"),
                value.optString("deviceId"), context?.optJSONObject("device")?.optString("label").orEmpty(),
                context?.optJSONObject("workspace")?.optString("name").orEmpty(), value.optString("lastUpdated"),
                listOf(value.optString("connectionError"), value.optString("error")).filter { it.isNotBlank() }.distinct().joinToString("\n"),
                context?.optJSONArray("devices")?.objects().orEmpty().map { it.optString("label") },
                value.optJSONArray("runs")?.objects().orEmpty().map { run ->
                    val localRun = local[run.optString("id")]
                    SharedRunSnapshot(run.optString("id"), run.optString("request"), run.optString("state"),
                        run.optLong("version"), run.optString("executor_device_id"), run.optString("summary"),
                        localRun != null, localRun?.optString("state").orEmpty(), localRun?.optInt("pending") ?: 0,
                        localRun?.optString("error").orEmpty())
                }, value.optJSONArray("documents")?.objects().orEmpty().map { doc ->
                    SharedDocumentSnapshot(doc.optString("id"), doc.optString("title"), doc.optString("kind"),
                        doc.optLong("version"), doc.optBoolean("archived"), doc.optJSONObject("body")?.toString(2).orEmpty())
                })
        }
    }
}
internal data class SharedRunSnapshot(val id: String, val request: String, val state: String, val version: Long,
    val executorId: String, val summary: String, val hasLocalRecord: Boolean, val localState: String,
    val pending: Int, val error: String)
internal data class SharedDocumentSnapshot(val id: String, val title: String, val kind: String, val version: Long,
    val archived: Boolean, val body: String)
internal data class AgentSettingsSnapshot(
    val endpoint: String = "", val model: String = "", val configured: Boolean = false, val hasApiKey: Boolean = false
) {
    companion object {
        fun from(value: JSONObject) = AgentSettingsSnapshot(value.optString("endpoint"), value.optString("model"),
            value.optBoolean("configured"), value.optBoolean("hasApiKey"))
    }
}
internal data class TaskEvent(val id: String, val time: String, val type: String, val message: String)
internal data class TaskSnapshot(
    val id: String, val request: String, val mode: String, val modeLabel: String,
    val state: String, val stepIndex: Int, val stepCount: Int,
    val createdAt: String, val summary: String,
    val approvalTitle: String, val approvalDescription: String,
    val events: List<TaskEvent>, val screenshotPath: String?
) {
    val inProgress get() = state == "running" || state == "waiting_approval"
    val statusLabel get() = when (state) {
        "running" -> "실행 중"
        "waiting_approval" -> "승인 대기"
        "completed" -> "완료"
        "cancelled" -> "중단됨"
        "interrupted" -> "실행 끊김"
        "failed" -> "실패"
        else -> state.ifEmpty { "준비" }
    }
    companion object {
        fun from(value: JSONObject): TaskSnapshot {
            val approval = value.optJSONObject("approval")
            val evidence = value.optJSONArray("evidence")?.objects().orEmpty()
            return TaskSnapshot(
                value.optString("id"), value.optString("request"), value.optString("mode", "builtin"),
                value.optString("modeLabel", "내장 절차 · AI 모델 미연결"), value.optString("state"),
                value.optInt("stepIndex"), value.optInt("stepCount"), value.optString("createdAt"), value.optString("summary"),
                approval?.optString("title").orEmpty(), approval?.optString("description").orEmpty(),
                value.optJSONArray("events")?.objects().orEmpty().map {
                    TaskEvent(it.optString("id"), it.optString("time"), it.optString("type"), it.optString("message"))
                },
                value.optString("screenshotPath").takeUnless { it.isBlank() || it == "null" }
                    ?: evidence.lastOrNull { it.optString("kind").contains("screenshot") }?.optString("path")
            )
        }
    }
}
