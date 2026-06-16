// app/src/main/java/com/example/heartsync/ui/screens/DataVizScreen.kt
package com.example.heartsync.ui.screens

import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.heartsync.ui.DataBizViewModel
import com.example.heartsync.ui.model.DayMetrics
import com.example.heartsync.ui.model.MetricStat
import com.google.firebase.auth.FirebaseAuth
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DataVizScreen(
    deviceId: String, // 기존 파라미터 유지
    vm: DataBizViewModel = viewModel(),
    uid: String? = null,
) {
    // 날짜/다이얼로그 상태
    var showPicker by remember { mutableStateOf(false) }
    var selectedDate by remember { mutableStateOf(LocalDate.now()) }

    // uid 결정: 파라미터 우선, 없으면 FirebaseAuth
    val effectiveUid = remember(uid) {
        uid ?: FirebaseAuth.getInstance().currentUser?.uid
    }

    if (effectiveUid.isNullOrEmpty()) {
        Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("로그인이 필요합니다")
        }
        return
    }

    val seoul = ZoneId.of("Asia/Seoul")
    val df = remember { DateTimeFormatter.ofPattern("yyyy-MM-dd (E)") }
    val pickerState = rememberDatePickerState(
        initialSelectedDateMillis = selectedDate.atStartOfDay(seoul).toInstant().toEpochMilli()
    )

    val dayMetrics by vm.dayMetrics.collectAsState()
    val isLoading by vm.isLoading.collectAsState()
    val fullCount by vm.lastFullCount.collectAsState()

    // 최초/날짜 변경 시: 페이지드 요약(정확 합계)
    LaunchedEffect(effectiveUid, selectedDate) {
        vm.refreshDaySummaryPaged(
            uid = effectiveUid,
            date = selectedDate,
            zone = seoul,
            pageSize = 3000L,
            force = true
        )
    }

    // 실시간 스냅샷 리스너
    LaunchedEffect(effectiveUid, selectedDate) {
        Log.d("DataViz", "startListenDayMetrics uid=$effectiveUid date=$selectedDate")
        vm.startListenDayMetrics(
            uid = effectiveUid,
            date = selectedDate,
            zone = seoul
        )
    }
    DisposableEffect(Unit) { onDispose { vm.stopAll() } }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("날짜별 통계", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            TextButton(onClick = { showPicker = true }) { Text(selectedDate.format(df)) }
        }

        // 날짜 전/후 이동
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = { selectedDate = selectedDate.minusDays(1) },
                modifier = Modifier.weight(1f)
            ) { Text("이전 날") }
            OutlinedButton(
                onClick = { selectedDate = selectedDate.plusDays(1) },
                modifier = Modifier.weight(1f)
            ) { Text("다음 날") }
        }

        Spacer(Modifier.height(12.dp))

        // 로딩바 & 총 표본수
        if (isLoading) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
        }
        if (fullCount > 0 && !isLoading) {
            Text("총 ${fullCount}개 기준", style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(8.dp))
        }

        MetricsRow(metrics = dayMetrics)
        Spacer(Modifier.height(8.dp))
        AssistChipRow(metrics = dayMetrics)
    }

    // 날짜 선택 다이얼로그 (단일 인스턴스)
    if (showPicker) {
        DatePickerDialog(
            onDismissRequest = { showPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { millis ->
                        selectedDate = Instant.ofEpochMilli(millis).atZone(seoul).toLocalDate()
                    }
                    showPicker = false
                }) { Text("선택") }
            },
            dismissButton = {
                TextButton(onClick = { showPicker = false }) { Text("취소") }
            }
        ) {
            DatePicker(state = pickerState)
        }
    }
}

@Composable
private fun MetricsRow(metrics: DayMetrics?) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        contentPadding = PaddingValues(vertical = 4.dp)
    ) {
        item { StatCard("AUSPR (ratio)", metrics?.auspr) }
        item { StatCard("PWTT (ms)",     metrics?.pwttMs) }
        item { StatCard("HSI",           metrics?.hsi) }
    }
}

@Composable
private fun StatCard(title: String, m: MetricStat?, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(12.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            if (m == null || m.count == 0) {
                Text("데이터 없음", style = MaterialTheme.typography.bodyMedium)
            } else {
                Text("평균: ${m.avg.format(2)}")
                Text("최고: ${m.max.format(2)}")
                Text("최저: ${m.min.format(2)}")
            }
        }
    }
}

@Composable
private fun AssistChipRow(metrics: DayMetrics?) {
    val totalN = metrics?.auspr?.count ?: 0
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        AssistChip(
            onClick = {},
            label = { Text("총 표본 수: $totalN") }
        )
    }
}

private fun Double.format(digits: Int): String =
    "%.${digits}f".format(this)
