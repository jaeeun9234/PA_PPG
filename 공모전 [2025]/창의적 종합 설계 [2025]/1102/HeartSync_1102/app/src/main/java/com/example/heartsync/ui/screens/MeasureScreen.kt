package com.example.heartsync.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.*

@Composable
fun MeasureScreen(
    onFinish: () -> Unit,            // "측정 종료" 클릭 시 호출 (Nav로 Home 이동)
    isConnected: Boolean = true,     // 연결 상태 표시용(원하면 ViewModel 값 바인딩)
    deviceName: String? = null       // 연결 기기명 표시용(선택)
) {
    val today = rememberDateText()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        // 날짜 칩
        AssistChip(
            onClick = {},
            label = { Text(today) }
        )

        Spacer(Modifier.height(16.dp))

        // 연결 상태 카드
        ElevatedCard(Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier.padding(20.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Rounded.CheckCircle,
                    contentDescription = "connected",
                    tint = MaterialTheme.colorScheme.primary
                )
                Spacer(Modifier.width(10.dp))
                val connectedText =
                    if (isConnected) "기기가 연결되어 있습니다."
                    else "기기가 연결되지 않았습니다."
                val nameSuffix = deviceName?.let { " ($it)" } ?: ""
                Text(
                    text = connectedText + nameSuffix,
                    style = MaterialTheme.typography.titleMedium
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        // 안내/진행 카드
        ElevatedCard(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                // 상단 아이콘 + 안내문
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = Icons.Outlined.Notifications,
                        contentDescription = "notice"
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "측정 중에는\n손가락과 손을\n움직이지 말고\n가만히 유지해주세요",
                        style = MaterialTheme.typography.titleLarge,
                        textAlign = TextAlign.Center
                    )
                }

                // 로딩 인디케이터
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "측정 중지",
                        style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.align(Alignment.CenterHorizontally)
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // 측정 종료 버튼
        Button(
            onClick = onFinish,
            modifier = Modifier
                .fillMaxWidth()
                .height(52.dp)
        ) {
            Text("측정 종료")
        }
    }
}

@Composable
private fun rememberDateText(): String {
    val sdf = SimpleDateFormat("yyyy/MM/dd", Locale.KOREA)
    return sdf.format(Date())
}

@Preview(showBackground = true)
@Composable
private fun PreviewMeasureScreen() {
    MaterialTheme {
        MeasureScreen(
            onFinish = {},
            isConnected = true,
            deviceName = "HeartSync-PPG"
        )
    }
}
