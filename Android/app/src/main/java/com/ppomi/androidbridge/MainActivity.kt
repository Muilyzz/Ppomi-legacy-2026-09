package com.ppomi.androidbridge

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** The device owns its requests, approvals, credentials and task history. */
class MainActivity : VoiceHostActivity() {
    private var provisioningError by mutableStateOf<String?>(null)
    private var requestedTask by mutableStateOf<String?>(null)
    private var requestedTaskRevision by mutableIntStateOf(0)
    private var requestedVoiceRevision by mutableIntStateOf(0)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        configure(intent)
        requestedTask = intent.getStringExtra("task_id")
        setContent { PpomiTheme {
            val voiceHost = remember { VoiceSessionHost.get(applicationContext) }
            val supportedVoiceView = remember {
                runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) }.getOrDefault(false)
            }
            var showVoice by rememberSaveable { mutableStateOf(requestedTask == null) }
            var showControlApps by remember { mutableStateOf(false) }
            LaunchedEffect(requestedTask, requestedTaskRevision) { if (requestedTask != null) showVoice = false }
            LaunchedEffect(requestedVoiceRevision) { if (requestedVoiceRevision > 0) showVoice = true }
            val runner = remember { LocalTaskRunner.get(applicationContext) }
            val settings = remember { AgentSettings.get(applicationContext) }
            val shared = remember { SharedTaskController.get(applicationContext) }
            var snapshot by remember { mutableStateOf(WorkbenchSnapshot()) }
            var error by remember { mutableStateOf<String?>(null) }
            var refresh by remember { mutableIntStateOf(0) }
            LaunchedEffect(refresh) {
                while (true) {
                    if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                        try {
                            val next = withContext(Dispatchers.IO) {
                                val tasks = runner.store().list().objects().map(TaskSnapshot::from)
                                val active = runner.activeTask()?.let(TaskSnapshot::from)
                                val service = BridgeAccessibilityService.getInstance()
                                WorkbenchSnapshot(tasks, active, BridgeAccessibilityService.connected(),
                                    BridgeSession.supported(), AgentSettingsSnapshot.from(settings.snapshot()), SharedSnapshot.from(shared.snapshot()),
                                    agentEndpoint = voiceHost.agentEndpoint,
                                    controlWindow = ControlWindowSnapshot.from(BridgeAccessibilityService.controlWindow()),
                                    chatControl = VoiceSessionHost.hasActiveControl(),
                                    lastOpened = BridgeAccessibilityService.lastOpenedPackage?.let { ControlAppSnapshot(it, service?.labelOf(it) ?: it) },
                                    popupStatus = BridgeAccessibilityService.popupStatus)
                            }
                            if (snapshot != next) snapshot = next
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (failure: Exception) { error = failure.message ?: "상태 읽기 실패" }
                    }
                    delay(500)
                }
            }
            fun act(action: () -> Unit): Boolean {
                return try { action(); error = null; refresh++; true }
                catch (failure: Exception) { error = failure.message ?: "요청 실패"; false }
            }
            val reasonOf = { t: TaskSnapshot -> t.approvalTitle.ifBlank { t.summary.ifBlank { "승인 필요" } } }
            val onApprove: (String) -> Unit = { id -> if (act { runner.approve(id) }) snapshot.active?.let { voiceHost.note("승인 · ${reasonOf(it)}") } }
            val onCancel: (String) -> Unit = { id -> if (act { runner.cancel(id) }) snapshot.active?.let { voiceHost.note("취소 · ${reasonOf(it)}") } }
            // The person's turn (docs/ui-tree.md): the only time the slot gets a border and the turn band exists.
            val turn = snapshot.active?.takeIf { it.state == "waiting_approval" }   // the runner's owner is the only task that can wait
            // A new turn rings the conversation like an incoming call (docs/ui-tree.md); the approval itself stays native.
            // 사람 차례 → 비서의 단계(톡 → 재촉 → 전화)는 호스트가 밟는다. 작업 화면을 보고 있으면 차례가 이미 보이므로 세지 않는다.
            LaunchedEffect(turn?.id, showVoice) { voiceHost.turn(if (showVoice) turn?.id else null, turn?.let { it.approvalTitle.ifBlank { it.summary.ifBlank { "승인 필요" } } } ?: "") }
            // The control slot (docs/ui-structure.md): Ppomi's content leaves the target app's window alone.
            // Records focus, as on the Mac: the workbench's data views take the whole screen and the target pop-up is
            // minimized while they are open, then restored on the way back to the conversation.
            val slot = if (showVoice) rememberControlSlot(snapshot) else null
            LaunchedEffect(showVoice, snapshot.controlWindow?.packageName != null) {
                val service = BridgeAccessibilityService.getInstance() ?: return@LaunchedEffect
                if (!showVoice && snapshot.controlWindow != null) service.setControlWindowHidden(true)
                if (showVoice && snapshot.controlWindow == null && snapshot.lastOpened != null) service.setControlWindowHidden(false)
            }
            val rootView = LocalView.current
            val density = LocalDensity.current.density
            val statusBar = WindowInsets.statusBars.getTop(LocalDensity.current)
            var dockedPackage by rememberSaveable { mutableStateOf<String?>(null) }   // survives rotation and fold changes
            val openPopup: (String) -> Unit = { packageName ->
                dockedPackage = null
                BridgeAccessibilityService.getInstance()?.openAsPopup(packageName)
            }
            LaunchedEffect(snapshot.controlWindow?.packageName, slot?.window == null) {
                val window = snapshot.controlWindow
                if (window == null) { dockedPackage = null; return@LaunchedEffect }
                // Only a pop-up overlapping this window is parked; split or full-screen targets are never dragged.
                val overlap = slot?.window ?: return@LaunchedEffect
                if (dockedPackage == window.packageName) return@LaunchedEffect
                val service = BridgeAccessibilityService.getInstance() ?: return@LaunchedEffect
                val location = IntArray(2).also { rootView.getLocationOnScreen(it) }
                // Park a pop-up that is not already beside the content at the slot's top-right corner, once per appearance.
                if (overlap.left < rootView.width * 0.5) {
                    val margin = (16 * density).toInt()
                    service.dockControlWindow(location[0] + rootView.width - window.bounds.width() - margin,
                        location[1] + statusBar + margin)
                }
                dockedPackage = window.packageName
            }
            Box(Modifier.fillMaxSize().background(palette.bg)) {
            Row(Modifier.fillMaxSize()) {
            val controlColumn: @Composable () -> Unit = { ControlSlotColumn(slot!!, snapshot, turn, error, openPopup,
                onPickApp = { showControlApps = true }, onRecords = { showVoice = false }, onApprove, onCancel) }
            if (slot != null && !slot.onRight) controlColumn()
            // Padding modifiers consume their insets: IME adds only the space left
            // after the navigation bar, so the WebView shrinks above the keyboard once.
            Column(Modifier.weight(1f).fillMaxHeight().statusBarsPadding().navigationBarsPadding().imePadding()) {
            if (showVoice) {
                // Narrow screens have no control column; the control header still needs a home.
                if (slot == null) ControlHeader(snapshot, onPickApp = { showControlApps = true }, onRecords = { showVoice = false })
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    key(voiceHost.viewGeneration) {
                        if (supportedVoiceView) AndroidView(factory = {
                            voiceHost.obtainView().apply {
                                // A WRAP_CONTENT WebView gives Chromium a zero CSS layout
                                // viewport, even when Compose measures the native view larger.
                                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                            }
                        }, modifier = Modifier.fillMaxSize())
                        else Text("Android System WebView 업데이트 필요")
                    }
                }
                if (slot == null && turn != null) TurnBand(turn, error, onApprove, onCancel)
            } else {
            Box(Modifier.weight(1f)) {
            PpomiWorkbench(snapshot = snapshot, requestedTaskId = requestedTask, requestedTaskRevision = requestedTaskRevision,
                error = provisioningError ?: error,
                onBack = { showVoice = true },
                onDismissError = { provisioningError = null; error = null },
                onPermission = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) },
                onStart = { text, model -> act {
                    val task = if (model) runner.startModel(text) else runner.startBuiltin(text)
                    requestedTask = task.optString("id").takeIf { it.isNotEmpty() }
                    requestedTaskRevision++
                } },
                onApprove = onApprove,
                onCancel = onCancel,
                onSaveAgentEndpoint = { act { voiceHost.agentEndpoint = it } },
                onSaveSettings = { endpoint, model, key -> act { settings.save(endpoint, model, key) } },
                onClearSettings = { act { settings.clear() } },
                onRefreshShared = { shared.refresh() },
                onStartShared = { id -> shared.start(id) },
                onConnectShared = { raw -> act { shared.configure(raw) } },
                onSecretScreen = { secure ->
                    if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                },
                context = this@MainActivity, initialSection = 1)
            }
            }
            }
            if (slot != null && slot.onRight) controlColumn()
            }
            if (turn != null) slot?.window?.let { window ->
                val ink = palette.turn
                Canvas(Modifier.fillMaxSize()) {
                    drawRect(ink, Offset(window.left - 3f, window.top - 3f),
                        Size(window.width() + 6f, window.height() + 6f), style = Stroke(2f * density))
                }
            }
            }
            if (showControlApps) ControlAppsDialog(this@MainActivity, voiceHost) {
                showControlApps = false
                if (!voiceHost.active) voiceHost.destroyHost() // Refresh bootstrap after native selection.
            }
        } }
    }

    override fun onDestroy() {
        // Leaving the conversation ends it, unless an OS call is running: the call screen owns that session.
        if (isFinishing && PpomiTelecom.connection == null) VoiceSessionHost.get(applicationContext).destroyHost()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        configure(intent)
        if (intent.getBooleanExtra("show_voice", false)) {
            requestedVoiceRevision++
            intent.removeExtra("show_voice")
        }
        requestedTask = intent.getStringExtra("task_id")
            ?: runCatching { LocalTaskRunner.get(applicationContext).activeTask()?.optString("id") }.getOrNull()
        requestedTaskRevision++
    }

    private fun configure(intent: Intent) {
        // The public launcher must never import credentials or redirect native
        // bearer-token requests. Debug provisioning has a separate DUMP gate.
        intent.removeExtra("bridge_token")
        intent.removeExtra("ssot_config")
        intent.removeExtra("configure_agent_endpoint")
        try {
            BridgeSession.configure(this, null)
            provisioningError = null
        } catch (failure: IllegalArgumentException) { provisioningError = failure.message }
    }
}

/** The reserved rectangle beside Ppomi's content: placeholder while empty, the live window bounds while present. */
private data class ControlSlot(val widthPx: Int, val onRight: Boolean, val window: android.graphics.Rect?)

@Composable
private fun rememberControlSlot(snapshot: WorkbenchSnapshot): ControlSlot? {
    if (LocalConfiguration.current.screenWidthDp < 720) return null   // narrow screens use the panel over the app instead
    val view = LocalView.current
    val rootWidth = view.width
    val rootHeight = view.height
    if (rootWidth <= 0 || rootHeight <= 0) return null
    val location = IntArray(2).also { view.getLocationOnScreen(it) }
    val overlap = snapshot.controlWindow?.bounds?.let { bounds ->
        android.graphics.Rect(bounds.left - location[0], bounds.top - location[1], bounds.right - location[0], bounds.bottom - location[1])
            .takeIf { it.intersect(0, 0, rootWidth, rootHeight) }
    }
    // A split-screen target sits beside this window (no overlap) and a full-screen one covers it: nothing to reserve.
    if (snapshot.controlWindow != null && overlap == null) return null
    if (overlap != null && overlap.width() > rootWidth * 0.85) return null
    val onRight = overlap == null || overlap.centerX() >= rootWidth / 2
    val width = when {
        overlap == null -> (rootWidth * 0.42).toInt()
        onRight -> rootWidth - overlap.left
        else -> overlap.right
    }
    return ControlSlot(width.coerceIn(rootWidth / 5, rootWidth * 3 / 4), onRight, overlap)
}

/** 제어 열: 머리띠(대상 · 기록) + 자리 + 사람 차례일 때만 차례 띠. */
@Composable
private fun ControlSlotColumn(slot: ControlSlot, snapshot: WorkbenchSnapshot, turn: TaskSnapshot?, error: String?, onOpenPopup: (String) -> Unit,
                              onPickApp: () -> Unit, onRecords: () -> Unit, onApprove: (String) -> Unit, onCancel: (String) -> Unit) {
    val width = with(LocalDensity.current) { slot.widthPx.toDp() }
    Column(Modifier.width(width).fillMaxHeight().statusBarsPadding().navigationBarsPadding()) {
        ControlHeader(snapshot, onPickApp, onRecords)
        // Empty slot: one line, ink border on the person's turn. The docked pop-up covers this rectangle otherwise
        // (its border is the Canvas over the window bounds).
        Box(Modifier.weight(1f).fillMaxWidth().then(if (turn != null && slot.window == null) Modifier.border(2.dp, palette.turn) else Modifier),
            contentAlignment = Alignment.Center) {
            if (slot.window == null) {
                val app = snapshot.lastOpened
                when {
                    snapshot.popupStatus.isNotBlank() -> SlotLine(snapshot.popupStatus)
                    snapshot.chatControl || snapshot.active?.state == "running" -> SlotLine("뽀미 진행 중")
                    app != null && snapshot.connected -> TextButton(onClick = { onOpenPopup(app.packageName) }) { Text("${app.label} 팝업") }
                    else -> SlotLine(app?.label ?: "팝업 자리")
                }
            }
        }
        if (turn != null) TurnBand(turn, error, onApprove, onCancel)
    }
}

/** 차례 띠: 사람 차례일 때만 한 줄(승인 실패면 그 오류) + 승인 · 취소. */
@Composable
private fun TurnBand(turn: TaskSnapshot, error: String?, onApprove: (String) -> Unit, onCancel: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        SlotLine(error ?: turn.approvalTitle.ifBlank { turn.summary.ifBlank { "승인 필요" } }, palette.fg, Modifier.weight(1f))
        Button(onClick = { onApprove(turn.id) }, colors = accentButton, modifier = Modifier.testTag("approve_task")) { Text("승인") }
        TextButton(onClick = { onCancel(turn.id) }, modifier = Modifier.testTag("cancel_task")) { Text("취소") }
    }
}

@Composable
private fun SlotLine(text: String, color: androidx.compose.ui.graphics.Color = palette.fg2, modifier: Modifier = Modifier) =
    Text(text, color = color, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = modifier.padding(horizontal = 12.dp))

/** 제어 머리띠: 대상(허용 앱 선택기, 현재 앱 이름) · 기록. */
@Composable
private fun ControlHeader(snapshot: WorkbenchSnapshot, onPickApp: () -> Unit, onRecords: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onPickApp, modifier = Modifier.semantics { contentDescription = "제어 앱" }) { Text(snapshot.lastOpened?.label ?: "제어 앱") }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onRecords) { Text("기록") }
    }
}

@Composable
private fun ControlAppsDialog(activity: MainActivity, host: VoiceSessionHost, onClose: () -> Unit) {
    var ready by remember { mutableStateOf(!host.active && !host.hasPendingStart()) }
    var apps by remember { mutableStateOf<List<BridgeAccessPolicy.App>?>(null) }
    var defaults by remember { mutableStateOf<Set<String>>(emptySet()) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var query by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(ready) {
        if (ready) {
            try {
                val available = withContext(Dispatchers.IO) { BridgeAccessPolicy.launchableApps(activity) }
                defaults = BridgeAccessPolicy.defaultPackages(activity)
                selected = BridgeAccessPolicy.allowedPackages(activity).intersect(available.map { it.packageName }.toSet())
                apps = available
            } catch (_: Exception) { error = "앱 목록 읽기 실패" }
        }
    }
    if (!ready) {
        AlertDialog(onDismissRequest = onClose, title = { Text("대화 종료") },
            text = { Text("종료 뒤 제어 앱 선택") },
            confirmButton = { TextButton(onClick = { host.stopVoice(); ready = true }) { Text("종료하고 선택") } },
            dismissButton = { TextButton(onClick = onClose) { Text("취소") } })
        return
    }
    AlertDialog(onDismissRequest = onClose, title = { Text("제어 앱") }, text = {
        Column {
            Text("선택한 앱 화면 읽기·조작 · 설정·홈 기본 허용 · 송금·결제·인증 제한")
            OutlinedTextField(value = query, onValueChange = { query = it }, singleLine = true,
                label = { Text("검색") }, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it) }
            if (apps == null && error == null) Text("읽는 중")
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 380.dp)) {
                items((apps ?: emptyList()).filter { it.label.contains(query, true) || it.packageName.contains(query, true) }, key = { it.packageName }) { app ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = selected.contains(app.packageName), enabled = !defaults.contains(app.packageName),
                            onCheckedChange = { checked -> selected = if (checked) selected + app.packageName else selected - app.packageName })
                        Column(Modifier.weight(1f)) {
                            Text(app.label + if (defaults.contains(app.packageName)) " · 기본 허용" else "")
                            Text(app.packageName, fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = palette.fg2)
                        }
                    }
                }
            }
        }
    }, confirmButton = {
        TextButton(enabled = apps != null, onClick = {
            try { BridgeAccessPolicy.saveUserPackages(activity, selected); onClose() }
            catch (_: Exception) { error = "작업 종료 뒤 저장" }
        }) { Text("저장") }
    }, dismissButton = { TextButton(onClick = onClose) { Text("취소") } })
}

internal fun org.json.JSONArray.objects(): List<JSONObject> =
    (0 until length()).mapNotNull { optJSONObject(it) }
