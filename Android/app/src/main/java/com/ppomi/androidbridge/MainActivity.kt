package com.ppomi.androidbridge

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import android.view.ViewGroup
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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
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
    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
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
            var showControl by rememberSaveable { mutableStateOf(false) }
            var contentPresented by rememberSaveable { mutableStateOf(intent.getBooleanExtra("executor_settings", false) && intent.getIntExtra("executor_section", 1) == 1) }
            var contentVisible by remember { mutableStateOf(false) }
            var showSettings by rememberSaveable { mutableStateOf(intent.getBooleanExtra("executor_settings", false) && intent.getIntExtra("executor_section", 1) == 2) }
            var showControlApps by remember { mutableStateOf(intent.getBooleanExtra("executor_control_apps", false)) }
            var parkedPopup by rememberSaveable { mutableStateOf(false) }
            val recordState = rememberSaveableStateHolder()
            LaunchedEffect(requestedTask, requestedTaskRevision) {
                if (requestedTask != null) {
                    showSettings = false; showControlApps = false
                    showControl = false; contentPresented = true
                }
            }
            LaunchedEffect(requestedVoiceRevision) {
                if (requestedVoiceRevision > 0) { showSettings = false; showControlApps = false; contentPresented = false }
            }
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
            val turn = snapshot.active?.takeIf { it.inProgress }
            val approval = turn?.takeIf { it.state == "waiting_approval" }
            val busy = snapshot.chatControl || turn != null
            val controlActive = (snapshot.chatControl && snapshot.controlWindow != null) || turn?.state == "running"
            LaunchedEffect(controlActive) { showControl = controlActive }
            val latestApproval by rememberUpdatedState(approval)
            val approvalSurfaceVisible by rememberUpdatedState(contentVisible && !showSettings && !showControlApps)
            DisposableEffect(lifecycle) {
                // A stopped window pauses recomposition; publish visibility from the lifecycle callback itself.
                val observer = LifecycleEventObserver { _, _ ->
                    val current = latestApproval
                    voiceHost.turn(current?.id, current?.let(reasonOf) ?: "",
                        lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) && approvalSurfaceVisible)
                }
                lifecycle.addObserver(observer)
                onDispose {
                    lifecycle.removeObserver(observer)
                    val current = latestApproval
                    voiceHost.turn(current?.id, current?.let(reasonOf) ?: "", false)
                }
            }
            LaunchedEffect(approval, showSettings, showControlApps, contentVisible) {
                voiceHost.turn(approval?.id, approval?.let(reasonOf) ?: "",
                    lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) && contentVisible && !showSettings && !showControlApps)
            }
            var controlArea by remember { mutableStateOf<android.graphics.Rect?>(null) }
            var dockedPackage by remember { mutableStateOf<String?>(null) }
            val openPopup: (String) -> Unit = { packageName ->
                dockedPackage = null
                BridgeAccessibilityService.getInstance()?.openAsPopup(packageName)
            }
            val showRecords: () -> Unit = {
                if (!busy && snapshot.controlWindow != null) {
                    BridgeAccessibilityService.getInstance()?.setControlWindowHidden(true)
                    parkedPopup = true
                }
                showControl = false
            }
            val openControl: () -> Unit = {
                showControl = true
                if (!busy && parkedPopup) {
                    BridgeAccessibilityService.getInstance()?.setControlWindowHidden(false)
                    parkedPopup = false
                }
            }
            // Only an idle fitting popup may be aligned once. Its position never changes the frame's columns.
            LaunchedEffect(snapshot.controlWindow?.packageName, controlArea, showControl, busy) {
                val target = snapshot.controlWindow
                if (target == null) { dockedPackage = null; return@LaunchedEffect }
                val area = controlArea ?: return@LaunchedEffect
                if (!showControl || busy || dockedPackage == target.packageName || area.isEmpty) return@LaunchedEffect
                if (target.bounds.width() > area.width() || target.bounds.height() > area.height()) return@LaunchedEffect
                if (!area.contains(target.bounds)) {
                    BridgeAccessibilityService.getInstance()?.dockControlWindow(area.right - target.bounds.width(), area.top)
                }
                dockedPackage = target.packageName
            }
            // Insets are consumed once around the three-region frame, including the software keyboard.
            Box(Modifier.fillMaxSize().background(palette.bg).statusBarsPadding().navigationBarsPadding().imePadding()) {
                WorkbenchFrame(modifier = Modifier.fillMaxSize(), contentPresented = contentPresented,
                    onContentPresentedChange = { contentPresented = it }, onContentVisibilityChange = { contentVisible = it },
                    contentActionLabel = if (approval != null) "승인 요청" else "기록", topBar = {
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text("뽀미")
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { showSettings = true }, modifier = Modifier.testTag("tab_settings")) { Text("설정") }
                    }
                }, conversation = {
                    key(voiceHost.viewGeneration) {
                        if (supportedVoiceView) AndroidView(factory = {
                            voiceHost.obtainView(this@MainActivity).apply {
                                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                            }
                        }, modifier = Modifier.fillMaxSize())
                        else Text("Android System WebView 업데이트 필요")
                    }
                }, contentPane = {
                    Column(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f).fillMaxWidth()) {
                            if (showControl) {
                                ControlSlotColumn(snapshot, error, openPopup, onPickApp = { showControlApps = true },
                                    onRecords = showRecords, popupEnabled = !busy,
                                    onControlArea = { controlArea = it })
                            } else recordState.SaveableStateProvider("records") {
                                PpomiWorkbench(snapshot = snapshot, requestedTaskId = requestedTask, requestedTaskRevision = requestedTaskRevision,
                                    error = provisioningError ?: error,
                                    onDismissError = { provisioningError = null; error = null },
                                    onPermission = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) },
                                    onStart = { text, model -> act {
                                        val task = if (model) runner.startModel(text) else runner.startBuiltin(text)
                                        requestedTask = task.optString("id").takeIf { it.isNotEmpty() }
                                        requestedTaskRevision++
                                    } },
                                    onControl = openControl,
                                    onRefreshShared = { shared.refresh() }, onStartShared = { id -> shared.start(id) },
                                    context = this@MainActivity)
                            }
                        }
                        if (turn != null) TurnBand(turn, error, onApprove, onCancel)
                    }
                })
            }
            val closeSettings: () -> Unit = {
                if (intent.getBooleanExtra("executor_settings", false)) finish()
                else showSettings = false
            }
            if (showSettings) {
                DisposableEffect(Unit) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                }
                Dialog(onDismissRequest = closeSettings,
                    properties = DialogProperties(usePlatformDefaultWidth = false, securePolicy = SecureFlagPolicy.SecureOn)) {
                    Column(Modifier.fillMaxWidth(0.94f).widthIn(max = 720.dp).fillMaxHeight(0.92f).background(palette.bg)
                        .semantics { testTagsAsResourceId = true }) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            TextButton(onClick = closeSettings, modifier = Modifier.testTag("close_settings")) { Text("닫기") }
                        }
                        Box(Modifier.weight(1f)) {
                            WorkbenchSettings(snapshot, onPermission = { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
                                onControlApps = { if (!voiceHost.active && LocalTaskRunner.actionOwner() == null) showControlApps = true },
                                context = this@MainActivity)
                        }
                    }
                }
            }
            if (showControlApps) ControlAppsDialog(this@MainActivity, voiceHost,
                onSaved = { voiceHost.refreshBootstrap(); showControlApps = false }, onClose = { showControlApps = false })
        } }
    }

    override fun onDestroy() {
        // Leaving the conversation ends it, unless an OS call is running: the call screen owns that session.
        if (isFinishing && PpomiTelecom.connection == null) VoiceSessionHost.get(applicationContext).destroyHost(this)
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

/** The content pane owns control geometry; an external window never reorders chat or changes its width. */
@Composable
private fun ControlSlotColumn(snapshot: WorkbenchSnapshot, error: String?, onOpenPopup: (String) -> Unit,
                              onPickApp: () -> Unit, onRecords: () -> Unit, popupEnabled: Boolean,
                              onControlArea: (android.graphics.Rect?) -> Unit) {
    var area by remember { mutableStateOf<android.graphics.Rect?>(null) }
    val rootView = LocalView.current
    val density = LocalDensity.current.density
    DisposableEffect(Unit) { onDispose { onControlArea(null) } }
    Column(Modifier.fillMaxSize()) {
        ControlHeader(snapshot, onPickApp, onRecords)
        Box(Modifier.weight(1f).fillMaxWidth().padding(12.dp).clipToBounds().onGloballyPositioned { coordinates ->
            val bounds = coordinates.boundsInRoot()
            val origin = IntArray(2).also { rootView.getLocationOnScreen(it) }
            val measured = android.graphics.Rect(bounds.left.toInt() + origin[0], bounds.top.toInt() + origin[1],
                bounds.right.toInt() + origin[0], bounds.bottom.toInt() + origin[1])
            if (area != measured) { area = measured; onControlArea(measured) }
        }, contentAlignment = Alignment.Center) {
            val target = snapshot.controlWindow
            val contained = target != null && area?.contains(target.bounds) == true
            if (!contained) {
                val app = snapshot.lastOpened
                when {
                    error != null -> SlotLine(error)
                    target != null -> SlotLine("제어 자리 밖")
                    snapshot.popupStatus.isNotBlank() -> SlotLine(snapshot.popupStatus)
                    snapshot.chatControl || snapshot.active?.state == "running" -> SlotLine("뽀미 진행 중")
                    app != null && snapshot.connected -> TextButton(onClick = { onOpenPopup(app.packageName) }, enabled = popupEnabled) { Text("${app.label} 팝업") }
                    else -> SlotLine(app?.label ?: "제어할 앱을 선택하세요")
                }
            }
            if (contained && snapshot.active?.state == "waiting_approval") {
                val ink = palette.turn
                Canvas(Modifier.fillMaxSize()) {
                    val bounds = target!!.bounds
                    val host = area!!
                    drawRect(ink, Offset((bounds.left - host.left).toFloat(), (bounds.top - host.top).toFloat()),
                        Size(bounds.width().toFloat(), bounds.height().toFloat()), style = Stroke(2f * density))
                }
            }
        }
    }
}

/** 차례 띠: 사람 차례일 때만 한 줄(승인 실패면 그 오류) + 승인 · 취소. */
@Composable
private fun TurnBand(turn: TaskSnapshot, error: String?, onApprove: (String) -> Unit, onCancel: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SlotLine(error ?: turn.approvalTitle.ifBlank { turn.summary.ifBlank { "진행 중" } }, palette.fg)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            if (turn.state == "waiting_approval") Button(onClick = { onApprove(turn.id) }, colors = accentButton,
                modifier = Modifier.testTag("approve_task")) { Text("승인") }
            TextButton(onClick = { onCancel(turn.id) }, modifier = Modifier.testTag("cancel_task")) { Text("중단") }
        }
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
        TextButton(onClick = onRecords, modifier = Modifier.testTag("show_records")) { Text("기록") }
    }
}

@Composable
private fun ControlAppsDialog(activity: MainActivity, host: VoiceSessionHost, onSaved: () -> Unit, onClose: () -> Unit) {
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
            try { BridgeAccessPolicy.saveUserPackages(activity, selected); onSaved() }
            catch (_: Exception) { error = "작업 종료 뒤 저장" }
        }) { Text("저장") }
    }, dismissButton = { TextButton(onClick = onClose) { Text("취소") } })
}

internal fun org.json.JSONArray.objects(): List<JSONObject> =
    (0 until length()).mapNotNull { optJSONObject(it) }
