package com.ppomi.androidbridge

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val Corners = RoundedCornerShape(22.dp)

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun PpomiWorkbench(
    snapshot: WorkbenchSnapshot,
    requestedTaskId: String?,
    requestedTaskRevision: Int,
    error: String?,
    onDismissError: () -> Unit,
    onPermission: () -> Unit,
    onStart: (String, Boolean) -> Unit,
    onControl: () -> Unit,
    onRefreshShared: () -> Unit,
    onStartShared: (String) -> Unit,
    context: Context,
    initialSection: Int = 1
) {
    var section by rememberSaveable { mutableIntStateOf(initialSection) }
    var selectedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(requestedTaskId, requestedTaskRevision) {
        if (!requestedTaskId.isNullOrEmpty()) { section = 0; selectedTaskId = requestedTaskId }
    }
    val selected = snapshot.tasks.firstOrNull { it.id == selectedTaskId }
        ?: snapshot.active?.takeIf { it.id == selectedTaskId }
    BackHandler(selectedTaskId != null) { selectedTaskId = null }
    PpomiTheme {
        Scaffold(modifier = Modifier.semantics { testTagsAsResourceId = true },
            // The content pane owns record navigation and the switch to native control.
            topBar = {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    NavigationBar(modifier = Modifier.weight(1f), containerColor = palette.bg, tonalElevation = 0.dp) {
                        listOf(Triple(0, "작업", Icons.Outlined.Dashboard), Triple(1, "기록", Icons.Outlined.History),
                            Triple(3, "공유", Icons.Outlined.CloudQueue)).forEach { (index, title, icon) ->
                            val tag = when (index) { 0 -> "tab_tasks"; 1 -> "tab_history"; else -> "tab_shared" }
                            NavigationBarItem(modifier = Modifier.testTag(tag), selected = section == index,
                                onClick = { section = index; selectedTaskId = null },
                                icon = { Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp)) },
                                label = { Text(title, fontSize = 12.sp) })
                        }
                    }
                    TextButton(onClick = onControl, modifier = Modifier.testTag("show_control")) { Text("제어") }
                }
            }) { padding ->
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
                Box(Modifier.widthIn(max = 720.dp).fillMaxSize()) {
                    when {
                        selected != null -> TaskDetail(selected, onBack = { selectedTaskId = null })
                        section == 0 -> Workspace(snapshot, onPermission, onStart,
                            onOpenTask = { selectedTaskId = it })
                        section == 3 -> SharedScreen(snapshot, onRefreshShared, onStartShared,
                            onOpenTask = { selectedTaskId = it })
                        else -> Records(snapshot.tasks, onOpenTask = { selectedTaskId = it })
                    }
                    if (error != null) {
                        Surface(Modifier.align(Alignment.BottomCenter).padding(16.dp).fillMaxWidth(),
                            shape = RoundedCornerShape(16.dp), color = palette.accentSoft, shadowElevation = 8.dp) {
                            Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(error, color = palette.bad, fontSize = 14.sp, modifier = Modifier.weight(1f))
                                IconButton(onClick = onDismissError) { Icon(Icons.Outlined.Close, "닫기") }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Workspace(snapshot: WorkbenchSnapshot, onPermission: () -> Unit,
                      onStart: (String, Boolean) -> Unit,
                      onOpenTask: (String) -> Unit) {
    var request by rememberSaveable { mutableStateOf("") }
    var modelMode by rememberSaveable { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    LaunchedEffect(snapshot.settings.configured) { if (!snapshot.settings.configured) modelMode = false }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { AppHeader("작업대", "시작 · 확인 · 기록") }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusPill(if (snapshot.connected) "연결됨" else "연결 필요",
                    if (snapshot.connected) palette.accentFg else palette.fg2, Icons.Outlined.Smartphone)
                StatusPill("이 기기", palette.fg2)
            }
        }
        if (!snapshot.connected) item {
            SurfaceCard {
                Icon(Icons.Outlined.TouchApp, null, tint = palette.fg2, modifier = Modifier.size(26.dp))
                Text("접근성 연결", fontWeight = FontWeight.Medium, fontSize = 16.sp)
                Text(if (snapshot.supported) "접근성 설정에서 뽀미 켜기" else "디버그 빌드 전용", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
                if (snapshot.supported) Button(onClick = onPermission, colors = accentButton, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(13.dp)) {
                    Text("접근성 설정", modifier = Modifier.padding(vertical = 4.dp))
                }
            }
        }
        snapshot.active?.let { task ->
            item { ActiveTaskCard(task, onOpenTask) }
        }
        item {
            SurfaceCard {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("요청", fontSize = 21.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.01).em, modifier = Modifier.weight(1f))
                    Icon(Icons.Outlined.AutoAwesome, contentDescription = null, tint = palette.fg2, modifier = Modifier.size(22.dp))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !modelMode, onClick = { modelMode = false }, label = { Text("내장 절차") })
                    if (snapshot.settings.configured) FilterChip(selected = modelMode, onClick = { modelMode = true },
                        label = { Text("AI") })
                }
                Text(if (modelMode) snapshot.settings.model else "AI 미연결",
                    color = palette.fg2, fontSize = 12.sp)
                OutlinedTextField(value = request, onValueChange = { if (it.length <= 2000) request = it },
                    label = { Text(if (modelMode) "요청" else "입력 문장") },
                    placeholder = { Text(if (modelMode) "예: 호텔 예약" else "예: 오늘도 한 걸음, 뽀미") },
                    modifier = Modifier.fillMaxWidth().testTag("task_request"), minLines = 3, maxLines = 5, shape = RoundedCornerShape(14.dp))
                Text(if (modelMode) "요청·화면 텍스트를 모델에 전송" else "앱 열기 → 화면 읽기 → 승인 → 입력 → 확인",
                    color = palette.fg2, fontSize = 12.sp, lineHeight = 18.sp)
                Button(onClick = { focus.clearFocus(); onStart(request.trim(), modelMode) }, colors = accentButton,
                    enabled = snapshot.connected && snapshot.active?.inProgress != true && (!modelMode || request.isNotBlank()),
                    modifier = Modifier.fillMaxWidth().height(52.dp).testTag(if (modelMode) "start_model" else "start_builtin"), shape = RoundedCornerShape(14.dp)) {
                    Icon(Icons.Outlined.PlayArrow, null, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (modelMode) "시작" else "실행", fontWeight = FontWeight.Medium)
                }
            }
        }
        if (snapshot.tasks.isNotEmpty()) item {
            SectionLabel("최근 작업", "이 기기")
            Spacer(Modifier.height(12.dp))
            TaskRow(snapshot.tasks.first(), onOpenTask)
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 2.dp), horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Icon(Icons.Outlined.Shield, null, tint = palette.fg2, modifier = Modifier.size(16.dp))
                Text("승인·중지 가능 · 기록 이 기기 저장", color = palette.fg2,
                    fontSize = 12.sp, lineHeight = 18.sp)
            }
        }
    }
}

@Composable
private fun ActiveTaskCard(task: TaskSnapshot, onOpenTask: (String) -> Unit) {
    SurfaceCard(borderColor = if (task.state == "waiting_approval") palette.turn else palette.line) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("현재 작업", fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            StatusPill(task.statusLabel, stateColor(task.state), modifier = Modifier.testTag("task_status"))
        }
        Text(task.request.ifBlank { "테스트 앱 제어" }, fontSize = 16.sp, lineHeight = 24.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        TaskProgress(task)
        if (task.state == "waiting_approval") ApprovalContent(task)
        else {
            Text(task.summary.ifBlank { task.events.lastOrNull()?.message ?: "준비 중" }, color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
            TextButton(onClick = { onOpenTask(task.id) }) { Text("기록") }
        }
    }
}

@Composable
private fun ApprovalContent(task: TaskSnapshot) {
    Row(horizontalArrangement = Arrangement.spacedBy(9.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.BackHand, null, tint = palette.accentFg, modifier = Modifier.size(22.dp))
        Text(task.approvalTitle.ifBlank { "승인 필요" }, color = palette.accentFg, fontWeight = FontWeight.Medium, fontSize = 16.sp)
    }
    Text(task.approvalDescription.ifBlank { task.summary }, fontSize = 14.sp, lineHeight = 21.sp)
}

@Composable
private fun TaskProgress(task: TaskSnapshot) {
    if (task.stepCount > 0) {
        LinearProgressIndicator(progress = { (task.stepIndex.toFloat() / task.stepCount).coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape), color = stateColor(task.state), trackColor = palette.line)
        Text("${task.stepIndex.coerceAtMost(task.stepCount)} / ${task.stepCount} 단계 · ${task.modeLabel}", color = palette.fg2, fontSize = 11.sp, style = Tabular)
    } else Text(task.modeLabel, color = palette.fg2, fontSize = 12.sp)
}

@Composable
private fun Records(tasks: List<TaskSnapshot>, onOpenTask: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { AppHeader("기록", "작업 · 화면") }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Metric("전체", tasks.size.toString(), Modifier.weight(1f))
                Metric("완료", tasks.count { it.state == "completed" }.toString(), Modifier.weight(1f))
                Metric("승인 대기", tasks.count { it.state == "waiting_approval" }.toString(), Modifier.weight(1f))
            }
        }
        if (tasks.isEmpty()) item {
            SurfaceCard {
                Icon(Icons.Outlined.History, null, tint = palette.fg2, modifier = Modifier.size(28.dp))
                Text("작업 없음", fontWeight = FontWeight.Medium, fontSize = 16.sp)
                Text("단계·화면 증빙", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
            }
        }
        items(tasks, key = { it.id }) { TaskRow(it, onOpenTask) }
        item { AccountingExampleCard() }
    }
}

@Composable
private fun TaskRow(task: TaskSnapshot, onOpenTask: (String) -> Unit) {
    Surface(Modifier.fillMaxWidth().testTag("history_item_${task.id}").clip(Corners).clickable { onOpenTask(task.id) }, shape = Corners, color = palette.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, palette.line)) {
        Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(timeLabel(task.createdAt), color = palette.fg2, fontSize = 11.sp, style = Tabular, modifier = Modifier.weight(1f))
                StatusPill(task.statusLabel, stateColor(task.state))
            }
            Text(task.request.ifBlank { "테스트 앱 제어" }, fontWeight = FontWeight.Medium, fontSize = 16.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(task.summary.ifBlank { task.modeLabel }, color = palette.fg2, fontSize = 12.sp, lineHeight = 18.sp,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Outlined.ArrowForward, "상세", tint = palette.fg2, modifier = Modifier.padding(start = 12.dp).size(17.dp))
            }
        }
    }
}

@Composable
private fun TaskDetail(task: TaskSnapshot, onBack: () -> Unit) {
    LazyColumn(Modifier.fillMaxSize().testTag("task_detail"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack, modifier = Modifier.offset(x = (-12).dp).testTag("close_detail")) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "뒤로") }
                Text("기록", fontSize = 21.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.01).em, modifier = Modifier.weight(1f))
                StatusPill(task.statusLabel, stateColor(task.state), modifier = Modifier.testTag("task_status"))
            }
        }
        item {
            Text(task.request.ifBlank { "테스트 앱 제어" }, fontSize = 24.sp, fontWeight = FontWeight.Medium, lineHeight = 30.sp, letterSpacing = (-0.01).em)
            Spacer(Modifier.height(10.dp))
            Text(timeLabel(task.createdAt), color = palette.fg2, fontSize = 12.sp, style = Tabular)
        }
        item {
            SurfaceCard {
                TaskProgress(task)
                if (task.state == "waiting_approval") ApprovalContent(task)
                else {
                    Text(task.summary.ifBlank { task.events.lastOrNull()?.message ?: "준비 중" }, fontSize = 14.sp, lineHeight = 21.sp)
                }
            }
        }
        task.screenshotPath?.let { path -> item { EvidenceCard(path) } }
        item { SectionLabel("진행", "이벤트 ${task.events.size}개") }
        if (task.events.isEmpty()) item { Text("이벤트 없음", color = palette.fg2, fontSize = 14.sp) }
        items(task.events, key = { it.id }) { event ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.padding(top = 6.dp).size(8.dp).clip(CircleShape).background(if (event.type.contains("fail")) palette.bad else palette.fg2))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(event.message.ifEmpty { event.type }, fontSize = 14.sp, lineHeight = 21.sp)
                    Text(timeLabel(event.time, short = true), color = palette.fg2, fontSize = 11.sp, style = Tabular)
                    Spacer(Modifier.height(10.dp))
                    HorizontalDivider(color = palette.line)
                }
            }
        }
    }
}

@Composable
private fun EvidenceCard(path: String) {
    var result by remember(path) { mutableStateOf<Pair<Boolean, android.graphics.Bitmap?>>(false to null) }
    LaunchedEffect(path) {
        val loadedBitmap = withContext(Dispatchers.IO) { runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val options = BitmapFactory.Options().apply { inSampleSize = if (bounds.outHeight > 2400) 2 else 1 }
            BitmapFactory.decodeFile(path, options)
        }.getOrNull() }
        result = Pair(true, loadedBitmap)
    }
    val bitmap = result.second
    SurfaceCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Image, null, tint = palette.fg2, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("화면 증빙", fontSize = 16.sp, fontWeight = FontWeight.Medium)
        }
        Text("기기 캡처", color = palette.fg2, fontSize = 12.sp)
        if (bitmap != null) {
            Image(bitmap.asImageBitmap(), "화면 증빙", contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth().heightIn(max = 540.dp).clip(RoundedCornerShape(12.dp)).background(palette.surface2))
        } else Text(if (result.first) "불러오기 실패" else "불러오는 중", color = palette.fg2, fontSize = 12.sp)
    }
}

@Composable
internal fun WorkbenchSettings(snapshot: WorkbenchSnapshot, onPermission: () -> Unit, onControlApps: () -> Unit, context: Context) {
    var revealPairing by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    val token = remember(revealPairing) { if (revealPairing) BridgeSession.token(context) else "" }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { AppHeader("설정", "권한") }
        item {
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.TouchApp, null, tint = palette.fg2, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(10.dp))
                    Text("화면 제어", fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                    StatusPill(if (snapshot.connected) "연결됨" else "연결 필요", if (snapshot.connected) palette.accentFg else palette.fg2)
                }
                Text("접근성 설정에서 뽀미 켜기 · 실행 중 패널에서 중지", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
                OutlinedButton(onClick = onPermission, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) { Text("접근성 설정") }
                OutlinedButton(onClick = onControlApps, enabled = !snapshot.chatControl && snapshot.active == null,
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp)) { Text("제어 앱 선택") }
            }
        }
        item {
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Cable, null, tint = palette.fg2, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(10.dp))
                    Text("로컬 MCP", fontSize = 16.sp, fontWeight = FontWeight.Medium)
                }
                Text("같은 폰 에이전트 앱 · Mac", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
                Text("http://127.0.0.1:8765/mcp", color = palette.fg2, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                TextButton(onClick = { revealPairing = !revealPairing; copied = false }) {
                    Icon(if (revealPairing) Icons.Outlined.VisibilityOff else Icons.Outlined.Link, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp)); Text(if (revealPairing) "키 숨기기" else "연결 키")
                }
                if (revealPairing) {
                    Text(token, fontSize = 12.sp, lineHeight = 18.sp, fontFamily = FontFamily.Monospace,
                        modifier = Modifier.fillMaxWidth().background(palette.surface2, RoundedCornerShape(10.dp)).padding(12.dp))
                    OutlinedButton(onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = ClipData.newPlainText("Ppomi local pairing", token)
                        if (android.os.Build.VERSION.SDK_INT >= 33) clip.description.extras = android.os.PersistableBundle().apply {
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        clipboard.setPrimaryClip(clip); copied = true
                    }, modifier = Modifier.fillMaxWidth()) { Text(if (copied) "복사됨" else "복사") }
                }
            }
        }
        item { Text("뽀미 · Android", color = palette.fg2, fontSize = 12.sp, lineHeight = 18.sp, modifier = Modifier.padding(2.dp)) }
    }
}

@Composable
private fun SharedScreen(snapshot: WorkbenchSnapshot, onRefresh: () -> Unit, onStart: (String) -> Unit,
                         onOpenTask: (String) -> Unit) {
    val shared = snapshot.shared
    LazyColumn(Modifier.fillMaxSize().testTag("shared_screen"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { AppHeader("공유", "서버 · 기기") }
        item {
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(shared.workspaceName.ifBlank { "공유 서버" }, fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                    StatusPill(if (!shared.configured) "미연결" else if (shared.online) "연결됨" else "확인 필요",
                        if (shared.online) palette.accentFg else palette.fg2, modifier = Modifier.testTag("shared_connection"))
                }
                if (shared.deviceName.isNotBlank()) Text("이 기기 · ${shared.deviceName}", fontSize = 14.sp)
                if (shared.devices.isNotEmpty()) Text("기기 · ${shared.devices.joinToString(" · ")}", color = palette.fg2, fontSize = 12.sp)
                if (shared.lastUpdated.isNotBlank()) Text("확인 · ${timeLabel(shared.lastUpdated)}${if (shared.online) "" else " · 저장됨"}", color = palette.fg2, fontSize = 11.sp, style = Tabular)
                if (shared.error.isNotBlank()) Text(shared.error, color = palette.bad, fontSize = 12.sp, lineHeight = 18.sp, modifier = Modifier.testTag("shared_error"))
                if (shared.configured) OutlinedButton(onClick = onRefresh, enabled = !shared.busy,
                    modifier = Modifier.fillMaxWidth().testTag("refresh_shared")) { Text(if (shared.busy) "확인 중" else "새로고침") }
                else Text("Android 구글 로그인은 아직 지원하지 않습니다.", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
            }
        }
        if (shared.configured && shared.runs.isEmpty()) item {
            Text("공유 작업 없음", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
        }
        if (shared.documents.isNotEmpty()) item { SectionLabel("규칙 · 절차", "읽기 전용") }
        items(shared.documents, key = { "document_" + it.id }) { document ->
            var expanded by rememberSaveable(document.id) { mutableStateOf(false) }
            SurfaceCard {
                Text(document.title, fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.testTag("shared_document_${document.id}"))
                Text("${if (document.kind == "rule") "규칙" else "절차"} · 버전 ${document.version}${if (document.archived) " · 보관됨" else ""}", color = palette.fg2, fontSize = 11.sp, style = Tabular)
                TextButton(onClick = { expanded = !expanded }, modifier = Modifier.testTag("open_shared_document_${document.id}")) { Text(if (expanded) "접기" else "내용") }
                if (expanded) {
                    Text(document.body.take(12000), color = palette.fg2, fontSize = 12.sp, lineHeight = 18.sp,
                        modifier = Modifier.testTag("shared_document_body_${document.id}"))
                    if (document.body.length > 12000) Text("앞 12,000자", color = palette.fg2, fontSize = 11.sp)
                }
            }
        }
        if (shared.runs.isNotEmpty()) item { SectionLabel("배정", "서버 기준") }
        items(shared.runs, key = { it.id }) { run ->
            SurfaceCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (run.executorId == shared.deviceId) "이 기기" else "다른 기기", color = palette.fg2, fontSize = 11.sp, modifier = Modifier.weight(1f))
                    StatusPill(sharedStateLabel(run.state), stateColor(run.state), modifier = Modifier.testTag("shared_state_${run.id}"))
                }
                Text(run.request, fontSize = 16.sp, fontWeight = FontWeight.Medium, lineHeight = 24.sp)
                Text("버전 ${run.version}", color = palette.fg2, fontSize = 11.sp, style = Tabular)
                if (run.summary.isNotBlank()) Text(run.summary, color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
                if (run.pending > 0) Text("기기 ${sharedStateLabel(run.localState)} · 전송 대기 ${run.pending}", color = palette.fg2, fontSize = 12.sp, style = Tabular)
                if (run.error.isNotBlank()) Text("전송 보류 · ${run.error}", color = palette.bad, fontSize = 12.sp, lineHeight = 18.sp)
                if (run.state == "queued" && run.executorId == shared.deviceId && !run.hasLocalRecord) {
                    Text("내장 절차 실행 · 입력 전 승인", color = palette.fg2, fontSize = 12.sp, lineHeight = 18.sp)
                    Button(onClick = { onStart(run.id) }, colors = accentButton, enabled = shared.online && !shared.busy && snapshot.connected && snapshot.active == null,
                        modifier = Modifier.fillMaxWidth().testTag("start_shared_${run.id}")) { Text("실행") }
                }
                if (run.hasLocalRecord) TextButton(onClick = { onOpenTask(run.id) }, modifier = Modifier.testTag("open_shared_${run.id}")) { Text("기록") }
            }
        }
    }
}

private fun sharedStateLabel(state: String) = when (state) {
    "queued" -> "대기"
    "running" -> "실행"
    "waiting_approval" -> "승인 대기"
    "completed" -> "완료"
    "failed" -> "실패"
    "cancelled" -> "중단"
    "interrupted" -> "끊김"
    else -> state
}

@Composable
private fun SurfaceCard(borderColor: Color = palette.line, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth(), shape = Corners, color = palette.surface, border = androidx.compose.foundation.BorderStroke(1.dp, borderColor)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(13.dp), content = content)
    }
}
@Composable
private fun AppHeader(title: String, subtitle: String) {
    Column(Modifier.fillMaxWidth().padding(top = 5.dp, bottom = 3.dp), verticalArrangement = Arrangement.spacedBy(11.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(30.dp).clip(RoundedCornerShape(10.dp)).background(palette.fg), contentAlignment = Alignment.Center) {
                Text("뽀", color = palette.bg, fontWeight = FontWeight.Medium, fontSize = 16.sp)
            }
            Spacer(Modifier.width(9.dp))
            Text("뽀미", color = palette.fg2, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f)); Text("ANDROID", color = palette.fg2, fontSize = 11.sp)
        }
        Text(title, color = palette.fg, fontSize = 24.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.01).em)
        Text(subtitle, color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
    }
}
@Composable
private fun StatusPill(label: String, color: Color, icon: ImageVector? = null, modifier: Modifier = Modifier) {
    Row(modifier.clip(CircleShape).background(palette.surface2).border(1.dp, palette.line, CircleShape).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        if (icon != null) Icon(icon, null, tint = color, modifier = Modifier.size(13.dp))
        else Box(Modifier.size(5.dp).clip(CircleShape).background(color))
        Text(label, color = palette.fg2, fontSize = 11.sp, fontWeight = FontWeight.Medium)
    }
}
@Composable
private fun Metric(label: String, count: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(17.dp)).background(palette.surface).border(1.dp, palette.line, RoundedCornerShape(17.dp)).padding(15.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(label, fontSize = 11.sp, color = palette.fg2)
        Text(count, fontSize = 24.sp, color = palette.fg, fontWeight = FontWeight.Medium, letterSpacing = (-0.01).em, style = Tabular)
    }
}
@Composable
private fun SectionLabel(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium)
        Text(subtitle, color = palette.fg2, fontSize = 12.sp, style = Tabular)
    }
}
@Composable
private fun stateColor(state: String) = when (state) {
    "completed" -> palette.accentFg
    "failed", "interrupted" -> palette.bad
    "running" -> palette.go
    "waiting_approval" -> palette.turn
    else -> palette.wait
}
private fun timeLabel(raw: String, short: Boolean = false): String = runCatching {
    DateTimeFormatter.ofPattern(if (short) "HH:mm:ss" else "M월 d일 · HH:mm")
        .withZone(ZoneId.systemDefault()).format(Instant.parse(raw))
}.getOrElse { raw.take(19).replace('T', ' ') }
