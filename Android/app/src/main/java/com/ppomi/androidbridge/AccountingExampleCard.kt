package com.ppomi.androidbridge

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger

/** Explicit, read-only synthetic archive; all validation and balances come from Swift. */
@Composable
internal fun AccountingExampleCard() {
    val context = LocalContext.current
    val coroutine = rememberCoroutineScope()
    var report by remember { mutableStateOf<JSONObject?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var selectedBookId by remember { mutableStateOf<String?>(null) }
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(22.dp), color = palette.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, palette.line)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
            Text("공통 분개장", fontSize = 16.sp, fontWeight = FontWeight.Medium)
            Text("가상 예시 · 읽기 전용", color = palette.fg2, fontSize = 12.sp)
            Text("Mac 공통 엔진 · 장부 저장 없음", color = palette.fg2, fontSize = 14.sp, lineHeight = 21.sp)
            if (report == null) {
                OutlinedButton(onClick = {
                    loading = true; error = null
                    coroutine.launch {
                        try {
                            val result = withContext(Dispatchers.IO) {
                                val input = context.assets.open("accounting-example.json").bufferedReader().use { it.readText() }
                                JSONObject(SharedAccounting.report(input))
                            }
                            if (!result.optBoolean("ok")) error = result.optString("error", "검증 실패")
                            else report = result
                        } catch (cancelled: CancellationException) { throw cancelled }
                        catch (failure: Throwable) { error = "엔진 오류 ${failure.message.orEmpty().take(160)}" }
                        finally { loading = false }
                    }
                }, enabled = !loading, modifier = Modifier.fillMaxWidth().testTag("accounting_demo")) {
                    if (loading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    else Text("예시")
                }
            }
            error?.let { Text(it, color = palette.bad, fontSize = 12.sp) }
            report?.let { data ->
                val books = data.optJSONArray("books")?.objects().orEmpty()
                val selected = books.firstOrNull { it.optJSONObject("book")?.optString("id") == selectedBookId } ?: books.firstOrNull { (it.optJSONArray("accounts")?.length() ?: 0) > 0 } ?: books.firstOrNull()
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    books.forEach { item ->
                        val book = item.getJSONObject("book")
                        FilterChip(selected = item == selected, onClick = { selectedBookId = book.getString("id") },
                            label = { Text(book.optString("name"), fontSize = 11.sp) })
                    }
                }
                selected?.let { selectedReport ->
                    val book = selectedReport.getJSONObject("book")
                    val scope = selectedReport.getJSONObject("scope")
                    val unit = book.getJSONObject("unit")
                    val scopeLabel = when (scope.optString("kind")) { "personal" -> "개인"; "business" -> "사업"; else -> "미분류" }
                    Column(Modifier.testTag("accounting_report"), verticalArrangement = Arrangement.spacedBy(11.dp)) {
                        Text("$scopeLabel · ${scope.optString("ownerID")} · ${unit.optString("name")}",
                            color = palette.fg2, fontSize = 11.sp, lineHeight = 16.5.sp)
                        if (scope.optString("kind") == "business") Text("사업 ID · ${scope.optString("businessID")}",
                            color = palette.fg2, fontSize = 11.sp)
                        Row(Modifier.fillMaxWidth()) {
                            Text("계정", fontSize = 11.sp, modifier = Modifier.weight(1f))
                            Text("원본", fontSize = 11.sp, modifier = Modifier.width(76.dp))
                            Text("평가 포함", fontSize = 11.sp, modifier = Modifier.width(76.dp))
                        }
                        HorizontalDivider(color = palette.line)
                        selectedReport.getJSONArray("accounts").objects().forEach { account ->
                            val id = account.getString("id")
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(account.optString("name"), fontSize = 12.sp, modifier = Modifier.weight(1f))
                                Text(formatMinor(selectedReport.getJSONObject("recordedBalances").optString(id, "0"), unit),
                                    fontSize = 11.sp, style = Tabular, modifier = Modifier.width(76.dp))
                                Text(formatMinor(selectedReport.getJSONObject("adjustedBalances").optString(id, "0"), unit),
                                    fontSize = 11.sp, style = Tabular, modifier = Modifier.width(76.dp))
                            }
                        }
                        Text("Swift 공통 엔진", color = palette.fg2, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}
private fun formatMinor(value: String, unit: JSONObject): String = runCatching {
    BigDecimal(BigInteger(value), unit.optInt("scale")).toPlainString() + " " + unit.optString("symbol")
}.getOrElse { value }
