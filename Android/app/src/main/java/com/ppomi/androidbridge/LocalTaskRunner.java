package com.ppomi.androidbridge;

import android.content.Context;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** On-device executor. No ADB, Mac, inbound MCP or model request is needed for built-in procedures. */
public final class LocalTaskRunner {
    private static LocalTaskRunner instance;
    private static volatile String owner;
    private static volatile String ownerState;
    private final Context context;
    private final TaskStore store;
    private final ExecutorService worker = Executors.newSingleThreadExecutor(r -> new Thread(r, "ppomi-local-task"));
    private static final Set<String> MODEL_TOOLS = new HashSet<>(Arrays.asList("open_app", "click", "type_text", "tap", "swipe", "long_press", "long_press_drag", "back", "home", "recents"));

    private LocalTaskRunner(Context context) {
        this.context = context.getApplicationContext();
        this.store = new TaskStore(this.context);
        store.recoverInterrupted();
    }
    public static synchronized LocalTaskRunner get(Context context) {
        if (instance == null) instance = new LocalTaskRunner(context);
        return instance;
    }
    public TaskStore store() { return store; }
    public static String actionOwner() { return owner; }
    public static boolean permitsOwner(String ownerId) {
        String current = owner;
        return current == null ? ownerId == null : current.equals(ownerId) && "running".equals(ownerState);
    }
    public synchronized JSONObject activeTask() { return owner == null ? null : store.get(owner); }

    public synchronized JSONObject startBuiltin(String request) {
        String text = validateRequest(request);
        try (InputStream input = context.getAssets().open("playbooks/text-test.json")) {
            String asset = new String(readBytes(input), StandardCharsets.UTF_8);
            JSONObject procedure = new JSONObject(asset);
            return start(text, "builtin", procedure.getJSONArray("steps"));
        } catch (RuntimeException error) { throw error; }
        catch (Exception error) { throw new IllegalStateException("내장 절차를 읽지 못했습니다.", error); }
    }
    public synchronized JSONObject startModel(String request) {
        if (!AgentSettings.get(context).configured()) throw new IllegalStateException("AI 모델을 먼저 연결해 주세요.");
        return start(validateRequest(request), "model", new JSONArray());
    }
    /** Persists the no-replay guard before requesting the server claim. This never starts execution. */
    synchronized JSONObject prepareSharedBuiltin(JSONObject run) throws Exception {
        if (AndroidExecutor.hasActiveControl()) throw new IllegalStateException("음성 대화를 종료한 뒤 별도 작업을 시작해 주세요.");
        if (owner != null) throw new IllegalStateException("진행 중인 작업을 먼저 완료하거나 중지해 주세요.");
        if (BridgeAccessibilityService.getInstance() == null) throw new IllegalStateException("Android 접근성 설정에서 뽀미 서비스를 먼저 켜 주세요.");
        if (!"queued".equals(run.optString("state")) || !"builtin".equals(run.optString("mode")))
            throw new IllegalArgumentException("대기 중인 내장 테스트 작업만 실행할 수 있습니다.");
        try (InputStream input = context.getAssets().open("playbooks/text-test.json")) {
            JSONArray steps = new JSONObject(new String(readBytes(input), StandardCharsets.UTF_8)).getJSONArray("steps");
            return store.create(run.getString("id"), validateRequest(run.getString("request")), "builtin", steps,
                TaskStore.object("phase", "claiming", "claimExpectedVersion", run.getLong("version"),
                    "executorDeviceId", run.getString("executor_device_id"), "workspaceId", run.getString("workspace_id"), "outbox", new JSONArray()));
        }
    }
    synchronized JSONObject startClaimedShared(String id, long version) {
        JSONObject task = store.get(id), shared = task.optJSONObject("shared");
        if (shared == null || !"claiming".equals(shared.optString("phase"))) throw new IllegalStateException("이미 처리한 공유 작업입니다.");
        TaskStore.put(shared, "phase", "active"); TaskStore.put(shared, "serverVersion", version); TaskStore.put(shared, "nextVersion", version);
        if (owner != null || AndroidExecutor.hasActiveControl() || BridgeAccessibilityService.getInstance() == null) {
            TaskStore.put(task, "state", "interrupted");
            store.event(task, "interrupted", "실행 준비 중 기기 연결 또는 작업 상태가 변경됐습니다.", new JSONObject());
            return task;
        }
        TaskStore.put(task, "state", "running");
        owner = id; ownerState = "running";
        store.event(task, "started", "공유 작업을 이 기기의 내장 절차로 실행합니다.", new JSONObject());
        schedule(id);
        return TaskStore.copy(task);
    }
    synchronized void reconcileSharedClaim(String id, JSONObject serverRun) {
        JSONObject task = store.get(id), shared = task.optJSONObject("shared");
        if (shared == null || !"claiming".equals(shared.optString("phase"))) return;
        if ("running".equals(serverRun.optString("state"))) {
            TaskStore.put(shared, "phase", "active"); TaskStore.put(shared, "serverVersion", serverRun.optLong("version"));
            TaskStore.put(shared, "nextVersion", serverRun.optLong("version"));
            TaskStore.put(task, "state", "interrupted");
            store.event(task, "interrupted", "서버 실행권 요청 결과가 불확실하여 동작을 시작하지 않았습니다.", new JSONObject());
        } else {
            TaskStore.put(shared, "phase", "claim_failed"); TaskStore.put(task, "state", "failed");
            TaskStore.put(task, "summary", "서버 실행권을 확정하지 못했습니다. 이 작업의 동작을 다시 시작하지 않습니다."); store.save(task);
        }
    }
    private JSONObject start(String request, String mode, JSONArray steps) {
        if (AndroidExecutor.hasActiveControl()) throw new IllegalStateException("음성 대화를 종료한 뒤 별도 작업을 시작해 주세요.");
        if (owner != null) throw new IllegalStateException("진행 중인 작업을 먼저 완료하거나 중지해 주세요.");
        if (BridgeAccessibilityService.getInstance() == null) throw new IllegalStateException("Android 접근성 설정에서 뽀미 서비스를 먼저 켜 주세요.");
        JSONObject task = store.create(request, mode, steps);
        owner = task.optString("id"); ownerState = "running";
        store.event(task, "started", mode.equals("builtin") ? "내장 절차를 폰에서 실행합니다. 모델에 연결하지 않습니다."
            : "요청과 현재 앱의 화면 텍스트를 설정한 모델에 전송하는 작업을 시작합니다.", new JSONObject());
        schedule(owner);
        return TaskStore.copy(task);
    }

    public synchronized JSONObject approve(String id) {
        JSONObject task = requireOwner(id, "waiting_approval");
        TaskStore.put(task, "state", "running");
        TaskStore.put(task, "approved", true);
        TaskStore.put(task, "summary", "승인한 동작을 실행합니다.");
        ownerState = "running";
        store.event(task, "approved", "사용자가 화면에 표시된 동작을 승인했습니다.", task.optJSONObject("approval"));
        schedule(id);
        return TaskStore.copy(task);
    }

    public synchronized JSONObject cancel(String id) {
        JSONObject task = store.get(id);
        if (terminal(task.optString("state"))) return task;
        TaskStore.put(task, "state", "cancelled");
        TaskStore.put(task, "summary", "사용자가 중지했습니다. 이미 완료된 동작은 되돌리지 않습니다.");
        store.event(task, "cancelled", task.optString("summary"), new JSONObject());
        release(id);
        return task;
    }

    public synchronized JSONObject resume(String id) {
        if (AndroidExecutor.hasActiveControl()) throw new IllegalStateException("음성 대화를 종료한 뒤 별도 작업을 시작해 주세요.");
        if (owner != null) throw new IllegalStateException("진행 중인 작업을 먼저 중지해 주세요.");
        JSONObject task = store.get(id);
        if (task.has("shared")) throw new IllegalStateException("공유 작업은 새 작업으로 다시 요청해 주세요. 중단된 동작을 자동으로 반복하지 않습니다.");
        if (!task.optString("state").equals("interrupted")) throw new IllegalStateException("중단된 작업만 이어갈 수 있습니다.");
        JSONObject flight = task.optJSONObject("inFlight");
        if (flight != null && flight.optBoolean("mutation"))
            throw new IllegalStateException("직전 동작의 완료 여부가 불확실합니다. 화면을 확인한 후 새 작업으로 다시 시작해 주세요.");
        if (BridgeAccessibilityService.getInstance() == null) throw new IllegalStateException("접근성 서비스를 먼저 켜 주세요.");
        boolean approval = task.optJSONObject("approval") != null;
        owner = id; ownerState = approval ? "waiting_approval" : "running";
        TaskStore.put(task, "state", ownerState); task.remove("inFlight");
        TaskStore.put(task, "approved", false);
        TaskStore.put(task, "summary", approval ? "동작을 다시 확인하고 승인해 주세요." : "확인된 지점에서 계속합니다.");
        store.event(task, "resumed", task.optString("summary"), new JSONObject());
        if (!approval) schedule(id);
        return TaskStore.copy(task);
    }

    public synchronized void serviceDisconnected() {
        if (owner == null) return;
        JSONObject task = store.get(owner);
        TaskStore.put(task, "resumeState", task.optString("state"));
        TaskStore.put(task, "state", "interrupted");
        TaskStore.put(task, "summary", "접근성 연결이 끊겨 작업을 중단했습니다. 자동으로 재실행하지 않습니다.");
        store.event(task, "interrupted", task.optString("summary"), new JSONObject());
        release(task.optString("id"));
    }

    private void schedule(String id) { worker.execute(() -> work(id)); }
    private void work(String id) {
        try {
            while (running(id)) {
                JSONObject task = store.get(id);
                if (task.optString("mode").equals("model")) { modelStep(id, task); continue; }
                JSONArray steps = task.getJSONArray("steps");
                int index = task.optInt("stepIndex");
                if (index >= steps.length()) { complete(id, "입력한 내용이 테스트 앱에 반영된 것을 확인하고 화면 증빙을 저장했습니다."); return; }
                JSONObject step = resolve(steps.getJSONObject(index), task.optString("request"));
                if (step.getString("op").equals("approval")) {
                    if (task.optBoolean("approved")) { advance(id, "승인 단계를 완료했습니다.", new JSONObject()); continue; }
                    waitApproval(id, step); return;
                }
                executeStep(id, step);
                advance(id, "단계 완료: " + step.getString("op"), TaskStore.object("operation", step.getString("op")));
            }
        } catch (Exception failure) { fail(id, failure); }
    }

    private void executeStep(String id, JSONObject step) throws Exception {
        String operation = step.getString("op");
        String target = step.optString("packageName");
        switch (operation) {
            case "open": call(id, "open_app", TaskStore.object("packageName", target)); settle(); break;
            case "observe": saveTree(id, observe(id, target)); break;
            case "type": {
                nodeCall(id, target, step.getJSONObject("selector"), "type_text", TaskStore.object("text", step.getString("text")));
                settle(); break;
            }
            case "click": {
                nodeCall(id, target, step.getJSONObject("selector"), "click", new JSONObject());
                settle(); break;
            }
            case "verify": {
                JSONObject node = find(id, target, step.getJSONObject("selector"));
                synchronized (this) {
                    JSONObject task = requireRunning(id);
                    store.event(task, "verified", "새 화면에서 예상한 결과를 확인했습니다.", TaskStore.object("observedText", node.optString("text")));
                }
                break;
            }
            case "capture": capture(id, target); break;
            default: throw new IllegalArgumentException("지원하지 않는 절차 단계입니다: " + operation);
        }
    }

    private JSONObject observe(String id, String target) throws Exception {
        if (!target.isEmpty()) {
            BridgeAccessPolicy.requireAllowedPackage(context, target);
            JSONObject status = service().executeLocal("status", new JSONObject(), id);
            if (!target.equals(status.optString("foregroundPackage"))) { call(id, "open_app", TaskStore.object("packageName", target)); settle(); }
        }
        Exception last = null;
        for (int attempt = 0; attempt < 15; attempt++) {
            if (!running(id)) throw new InterruptedException("작업이 중단되었습니다.");
            try {
                JSONObject tree = service().executeLocal("ui_tree", new JSONObject(), id);
                if ((target.isEmpty() || target.equals(tree.optString("packageName"))) && tree.getJSONArray("nodes").length() > 0) return tree;
            } catch (Exception notReady) { last = notReady; }
            Thread.sleep(180);
        }
        throw new IllegalStateException("대상 앱의 화면을 확인하지 못했습니다.", last);
    }

    private JSONObject find(String id, String target, JSONObject selector) throws Exception {
        for (int attempt = 0; attempt < 12; attempt++) {
            JSONObject found = uniqueNode(observe(id, target), selector);
            if (found != null) return found;
            Thread.sleep(180);
        }
        throw new IllegalStateException("예상한 화면 요소를 찾지 못했습니다. 화면을 확인해 주세요.");
    }

    private void nodeCall(String id, String target, JSONObject selector, String tool, JSONObject arguments) throws Exception {
        for (int attempt = 0; attempt < 3; attempt++) {
            JSONObject node = find(id, target, selector);
            JSONObject args = TaskStore.copy(arguments); args.put("nodeId", node.getString("id"));
            try { call(id, tool, args); return; }
            catch (Exception failure) {
                Throwable cause = failure;
                while (cause.getCause() != null) cause = cause.getCause();
                // This specific bridge error occurs before performAction. Only this known
                // non-dispatch outcome can be retried; uncertain mutations remain marked.
                if (attempt == 2 || cause.getMessage() == null || !cause.getMessage().contains("Stale nodeId")) throw failure;
                synchronized (this) {
                    JSONObject task = requireRunning(id); task.remove("inFlight");
                    store.event(task, "action_not_dispatched", "화면 노드가 만료되어 실행하지 않았습니다. 새 화면에서 다시 찾습니다.", TaskStore.object("tool", tool));
                }
            }
        }
    }

    static JSONObject uniqueNode(JSONObject tree, JSONObject selector) throws Exception {
        JSONArray nodes = tree.getJSONArray("nodes"); JSONObject found = null;
        for (int i = 0; i < nodes.length(); i++) {
            JSONObject node = nodes.getJSONObject(i);
            if (!node.optBoolean("visible") || !node.optBoolean("enabled") || node.optBoolean("password")) continue;
            boolean matches = true;
            var keys = selector.keys();
            while (keys.hasNext()) { String key = keys.next(); if (!selector.get(key).equals(node.opt(key))) { matches = false; break; } }
            if (!matches) continue;
            if (found != null) throw new IllegalStateException("같은 조건의 화면 요소가 여러 개여서 자동으로 선택하지 않습니다.");
            found = node;
        }
        return found;
    }

    private JSONObject call(String id, String tool, JSONObject args) throws Exception {
        synchronized (this) {
            JSONObject task = requireRunning(id);
            TaskStore.put(task, "inFlight", TaskStore.object("tool", tool, "arguments", args, "mutation", true, "startedAt", TaskStore.now()));
            store.event(task, "action_started", "Android 동작 실행: " + tool, TaskStore.object("tool", tool, "arguments", args));
        }
        JSONObject result = service().executeLocal(tool, args, id);
        if (result.has("gestureId")) {
            String gestureId = result.getString("gestureId");
            long deadline = android.os.SystemClock.uptimeMillis() + 10_000;
            while (true) {
                if (!running(id)) throw new InterruptedException("작업이 중단되었습니다.");
                JSONObject gesture = service().executeLocal("gesture_status", TaskStore.object("gestureId", gestureId), id);
                String state = gesture.optString("state");
                if ("completed".equals(state)) { result.put("gesture", gesture); break; }
                if (!"pending".equals(state)) throw new IllegalStateException("제스처가 완료되지 않았습니다. 화면을 확인해 주세요: " + state);
                if (android.os.SystemClock.uptimeMillis() > deadline) throw new IllegalStateException("제스처 완료 확인 시간이 초과됐습니다. 자동 재시도하지 않습니다.");
                Thread.sleep(100);
            }
        }
        synchronized (this) {
            JSONObject task = requireRunning(id);
            // Keep this marker until the durable step checkpoint advances. A crash after the
            // platform accepted an action must never replay that same action on resume.
            JSONObject flight = task.optJSONObject("inFlight");
            if (flight != null) TaskStore.put(flight, "returned", true);
            store.event(task, "action_returned", "Android가 동작 결과를 반환했습니다. 이후 화면에서 결과를 확인합니다.", TaskStore.object("tool", tool, "result", result));
        }
        return result;
    }

    private void saveTree(String id, JSONObject tree) throws Exception {
        synchronized (this) {
            JSONObject task = requireRunning(id);
            File file = store.evidenceFile(id, UUID.randomUUID() + ".json");
            AtomicFile atomic = new AtomicFile(file); FileOutputStream output = atomic.startWrite();
            try { output.write(tree.toString().getBytes(StandardCharsets.UTF_8)); atomic.finishWrite(output); }
            catch (Exception error) { atomic.failWrite(output); throw error; }
            store.evidence(task, "ui_tree", file, TaskStore.object("packageName", tree.optString("packageName"), "snapshotId", tree.optString("snapshotId")));
        }
    }
    private void capture(String id, String target) throws Exception {
        JSONObject tree = observe(id, target); saveTree(id, tree);
        File file = store.evidenceFile(id, UUID.randomUUID() + ".png");
        JSONObject result = service().captureLocal(file.getAbsolutePath(), id);
        synchronized (this) {
            JSONObject task = requireRunning(id);
            if (!file.isFile() || file.length() == 0) throw new IllegalStateException("화면 증빙 파일이 저장되지 않았습니다.");
            store.evidence(task, "screenshot", file, result);
            store.event(task, "evidence_saved", "Android에서 직접 캡처한 화면을 폰에 저장했습니다.", result);
        }
    }

    private synchronized void advance(String id, String message, JSONObject data) {
        JSONObject task = requireRunning(id);
        TaskStore.put(task, "stepIndex", task.optInt("stepIndex") + 1);
        TaskStore.put(task, "summary", message); task.remove("approval"); task.remove("approved");
        task.remove("inFlight");
        store.event(task, "step_completed", message, data);
    }
    private void waitApproval(String id, JSONObject approval) {
        synchronized (this) {
            JSONObject task = requireRunning(id);
            TaskStore.put(task, "state", "waiting_approval"); TaskStore.put(task, "approval", approval);
            TaskStore.put(task, "summary", "동작을 실행하기 전에 승인을 기다립니다.");
            ownerState = "waiting_approval";
            store.event(task, "approval_requested", task.optString("summary"), approval);
        }
        BridgeAccessibilityService bridge = BridgeAccessibilityService.getInstance();
        if (bridge != null) bridge.openWorkbench();
    }
    private synchronized void complete(String id, String summary) {
        JSONObject task = requireRunning(id);
        TaskStore.put(task, "state", "completed"); TaskStore.put(task, "summary", summary);
        task.remove("approval"); task.remove("inFlight");
        store.event(task, "completed", summary, new JSONObject()); release(id);
        BridgeAccessibilityService bridge = BridgeAccessibilityService.getInstance();
        if (bridge != null) bridge.openWorkbench();
    }
    private synchronized void fail(String id, Exception error) {
        if (!id.equals(owner)) return;
        JSONObject task = store.get(id);
        TaskStore.put(task, "state", "failed");
        String message = error.getMessage() == null ? "작업 중 오류가 발생했습니다." : error.getMessage();
        TaskStore.put(task, "summary", message);
        store.event(task, "failed", message, new JSONObject()); release(id);
        BridgeAccessibilityService bridge = BridgeAccessibilityService.getInstance();
        if (bridge != null) bridge.openWorkbench();
    }
    private synchronized JSONObject requireOwner(String id, String state) {
        if (!id.equals(owner)) throw new IllegalStateException("이 작업은 현재 실행 중이 아닙니다.");
        JSONObject task = store.get(id);
        if (!state.equals(task.optString("state"))) throw new IllegalStateException("현재 작업 상태에서는 이 동작을 할 수 없습니다.");
        return task;
    }
    private JSONObject requireRunning(String id) { return requireOwner(id, "running"); }
    private synchronized boolean running(String id) { return id.equals(owner) && "running".equals(ownerState); }
    private void release(String id) { if (id.equals(owner)) { ownerState = null; owner = null; } }
    private static boolean terminal(String state) { return Arrays.asList("completed", "cancelled", "failed").contains(state); }
    private static String validateRequest(String input) {
        String value = input == null ? "" : input.trim();
        if (value.isEmpty()) value = "뽀미 Android 한글 테스트";
        if (value.length() > 2000) throw new IllegalArgumentException("요청은 2,000자 이내로 입력해 주세요.");
        return value;
    }
    private static JSONObject resolve(JSONObject step, String request) throws Exception {
        JSONObject output = new JSONObject(); var keys = step.keys();
        while (keys.hasNext()) {
            String key = keys.next(); Object value = step.get(key);
            output.put(key, value instanceof String ? ((String) value).replace("${request}", request)
                : value instanceof JSONObject ? resolve((JSONObject) value, request) : value);
        }
        return output;
    }
    private static BridgeAccessibilityService service() {
        BridgeAccessibilityService bridge = BridgeAccessibilityService.getInstance();
        if (bridge == null) throw new IllegalStateException("접근성 서비스가 연결되지 않았습니다.");
        return bridge;
    }
    private static void settle() throws InterruptedException { Thread.sleep(350); }
    private static byte[] readBytes(InputStream input) throws Exception {
        java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream(); byte[] buffer = new byte[4096]; int count;
        while ((count = input.read(buffer)) >= 0) bytes.write(buffer, 0, count);
        return bytes.toByteArray();
    }

    private void modelStep(String id, JSONObject task) throws Exception {
        JSONObject pending = task.optJSONObject("pendingAction");
        if (pending != null && task.optBoolean("approved")) {
            JSONObject action = TaskStore.copy(pending);
            String target = action.optString("packageName");
            JSONObject current = observe(id, target);
            JSONObject args = action.getJSONObject("arguments");
            if (action.optJSONObject("selector") != null) {
                JSONObject node = uniqueNode(current, action.getJSONObject("selector"));
                if (node == null) throw new IllegalStateException("승인 후 화면이 바뀌었습니다. 새 작업으로 다시 확인해 주세요.");
                args.put("nodeId", node.getString("id"));
            }
            if ((action.getString("tool").equals("tap") || action.getString("tool").equals("swipe") || action.getString("tool").equals("long_press_drag"))
                && !fingerprint(current).equals(action.optString("screenFingerprint")))
                throw new IllegalStateException("승인 후 화면이 바뀌어 좌표 동작을 중단했습니다.");
            call(id, action.getString("tool"), args); settle();
            synchronized (this) {
                JSONObject next = requireRunning(id);
                next.remove("pendingAction"); next.remove("approved"); next.remove("approval");
                next.remove("inFlight");
                TaskStore.put(next, "stepIndex", next.optInt("stepIndex") + 1);
                String nextPackage = action.getString("tool").equals("open_app") ? args.getString("packageName")
                    : action.getString("tool").equals("home") ? BridgeAccessPolicy.launcherPackage(context) : target;
                TaskStore.put(next, "lastPackage", nextPackage);
                store.save(next);
            }
            return;
        }
        if (task.optInt("modelTurns") >= 24) throw new IllegalStateException("모델 작업의 24단계 제한에 도달했습니다.");
        String target = task.optString("lastPackage", "com.ppomi.androidtarget");
        JSONObject screen = observe(id, target); saveTree(id, screen);
        JSONArray recent = new JSONArray(); JSONArray events = task.getJSONArray("events");
        for (int i = Math.max(0, events.length() - 8); i < events.length(); i++) recent.put(events.get(i));
        synchronized (this) {
            JSONObject next = requireRunning(id);
            TaskStore.put(next, "summary", "설정한 모델에 현재 화면을 보내 다음 동작을 요청합니다.");
            TaskStore.put(next, "modelTurns", next.optInt("modelTurns") + 1);
            store.event(next, "provider_request", "사용자가 선택한 제공자에 요청 및 접근성 화면 텍스트를 전송합니다.",
                TaskStore.object("endpoint", AgentSettings.get(context).snapshot().optString("endpoint")));
        }
        JSONObject decision = new CompatibleModelClient(AgentSettings.get(context), BridgeAccessPolicy.allowedPackages(context)).next(task.optString("request"), screen, recent);
        synchronized (this) { store.event(requireRunning(id), "model_judgment", "모델의 다음 동작 판단입니다. 관찰된 사실과 구분해 저장합니다.", decision); }
        if (decision.getBoolean("done")) {
            capture(id, target);
            complete(id, "모델의 완료 판단: " + decision.optString("summary", "완료") + "\n마지막 화면 증빙을 저장했습니다.");
            return;
        }
        JSONObject action = TaskStore.copy(decision.getJSONObject("action"));
        String tool = action.getString("tool");
        if (!MODEL_TOOLS.contains(tool)) throw new IllegalArgumentException("허용하지 않은 모델 도구입니다.");
        JSONObject args = action.optJSONObject("arguments");
        if (args == null) { args = new JSONObject(); action.put("arguments", args); }
        if (tool.equals("open_app")) {
            String opened = args.getString("packageName"); BridgeAccessPolicy.requireAllowedPackage(context, opened);
            if (opened.equals(context.getPackageName())) throw new IllegalArgumentException("모델은 뽀미의 설정·승인 화면을 조작할 수 없습니다.");
        }
        if (tool.equals("click") || tool.equals("type_text") || tool.equals("long_press") || tool.equals("long_press_drag")) {
            JSONObject selected = null;
            JSONArray nodes = screen.getJSONArray("nodes");
            for (int i = 0; i < nodes.length(); i++) if (nodes.getJSONObject(i).optString("id").equals(args.getString("nodeId"))) selected = nodes.getJSONObject(i);
            if (selected == null || selected.optBoolean("password")) throw new IllegalArgumentException("모델이 현재 화면의 유효한 노드를 선택하지 않았습니다.");
            action.put("selector", modelSelector(screen, selected, tool));
        }
        action.put("packageName", target); action.put("screenFingerprint", fingerprint(screen));
        synchronized (this) { JSONObject next = requireRunning(id); TaskStore.put(next, "pendingAction", action); store.save(next); }
        waitApproval(id, TaskStore.object("title", "모델이 제안한 동작을 실행할까요?", "description",
            decision.optString("reason") + "\n\n도구: " + tool + "\n입력: " + args, "action", tool));
    }

    static JSONObject modelSelector(JSONObject screen, JSONObject selected, String tool) throws Exception {
        JSONObject selector = TaskStore.object("className", selected.optString("className"));
        // Launcher icons often share one resource ID. Preserve their labels as
        // part of the approved identity instead of treating the ID as sufficient.
        for (String field : Arrays.asList("resourceId", "contentDescription", "text")) {
            String value = selected.optString(field);
            if (!value.isEmpty()) selector.put(field, value);
        }
        selector.put(tool.equals("type_text") ? "editable" : tool.startsWith("long_press") ? "longClickable" : "clickable", true);
        JSONObject found = uniqueNode(screen, selector);
        if (found == null || !found.getString("id").equals(selected.getString("id")))
            throw new IllegalStateException("모델 동작 대상을 다시 확인하지 못했습니다.");
        return selector;
    }

    static String fingerprint(JSONObject tree) throws Exception {
        JSONArray output = new JSONArray(); JSONArray nodes = tree.getJSONArray("nodes");
        for (int i = 0; i < nodes.length(); i++) {
            JSONObject node = nodes.getJSONObject(i);
            output.put(TaskStore.object("text", node.optString("text"), "className", node.optString("className"),
                "resourceId", node.optString("resourceId"), "contentDescription", node.optString("contentDescription"),
                "bounds", node.optJSONObject("bounds"), "editable", node.optBoolean("editable"), "clickable", node.optBoolean("clickable"),
                "longClickable", node.optBoolean("longClickable"), "visible", node.optBoolean("visible"),
                "enabled", node.optBoolean("enabled"), "password", node.optBoolean("password")));
        }
        JSONObject approvedScreen = TaskStore.object("packageName", tree.optString("packageName"),
            "displayWidth", tree.optInt("displayWidth"), "displayHeight", tree.optInt("displayHeight"), "nodes", output);
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(approvedScreen.toString().getBytes(StandardCharsets.UTF_8));
        StringBuilder value = new StringBuilder(); for (byte item : digest) value.append(String.format("%02x", item & 255));
        return value.toString();
    }
}
