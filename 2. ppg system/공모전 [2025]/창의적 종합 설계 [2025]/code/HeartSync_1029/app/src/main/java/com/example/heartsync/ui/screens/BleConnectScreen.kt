// app/src/main/java/com/example/heartsync/ui/screens/BleConnectScreen.kt
package com.example.heartsync.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.example.heartsync.ble.PpgBleClient
import com.example.heartsync.data.model.BleDevice
import com.example.heartsync.ui.components.StatusCard
import com.example.heartsync.viewmodel.BleViewModel

@Composable
fun BleConnectScreen(
    vm: BleViewModel,
    onConnected: (() -> Unit)? = null
) {
    val scanning by vm.scanning.collectAsState()
    val results by vm.scanResults.collectAsState()
    val conn by vm.connectionState.collectAsState()

    // ✅ 연결 성공 시: 서비스 시작 → 콜백
    LaunchedEffect(conn) {
        if (conn is PpgBleClient.ConnectionState.Connected) {
            val d = (conn as PpgBleClient.ConnectionState.Connected).device
            vm.startMeasure(d)             // ★ 측정 서비스 기동
            onConnected?.invoke()          // ★ 화면 복귀(또는 이동)
        }
    }

    // 권한 런처
    val requiredPerms = remember {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            list += Manifest.permission.BLUETOOTH_SCAN
            list += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            list += Manifest.permission.ACCESS_FINE_LOCATION
        }
        list.toTypedArray()
    }
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* no-op */ }

    var selected by remember { mutableStateOf<BleDevice?>(null) }

    Scaffold(
        contentWindowInsets = WindowInsets(0)
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text("BLE 장치 연결", style = MaterialTheme.typography.headlineSmall)

            when (conn) {
                is PpgBleClient.ConnectionState.Connected -> {
                    StatusCard(
                        icon = "success",
                        title = "연결된 기기: ${(conn as PpgBleClient.ConnectionState.Connected).device.name ?: "Unknown"}",
                        buttonText = "연결 해제",
                        onClick = { vm.disconnect() }
                    )
                    Spacer(Modifier.weight(1f))
                }

                is PpgBleClient.ConnectionState.Connecting -> {
                    StatusCard(
                        icon = "error",
                        title = "연결 중…",
                        buttonText = "취소",
                        onClick = { vm.disconnect() }
                    )
                    Spacer(Modifier.weight(1f))
                }

                is PpgBleClient.ConnectionState.Disconnected,
                is PpgBleClient.ConnectionState.Failed -> {
                    StatusCard(
                        icon = "error",
                        title = if (conn is PpgBleClient.ConnectionState.Failed)
                            "연결 실패: ${(conn as PpgBleClient.ConnectionState.Failed).reason}"
                        else
                            "연결된 기기가 없습니다.",
                        buttonText = if (scanning) "스캔 중지" else "스캔 시작",
                        onClick = {
                            if (scanning) vm.stopScan()
                            else {
                                permLauncher.launch(requiredPerms)
                                vm.startScan()
                            }
                        }
                    )

                    if (results.isNotEmpty()) {
                        Text("발견된 장치 (${results.size})", fontWeight = FontWeight.Bold)

                        // ✅ 리스트는 가변영역으로 크게, 아래 버튼은 항상 보이게
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f, fill = true)
                                .heightIn(min = 260.dp) // ★ 보너스: 최소 높이 확보
                        ) {
                            DeviceRadioList(
                                items = results,
                                selected = selected,
                                onSelected = { dev -> selected = dev }
                            )
                        }
                    } else {
                        // 결과 없을 때도 아래 버튼이 보이도록 빈 공간을 차지
                        Spacer(Modifier.weight(1f))
                    }

                    Button(
                        onClick = { selected?.let(vm::connect) },
                        enabled = selected != null,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(48.dp)
                            .imePadding()
                    ) {
                        Text(if (selected != null) "연결하기" else "기기 선택 후 연결")
                    }
                }
            }
        }
    }
}

/** 스캔 결과 리스트(라디오 선택) */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DeviceRadioList(
    items: List<BleDevice>,
    selected: BleDevice?,
    onSelected: (BleDevice) -> Unit
) {
    Surface(tonalElevation = 1.dp, shape = MaterialTheme.shapes.medium) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 6.dp, vertical = 4.dp),
            contentPadding = PaddingValues(bottom = 8.dp)
        ) {
            stickyHeader {
                Surface(color = MaterialTheme.colorScheme.surface) {
                    Text(
                        "발견된 장치 (${items.size})",
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    )
                }
            }
            items(items, key = { it.address }) { dev ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 48.dp)
                        .clickable { onSelected(dev) }
                        .padding(horizontal = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    RadioButton(
                        selected = selected?.address == dev.address,
                        onClick = { onSelected(dev) }
                    )
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(dev.name ?: "Unknown", style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                        Text(dev.address, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    }
                }
                Divider(thickness = 0.6.dp)
            }
        }
    }
}
