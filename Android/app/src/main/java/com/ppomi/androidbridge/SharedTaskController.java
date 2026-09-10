package com.ppomi.androidbridge;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Server owns shared state; this device keeps an execution journal and a durable status outbox. */
public final class SharedTaskController {
    private static SharedTaskController instance;
    private final SupabaseSettings settings;
    private final SupabaseClient client;
    private final LocalTaskRunner runner;
    private final AtomicFile cache;
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor(r -> new Thread(r, "ppomi-shared-tasks"));
    private JSONObject state = TaskStore.object("configured", false, "online", false, "busy", false, "runs", new JSONArray());
    private SharedTaskController(Context context) {
        settings = new SupabaseSettings(context); client = new SupabaseClient(settings); runner = LocalTaskRunner.get(context);
        cache = new AtomicFile(new File(context.getFilesDir(), "shared-server-cache.json"));
        if (cache.getBaseFile().isFile()) try { state = new JSONObject(new String(cache.readFully(), StandardCharsets.UTF_8)); } catch (Exception ignored) { }
        TaskStore.put(state, "configured", settings.configured()); TaskStore.put(state, "online", false); TaskStore.put(state, "busy", false);
        worker.scheduleWithFixedDelay(this::refreshNow, 1, 5, TimeUnit.SECONDS);
    }
    public static synchronized SharedTaskController get(Context context) {
        if (instance == null) instance = new SharedTaskController(context.getApplicationContext());
        return instance;
    }
    public synchronized JSONObject snapshot() {
        JSONObject copy = TaskStore.copy(state); JSONArray summaries = new JSONArray();
        JSONArray tasks = runner.store().list();
        for (int i = 0; i < tasks.length(); i++) {
            JSONObject task = tasks.optJSONObject(i), shared = task.optJSONObject("shared");
            if (shared == null || !shared.optString("executorDeviceId").equals(state.optString("deviceId"))) continue;
            JSONArray outbox = shared.optJSONArray("outbox");
            summaries.put(TaskStore.object("id", task.optString("id"), "state", task.optString("state"),
                "pending", outbox == null ? 0 : outbox.length(), "error", shared.optString("error"), "phase", shared.optString("phase")));
        }
        TaskStore.put(copy, "localRuns", summaries); return copy;
    }
    public void configure(String json) {
        SupabaseSettings.validate(json);
        worker.execute(() -> {
            try {
                settings.save(json); client.reset();
                synchronized (this) {
                    state = TaskStore.object("configured", true, "online", false, "busy", false, "runs", new JSONArray()); saveCache();
                }
                refreshNow();
            } catch (Exception failure) { set("error", safeMessage(failure)); }
        });
    }
    public void refresh() { worker.execute(this::refreshNow); }
    public void start(String runId) {
        worker.execute(() -> {
            set("busy", true);
            try {
                if (!settings.configured()) throw new IllegalStateException("공유 서버를 먼저 연결해 주세요.");
                JSONObject context = (JSONObject) client.rpc("ppomi_context", new JSONObject()); validateIdentity(context);
                JSONObject run = ((JSONObject) client.rpc("ppomi_get_run", TaskStore.object("p_run_id", runId))).getJSONObject("run");
                if (!settings.credentials().optString("deviceId").equals(run.optString("executor_device_id")))
                    throw new IllegalStateException("다른 기기에 배정된 작업은 이 기기에서 실행할 수 없습니다.");
                runner.prepareSharedBuiltin(run);
                JSONObject claimed = (JSONObject) client.rpc("ppomi_claim_run", TaskStore.object("p_run_id", runId, "p_expected_version", run.getLong("version")));
                runner.startClaimedShared(runId, claimed.getLong("version"));
                set("error", "");
            } catch (Exception failure) { set("error", safeMessage(failure)); }
            finally { set("busy", false); refreshNow(); }
        });
    }
    private void refreshNow() {
        if (!settings.configured()) return;
        try {
            JSONObject context = (JSONObject) client.rpc("ppomi_context", new JSONObject()); validateIdentity(context);
            flush(context);
            JSONArray runs = (JSONArray) client.rpc("ppomi_list_runs", TaskStore.object("p_limit", 50));
            JSONArray documents = (JSONArray) client.rpc("ppomi_list_documents", new JSONObject());
            synchronized (this) {
                TaskStore.put(state, "configured", true); TaskStore.put(state, "online", true);
                TaskStore.put(state, "context", context); TaskStore.put(state, "runs", runs);
                TaskStore.put(state, "documents", documents);
                TaskStore.put(state, "deviceId", context.getJSONObject("device").getString("id"));
                TaskStore.put(state, "lastUpdated", TaskStore.now()); TaskStore.put(state, "connectionError", ""); saveCache();
            }
        } catch (Exception failure) {
            synchronized (this) { TaskStore.put(state, "online", false); TaskStore.put(state, "connectionError", safeMessage(failure)); }
        }
    }
    private void validateIdentity(JSONObject context) throws Exception {
        if (!settings.credentials().getString("deviceId").equals(context.getJSONObject("device").getString("id")))
            throw new IllegalStateException("서버의 기기 등록과 이 앱의 연결 정보가 일치하지 않습니다.");
    }
    private void flush(JSONObject context) throws Exception {
        String deviceId = context.getJSONObject("device").getString("id"), workspaceId = context.getJSONObject("workspace").getString("id");
        JSONArray tasks = runner.store().list();
        for (int i = 0; i < tasks.length(); i++) {
            JSONObject task = tasks.getJSONObject(i), shared = task.optJSONObject("shared");
            if (shared == null || !deviceId.equals(shared.optString("executorDeviceId")) || !workspaceId.equals(shared.optString("workspaceId"))) continue;
            String id = task.getString("id");
            if ("claiming".equals(shared.optString("phase"))) {
                JSONObject serverRun = ((JSONObject) client.rpc("ppomi_get_run", TaskStore.object("p_run_id", id))).getJSONObject("run");
                runner.reconcileSharedClaim(id, serverRun);
            }
            if (!shared.optString("error").isEmpty()) continue;
            JSONObject event;
            while ((event = runner.store().firstSharedEvent(id)) != null) {
                try {
                    JSONObject result = (JSONObject) client.rpc("ppomi_append_run_event", event);
                    runner.store().acknowledgeSharedEvent(id, event.getString("p_event_id"), result.getJSONObject("run").getLong("version"));
                } catch (SupabaseClient.HttpFailure failure) {
                    if (failure.conflict || (failure.status >= 400 && failure.status < 500 && failure.status != 401 && failure.status != 403 && failure.status != 429)) {
                        runner.store().sharedError(id, failure.getMessage()); break;
                    }
                    throw failure;
                }
            }
        }
    }
    private synchronized void set(String key, Object value) { TaskStore.put(state, key, value); }
    private void saveCache() {
        FileOutputStream output = null;
        try { output = cache.startWrite(); output.write(state.toString().getBytes(StandardCharsets.UTF_8)); cache.finishWrite(output); }
        catch (Exception failure) { if (output != null) cache.failWrite(output); }
    }
    private static String safeMessage(Exception failure) {
        return failure instanceof IllegalStateException || failure instanceof SupabaseClient.HttpFailure
            ? failure.getMessage() : "공유 작업을 확인하지 못했습니다. 기기의 실행 기록은 유지됩니다.";
    }
}
