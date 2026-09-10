package com.ppomi.androidbridge;

import org.json.JSONArray;
import org.json.JSONObject;

/** Status outbox is part of the same AtomicFile as the local execution event. */
final class SharedRunJournal {
    static void append(JSONObject task, JSONObject event) {
        JSONObject shared = task.optJSONObject("shared");
        if (shared == null || !"active".equals(shared.optString("phase"))) return;
        String kind = event.optString("type"), state, summary;
        boolean userAction = false;
        switch (kind) {
            case "started": state = "running"; summary = "Android에서 내장 테스트 절차를 시작했습니다."; break;
            case "approval_requested": state = "waiting_approval"; summary = "Android 화면에서 사용자의 승인을 기다립니다."; break;
            case "approved": state = "running"; kind = "approval"; userAction = true; summary = "사용자가 Android 화면에서 동작을 승인했습니다."; break;
            case "completed": state = "completed"; summary = "테스트 앱의 입력 결과를 확인했습니다. 화면 증빙은 실행 기기에 보관합니다."; break;
            case "failed": state = "failed"; summary = "Android 작업이 실패했습니다. 자세한 실행 기록은 기기에서 확인해 주세요."; break;
            case "cancelled": state = "cancelled"; userAction = true; summary = "사용자가 Android 작업을 중단했습니다."; break;
            case "interrupted": state = "interrupted"; summary = "Android 실행 연결이 끊겼습니다. 자동으로 동작을 반복하지 않습니다."; break;
            case "resumed": state = task.optString("state"); kind = "resume"; userAction = true; summary = "사용자가 Android 작업을 재개했습니다."; break;
            default: return;
        }
        JSONArray outbox = shared.optJSONArray("outbox");
        if (outbox == null) { outbox = new JSONArray(); TaskStore.put(shared, "outbox", outbox); }
        long expected = shared.optLong("nextVersion");
        JSONObject data = TaskStore.object("local_task_id", task.optString("id"));
        if (userAction) TaskStore.put(data, "user_action", true);
        outbox.put(TaskStore.object("p_run_id", task.optString("id"), "p_event_id", event.optString("id"),
            "p_expected_version", expected, "p_state", state, "p_kind", kind, "p_summary", summary, "p_data", data));
        TaskStore.put(shared, "nextVersion", expected + 1);
    }
}
