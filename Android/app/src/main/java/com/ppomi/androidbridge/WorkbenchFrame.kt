package com.ppomi.androidbridge

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlin.math.min

/** The same chat occupies the cover screen and the right of an unfolded window. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
internal fun WorkbenchFrame(
    topBar: @Composable () -> Unit,
    conversation: @Composable () -> Unit,
    contentPane: @Composable () -> Unit,
    contentPresented: Boolean,
    onContentPresentedChange: (Boolean) -> Unit,
    onContentVisibilityChange: (Boolean) -> Unit,
    contentActionLabel: String = "기록",
    modifier: Modifier = Modifier
) {
    BoxWithConstraints(modifier) {
        val compact = maxWidth < 600.dp
        var previousCompact by rememberSaveable { mutableStateOf(compact) }
        LaunchedEffect(compact) {
            if (previousCompact != compact) onContentPresentedChange(false)
            previousCompact = compact
        }
        LaunchedEffect(compact, contentPresented) { onContentVisibilityChange(!compact || contentPresented) }
        Layout(modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }.testTag("workbench_frame"), content = {
            Row(Modifier.testTag("workbench_top_bar").semantics { contentDescription = "앱" }) {
                Box(Modifier.weight(1f)) { topBar() }
                if (compact) TextButton(onClick = { onContentPresentedChange(true) }, modifier = Modifier.testTag("open_content")) {
                    Text(contentActionLabel)
                }
            }
            Box(Modifier.testTag("workbench_chat").semantics { contentDescription = "대화" }) { conversation() }
            Box(Modifier.testTag("workbench_content").semantics { contentDescription = "기록 및 작업" }) {
                if (!compact) contentPane()
                else if (contentPresented) Dialog(onDismissRequest = { onContentPresentedChange(false) },
                    properties = DialogProperties(usePlatformDefaultWidth = false)) {
                    Column(Modifier.fillMaxSize().background(palette.bg).semantics { testTagsAsResourceId = true }
                        .testTag("workbench_content_sheet")) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            TextButton(onClick = { onContentPresentedChange(false) }, modifier = Modifier.testTag("close_content")) { Text("대화로 돌아가기") }
                        }
                        Box(Modifier.weight(1f).fillMaxWidth()) { contentPane() }
                    }
                }
            }
        }) { children, constraints ->
            val width = constraints.maxWidth
            val height = constraints.maxHeight
            val top = children[0].measure(Constraints(minWidth = width, maxWidth = width, maxHeight = height))
            val remaining = (height - top.height).coerceAtLeast(0)
            val chatWidth = if (compact) width else min(412.dp.roundToPx(), (width * 0.45f).toInt())
            val chat = children[1].measure(Constraints.fixed(chatWidth, remaining))
            val content = children[2].measure(Constraints.fixed(if (compact) 0 else width - chatWidth, if (compact) 0 else remaining))
            layout(width, height) {
                top.place(0, 0)
                chat.place(width - chatWidth, top.height)
                if (!compact) content.place(0, top.height)
            }
        }
    }
}
