package com.example.heartsync.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

import com.example.heartsync.ui.screens.model.NotiLogRow
import com.example.heartsync.ui.screens.model.localTimeStr
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.width

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun NotiLogScreen() {
    val vm: NotiLogViewModel = androidx.lifecycle.viewmodel.compose.viewModel(
        factory = notiLogViewModelFactory()
    )
    NotiLogScreen(vm = vm)
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun NotiLogScreen(vm: NotiLogViewModel) {
    val rows    by vm.rows.collectAsState()
    val header  by vm.headerText.collectAsState()
    val loading by vm.loading.collectAsState()
    val selDate by vm.selectedDate.collectAsState()

    var showPicker by remember { mutableStateOf(false) }


    val hScroll = rememberScrollState()

    Scaffold(
        topBar = {
            // ✅ SmallTopAppBar 대신 CenterAlignedTopAppBar 사용
            CenterAlignedTopAppBar(
                title = { Text("이상 로그 알림") },
                actions = {
                    TextButton(onClick = { showPicker = true }) {
                        Text(selDate.format(DateTimeFormatter.ISO_DATE))
                    }
                },
                windowInsets = WindowInsets(0.dp)

            )
        }
    ) { inner ->
        Column(Modifier.padding(inner).padding(top = 0.dp) ) {
            if (loading) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }

            Text(
                text = header,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp)
            )

            // 가로 스크롤 컨테이너
            Column(
                Modifier
                    .fillMaxSize()
                    .horizontalScroll(hScroll)   // ← 가로 스크롤 가능
            ) {
                // 각 컬럼의 고정 폭(dp) — 필요하면 숫자 조절
                val wTime = 90.dp
                val wSide = 80.dp
                val wReasons = 320.dp
                val wAuspr = 100.dp
                val wPwtt = 90.dp
                val wHsi = 100.dp

                // ==== 헤더 ====
                Row(
                    Modifier
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text("시각",    Modifier.width(wTime),   style = MaterialTheme.typography.labelLarge)
                    Text("side",    Modifier.width(wSide),   style = MaterialTheme.typography.labelLarge)
                    Text("reasons", Modifier.width(wReasons),style = MaterialTheme.typography.labelLarge)
                    Text("AUSPR (ratio)",Modifier.width(wAuspr),    style = MaterialTheme.typography.labelLarge)
                    Text("PWTT (ms)", Modifier.width(wPwtt),    style = MaterialTheme.typography.labelLarge)
                    Text("HSI",Modifier.width(wHsi),   style = MaterialTheme.typography.labelLarge)
                }
                HorizontalDivider()

                if (!loading && rows.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(top = 8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "선택한 날짜에 이상 알림이 없습니다",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else {
                    // ==== 리스트 ====
                    LazyColumn(
                        modifier = Modifier.fillMaxHeight(),
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(rows, key = { it.id }) { r ->
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    r.localTimeStr(ZoneId.of("Asia/Seoul")),
                                    Modifier.width(wTime),
                                    maxLines = 1,
                                    overflow = TextOverflow.Clip
                                )
                                Text(
                                    r.side ?: "-",
                                    Modifier.width(wSide),
                                    maxLines = 1,
                                    overflow = TextOverflow.Clip
                                )
                                // 교체 (줄바꿈 + 불릿)
                                val reasonsText = r.reasons
                                    ?.joinToString(separator = "\n") { reason ->
                                        "• " + translateReason(
                                            reason
                                        )
                                    }
                                    ?: "-"

                                Text(
                                    text = reasonsText,
                                    modifier = Modifier.width(wReasons),
                                    maxLines = 5,            // 필요하면 늘리거나 없애기
                                    softWrap = true,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Text(r.auspr?.let { "%.2f".format(it) } ?: "-",
                                    Modifier.width(wAuspr))
                                Text(r.pwttMs?.let { "%.0f".format(it) } ?: "-",
                                    Modifier.width(wPwtt))
                                Text(r.hsi?.let { "%.2f".format(it) } ?: "-",
                                    Modifier.width(wHsi))
                            }
                            HorizontalDivider()
                        }
                    }
                }
            }
        }
    }

    if (showPicker) {
        val zone = ZoneId.systemDefault()
        val initMillis = selDate.atStartOfDay(zone).toInstant().toEpochMilli()
        val dateState = rememberDatePickerState(initialSelectedDateMillis = initMillis)

        DatePickerDialog(
            onDismissRequest = { showPicker = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        val millis = dateState.selectedDateMillis
                        if (millis != null) {
                            val picked = java.time.Instant.ofEpochMilli(millis).atZone(zone).toLocalDate()
                            vm.setDate(picked)
                        }
                        showPicker = false
                    }
                ) { Text("확인") }
            },
            dismissButton = {
                TextButton(onClick = { showPicker = false }) { Text("취소") }
            }
        ) {
            DatePicker(state = dateState)
        }
    }
}

/**
 * 간단한 커스텀 DatePicker 대용(Compose Material3 기본 DatePickerState 버전차 회피용)
 */
@Composable
private fun DatePickerSheet(
    initial: LocalDate,
    onPicked: (LocalDate) -> Unit
) {
    var year by remember { mutableStateOf(initial.year) }
    var month by remember { mutableStateOf(initial.monthValue) }
    var day by remember { mutableStateOf(initial.dayOfMonth) }

    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("날짜 선택", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(
            value = year.toString(),
            onValueChange = { it.toIntOrNull()?.let { y -> if (y in 2000..2100) year = y } },
            label = { Text("연(YYYY)") }
        )
        OutlinedTextField(
            value = month.toString(),
            onValueChange = { it.toIntOrNull()?.let { m -> if (m in 1..12) month = m } },
            label = { Text("월(MM)") }
        )
        OutlinedTextField(
            value = day.toString(),
            onValueChange = { it.toIntOrNull()?.let { d -> if (d in 1..31) day = d } },
            label = { Text("일(DD)") }
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Button(onClick = {
                runCatching { LocalDate.of(year, month, day) }.getOrNull()?.let(onPicked)
            }) { Text("확인") }
        }
    }
}
// 영어 reasons → 한글 표시용 변환
private fun translateReason(reason: String): String = when (reason) {
    "AUSPR out-of-range" -> "AUSPR 범위 이탈"
    "PWTT high"          -> "PWTT 증가"
    "HSI high"           -> "HSI 증가"
    else -> reason
}
