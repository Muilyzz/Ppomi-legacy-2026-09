package com.ppomi.androidbridge;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.UUID;

/** App-private task/evidence records. These records are not financial journal postings. */
public final class TaskStore {
    private final File directory;

    public TaskStore(Context context) { this(new File(context.getFilesDir(), "tasks")); }
    TaskStore(File directory) {
        this.directory = directory;
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("작업 저장소를 만들지 못했습니다.");
    }

    public synchronized JSONArray list() {
        ArrayList<JSONObject> tasks = new ArrayList<>();
        File[] files = directory.listFiles((dir, name) -> name.endsWith(".json"));
        if (files != null) for (File file : files) tasks.add(read(file));
        tasks.sort(Comparator.comparing((JSONObject item) -> item.optString("createdAt")).reversed());
        return new JSONArray(tasks);
    }

    public synchronized JSONObject get(String id) {
        File file = taskFile(id);
        if (!file.isFile()) throw new IllegalArgumentException("작업을 찾을 수 없습니다.");
        return read(file);
    }

    synchronized JSONObject create(String request, String mode, JSONArray steps) {
        return create(UUID.randomUUID().toString(), request, mode, steps, null);
    }

    synchronized JSONObject create(String id, String request, String mode, JSONArray steps, JSONObject shared) {
        if (taskFile(id).exists()) throw new IllegalStateException("이미 기기에 기록된 공유 작업입니다. 같은 동작을 다시 시작하지 않습니다.");
        JSONObject task = object("id", id, "request", request,
            "title", request.length() > 48 ? request.substring(0, 48) + "…" : request,
            "mode", mode, "modeLabel", mode.equals("builtin") ? "내장 절차 · AI 모델 미연결" : "연결한 AI 모델",
            "state", "running", "stepIndex", 0, "stepCount", steps.length(), "steps", steps,
            "createdAt", now(), "updatedAt", now(), "summary", "작업을 준비합니다.",
            "events", new JSONArray(), "evidence", new JSONArray(), "modelTurns", 0);
        if (shared != null) { put(task, "shared", shared); put(task, "state", "queued"); }
        save(task);
        return task;
    }

    synchronized void save(JSONObject task) {
        put(task, "updatedAt", now());
        AtomicFile atomic = new AtomicFile(taskFile(task.optString("id")));
        FileOutputStream output = null;
        try {
            output = atomic.startWrite();
            output.write(task.toString().getBytes(StandardCharsets.UTF_8));
            atomic.finishWrite(output);
        } catch (Exception error) {
            if (output != null) atomic.failWrite(output);
            throw new IllegalStateException("작업 상태를 저장하지 못했습니다.", error);
        }
    }

    synchronized void event(JSONObject task, String type, String message, JSONObject data) {
        JSONArray events = task.optJSONArray("events");
        if (events == null) { events = new JSONArray(); put(task, "events", events); }
        JSONObject event = object("id", UUID.randomUUID().toString(), "time", now(), "type", type,
            "message", message, "data", data == null ? new JSONObject() : data);
        events.put(event);
        SharedRunJournal.append(task, event);
        save(task);
    }

    synchronized JSONObject firstSharedEvent(String id) {
        JSONObject shared = get(id).optJSONObject("shared");
        JSONArray outbox = shared == null ? null : shared.optJSONArray("outbox");
        return outbox == null || outbox.length() == 0 ? null : copy(outbox.optJSONObject(0));
    }
    synchronized void acknowledgeSharedEvent(String id, String eventId, long version) {
        JSONObject task = get(id), shared = task.optJSONObject("shared");
        JSONArray outbox = shared.optJSONArray("outbox");
        if (outbox == null || outbox.length() == 0 || !eventId.equals(outbox.optJSONObject(0).optString("p_event_id")))
            throw new IllegalStateException("공유 기록 전송 순서를 확인할 수 없습니다.");
        outbox.remove(0); put(shared, "serverVersion", version); shared.remove("error"); save(task);
    }
    synchronized void sharedError(String id, String error) {
        JSONObject task = get(id); put(task.optJSONObject("shared"), "error", error); save(task);
    }

    /** Must run once per process before accepting a new task; never replays an interrupted action. */
    synchronized void recoverInterrupted() {
        JSONArray tasks = list();
        for (int i = 0; i < tasks.length(); i++) {
            JSONObject task = tasks.optJSONObject(i);
            String state = task.optString("state");
            if (!state.equals("running") && !state.equals("waiting_approval")) continue;
            put(task, "resumeState", state);
            put(task, "state", "interrupted");
            put(task, "summary", "앱 실행이 중단되었습니다. 실행 중이던 동작을 자동으로 반복하지 않습니다.");
            event(task, "interrupted", task.optString("summary"), new JSONObject());
        }
    }

    public synchronized File evidenceFile(String taskId, String fileName) {
        taskFile(taskId);
        if (!fileName.matches("[A-Za-z0-9_-]+\\.(png|json)")) throw new IllegalArgumentException("잘못된 증빙 파일 이름입니다.");
        File folder = new File(directory, taskId);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IllegalStateException("증빙 저장소를 만들지 못했습니다.");
        return new File(folder, fileName);
    }

    synchronized void evidence(JSONObject task, String kind, File file, JSONObject metadata) {
        JSONArray evidence = task.optJSONArray("evidence");
        evidence.put(object("id", UUID.randomUUID().toString(), "kind", kind, "path", file.getAbsolutePath(),
            "createdAt", now(), "source", "android_accessibility", "metadata", metadata));
        if (kind.equals("screenshot")) put(task, "screenshotPath", file.getAbsolutePath());
        save(task);
    }

    private File taskFile(String id) {
        if (id == null || !id.matches("[a-f0-9-]{36}")) throw new IllegalArgumentException("잘못된 작업 ID입니다.");
        return new File(directory, id + ".json");
    }

    private static JSONObject read(File file) {
        try { return new JSONObject(new String(new AtomicFile(file).readFully(), StandardCharsets.UTF_8)); }
        catch (Exception failure) { throw new IllegalStateException("저장된 작업을 읽지 못했습니다: " + file.getName(), failure); }
    }

    static String now() { return Instant.now().toString(); }
    static JSONObject object(Object... entries) {
        JSONObject output = new JSONObject();
        for (int i = 0; i < entries.length; i += 2) put(output, (String) entries[i], entries[i + 1]);
        return output;
    }
    static void put(JSONObject object, String key, Object value) {
        try { object.put(key, value == null ? JSONObject.NULL : value); }
        catch (Exception error) { throw new IllegalArgumentException(error); }
    }
    static JSONObject copy(JSONObject object) {
        try { return new JSONObject(object.toString()); }
        catch (Exception error) { throw new IllegalArgumentException(error); }
    }
}
