// app/src/main/java/com/example/heartsync/ble/PpgBleClient.kt
package com.example.heartsync.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import com.example.heartsync.data.model.BleDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.*
import java.util.concurrent.LinkedBlockingQueue
import com.example.heartsync.data.remote.PpgRepository
import java.nio.charset.StandardCharsets
import com.example.heartsync.ppg.PpgProcessor
import com.example.heartsync.data.model.PpgEvent   // ← 너희 프로젝트의 데이터클래스
import com.google.firebase.auth.FirebaseAuth


/**
 * HeartSync BLE 클라이언트
 * - GATT 133 회피: 연결 순서 (discover → MTU → CCCD)
 */
class PpgBleClient(
    private val ctx: Context,
    private val onLine: (String) -> Unit = {},
    private val onError: (String) -> Unit = {},
    private val filterByService: Boolean = false
) {
    // ===== UUID =====
    private val serviceUuid: UUID = UUID.fromString("5ba7a52c-c3fe-46eb-8ade-0dacbd466278")
    private val notifyCharUuids = listOf(
        UUID.fromString("5dde726d-4cf3-4e2f-ab24-323caa359b78")
    )
    private val cccdUuid: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private val repoScope = CoroutineScope(Dispatchers.IO)

    // ===== UI State =====
    sealed interface ConnectionState {
        data object Disconnected : ConnectionState
        data object Connecting : ConnectionState
        data class Connected(val device: BleDevice) : ConnectionState
        data class Failed(val reason: String) : ConnectionState
    }

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _scanResults = MutableStateFlow<List<BleDevice>>(emptyList())
    val scanResults: StateFlow<List<BleDevice>> = _scanResults.asStateFlow()

    private val _connectionState =
        MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    // ===== BLE handles =====
    private val btManager get() =
        ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val btAdapter: BluetoothAdapter? get() = btManager.adapter
    private val scanner: BluetoothLeScanner? get() = btAdapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    private val descriptorQueue = LinkedBlockingQueue<BluetoothGattDescriptor>()
    private var scanCallback: ScanCallback? = null

    private val processor = PpgProcessor.instance
    private val repo = PpgRepository.default()


    // 라인 프레이머 (Notify 조각 -> 개행 단위)
    private val lineBuf = StringBuilder()
    private fun StringBuilder.indexOfAny(chars: CharArray): Int {
        for (i in 0 until this.length) {
            val c = this[i]
            for (t in chars) if (c == t) return i
        }
        return -1
    }

    // 정규식 없이 key=value 숫자 파싱 (음수/소수 지원)
    private fun parseNumKV(src: String, key: String): Double? {
        val k = "$key="
        val start = src.indexOf(k)
        if (start < 0) return null
        var i = start + k.length
        if (i >= src.length) return null
        val sb = StringBuilder()
        while (i < src.length) {
            val ch = src[i]
            if (ch == '-' || ch == '.' || (ch in '0'..'9')) {
                sb.append(ch)
                i++
            } else break
        }
        return sb.toString().toDoubleOrNull()
    }

    private fun feedBytesAndEmitLines(bytes: ByteArray) {
        val s = try { String(bytes, StandardCharsets.UTF_8) } catch (_: Exception) { return }
        lineBuf.append(s)

        val delims = charArrayOf('\n', '\r')
        while (true) {
            val idx = lineBuf.indexOfAny(delims)
            if (idx < 0) break

            val oneLine = lineBuf.substring(0, idx).trim()
            lineBuf.delete(0, idx + 1)
            if (oneLine.isEmpty()) continue

            handleOneLine(oneLine)  // ← 라인별 처리를 모두 여기서
        }

        // 개행이 전혀 안 오면 버퍼 과증식 방지
        if (lineBuf.length > 8192) {
            val oneLine = lineBuf.toString().trim()
            lineBuf.clear()
            if (oneLine.isNotEmpty()) {
                handleOneLine(oneLine)  // ← 동일하게 처리
            }
        }
    }

    /** 한 줄 처리: CSV 우선 → 아니면 기존 STAT/ALERT 라인 처리 */
    private fun handleOneLine(oneLine: String) {
        // 1) CSV("timestamp,left,right") 라인이면 앱 내 처리 파이프라인으로
        val parts = oneLine.split(',')
        if (parts.size == 3) {
            val tUs = parts[0].toLongOrNull()
            val l   = parts[1].toIntOrNull()
            val r   = parts[2].toIntOrNull()
            if (tUs != null && l != null && r != null) {
                // (a) 지표 계산용으로 투입 (BPM/SUT/PAD/AmpRatio/UpSlope/PPI 등)
                processor.addSample(tUs, l, r)

                // (b) 실시간 그래프 반영 (절대 시각)
                val abs = System.currentTimeMillis()
                PpgRepository.emitSmoothed(abs, l, r)

                // (c) UI 로그 필요하면 아래 주석 해제
                // onLine(oneLine)
                return
            }
        }

        // 2) CSV가 아니라면: 기존 STAT/ALERT 텍스트 라인 저장(그대로 유지)
        if (oneLine.startsWith("STAT") || oneLine.startsWith("ALERT")) {
            repoScope.launch {
                com.example.heartsync.data.remote.PpgRepository.trySaveFromLine(oneLine)
            }
        }

        // 3) UI 로그 전달(기존 동작 유지)
        onLine(oneLine)
    }

    // 재시도용
    private var targetDevice: BleDevice? = null
    private var backoffMs = 1500

    // ===== Permission helpers =====
    private fun hasScanPerm(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
                ContextCompat.checkSelfPermission(
                    ctx, Manifest.permission.BLUETOOTH_SCAN
                ) == PackageManager.PERMISSION_GRANTED

    private fun hasConnectPerm(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
                ContextCompat.checkSelfPermission(
                    ctx, Manifest.permission.BLUETOOTH_CONNECT
                ) == PackageManager.PERMISSION_GRANTED

    private fun hasLegacyLocation(): Boolean =
        Build.VERSION.SDK_INT < 31 &&
                ContextCompat.checkSelfPermission(
                    ctx, Manifest.permission.ACCESS_FINE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED

    // ===== Scan =====
    @SuppressLint("MissingPermission")
    fun startScan() {
        if (btAdapter?.isEnabled != true) { onError("블루투스가 꺼져 있습니다."); return }
        if (!(hasScanPerm() || hasLegacyLocation())) { onError("스캔 권한이 없습니다."); return }
        if (_scanning.value) return

        _scanResults.value = emptyList()
        _scanning.value = true

        val filters = if (filterByService)
            listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build())
        else null

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val dev = result.device ?: return
                val item = BleDevice(dev.name, dev.address)
                val cur = _scanResults.value
                if (cur.none { it.address == item.address }) {
                    _scanResults.value = cur + item
                }
            }
            override fun onScanFailed(errorCode: Int) {
                _scanning.value = false
                onError("스캔 실패: $errorCode")
            }
        }
        scanner?.startScan(filters, settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        _scanning.value = false
        scanCallback?.let { scanner?.stopScan(it) }
        scanCallback = null
    }

    // ===== Connect / Disconnect =====
    @SuppressLint("MissingPermission")
    fun connect(device: BleDevice) {
        if (!hasConnectPerm()) { onError("연결 권한이 없습니다."); return }
        stopScan()
        targetDevice = device
        _connectionState.value = ConnectionState.Connecting

        val btDev = try {
            BluetoothAdapter.getDefaultAdapter().getRemoteDevice(device.address)
        } catch (_: IllegalArgumentException) {
            _connectionState.value = ConnectionState.Failed("잘못된 MAC 주소"); return
        }

        closeGatt() // 이전 세션 완전 정리
        Log.d("BLE", "connect() to ${device.address}")

        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            btDev.connectGatt(ctx, /*autoConnect*/ false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            btDev.connectGatt(ctx, /*autoConnect*/ false, gattCallback)
        }
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        Log.d("BLE", "disconnect()")
        closeGatt()
        _connectionState.value = ConnectionState.Disconnected
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt() {
        if (!hasConnectPerm()) {
            gatt = null
            return
        }
        try { gatt?.disconnect() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
    }

    private fun refreshDeviceCache(g: BluetoothGatt): Boolean {
        return try {
            val m = g.javaClass.getMethod("refresh")
            m.isAccessible = true
            m.invoke(g) as Boolean
        } catch (_: Exception) { false }
    }

    private fun retryConnectWithBackoff() {
        val dev = targetDevice ?: return
        val d = backoffMs.coerceAtMost(5000)
        Log.d("BLE", "retry in ${d}ms")
        android.os.Handler(ctx.mainLooper).postDelayed({
            backoffMs = (backoffMs * 2).coerceAtMost(5000)
            connect(dev)
        }, d.toLong())
    }

    // ===== GATT Callback =====
    private val gattCallback = object : BluetoothGattCallback() {

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            Log.d("BLE", "onConnChange status=$status state=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                refreshDeviceCache(g)
                closeGatt()
                _connectionState.value = ConnectionState.Failed("GATT 오류: $status")
                retryConnectWithBackoff()
                return
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    backoffMs = 1500
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    closeGatt()
                    _connectionState.value = ConnectionState.Disconnected
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            Log.d("BLE", "onServicesDiscovered status=$status")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                _connectionState.value = ConnectionState.Failed("서비스 검색 실패: $status"); return
            }

            val svc = g.getService(this@PpgBleClient.serviceUuid)
            if (svc == null) {
                Log.e("BLE", "Service not found: $serviceUuid")
                _connectionState.value = ConnectionState.Failed("서비스 UUID 미일치"); return
            }

            val dev = BleDevice(g.device?.name, g.device?.address ?: "Unknown")
            _connectionState.value = ConnectionState.Connected(dev)

            val ok = g.requestMtu(185)
            Log.d("BLE", "requestMtu(185) -> $ok (콜백은 onMtuChanged)")
            if (!ok) {
                Log.w("BLE", "requestMtu returned false, enabling notifications immediately")
                enableNotifications(g, svc)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            Log.d("BLE", "onMtuChanged mtu=$mtu status=$status")
            val svc = g.getService(this@PpgBleClient.serviceUuid) ?: run {
                Log.e("BLE", "Service missing on onMtuChanged")
                if (hasConnectPerm()) g.disconnect()
                return
            }
            enableNotifications(g, svc)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            Log.d("BLE", "onDescriptorWrite status=$status desc=${descriptor.uuid} char=${descriptor.characteristic.uuid}")
            writeNextDescriptor()
            if (descriptorQueue.isEmpty()) {
                Log.d("BLE", "All CCCDs written. Waiting for onCharacteristicChanged...")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            val bytes = ch.value ?: return
            Log.d("BLE", "notify bytes=${bytes.size} from ${ch.uuid}")
            feedBytesAndEmitLines(bytes)
        }
    }

    // ===== Notify/Indicate 등록 =====
    @SuppressLint("MissingPermission")
    private fun enableNotifications(g: BluetoothGatt, svc: BluetoothGattService) {
        descriptorQueue.clear()

        for (uuid in notifyCharUuids) {
            val ch = svc.getCharacteristic(uuid)
            if (ch == null) {
                Log.e("BLE", "Notify characteristic not found: $uuid")
                continue
            }

            val props = ch.properties
            val hasNotify = (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
            val hasIndicate = (props and BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0

            if (!hasNotify && !hasIndicate) {
                Log.e("BLE", "Char $uuid has neither NOTIFY nor INDICATE")
                continue
            }

            val ok = try { g.setCharacteristicNotification(ch, true) } catch (_: SecurityException) { false }
            if (!ok) {
                Log.e("BLE", "setCharacteristicNotification failed for $uuid")
                continue
            }

            val cccd = ch.getDescriptor(cccdUuid)
            if (cccd == null) {
                Log.e("BLE", "CCCD not found for $uuid")
                continue
            }

            cccd.value = if (hasNotify)
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            else
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE

            Log.d("BLE", "Queue CCCD write for $uuid (notify=$hasNotify indicate=$hasIndicate)")
            descriptorQueue.add(cccd)
        }

        writeNextDescriptor()
    }

    @SuppressLint("MissingPermission")
    private fun writeNextDescriptor() {
        val d = descriptorQueue.poll() ?: return
        try {
            val value = d.value ?: BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= 33) {
                gatt?.writeDescriptor(d, value)
            } else {
                @Suppress("DEPRECATION")
                run {
                    d.value = value
                    gatt?.writeDescriptor(d)
                }
            }
        } catch (_: SecurityException) {
            onError("Descriptor write 권한 오류")
        }
    }

    init {
        // STAT 업로드
        repoScope.launch {
            processor.stat.collect { st ->
                val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return@collect
                val sid = repo.getSessionId() ?: return@collect

                if (sid.isBlank()) return@collect

                val data = mapOf(
                    "event" to "STAT",
                    "ts_ms" to st.tsMsRel,

                    // 기존 지표
                    "AmpRatio" to st.ampRatio,
                    "BPM_L" to st.BPM_L,
                    "BPM_R" to st.BPM_R,
                    "PAD_ms" to st.PAD_ms,              // foot_R - foot_L
                    "PQIL" to null, "PQIR" to null,
                    "SUTL_ms" to st.SUTL_ms,
                    "SUTR_ms" to st.SUTR_ms,
                    "ampL" to st.ampL, "ampR" to st.ampR,
                    "dSUT_ms" to st.dSUT_ms,
                    "smoothed_left" to st.smoothed_left,
                    "smoothed_right" to st.smoothed_right,

                    // 추가 지표
                    "UpSlope_L" to st.UpSlope_L,
                    "UpSlope_R" to st.UpSlope_R,
                    "PPI_L_ms" to st.PPI_L_ms,
                    "PPI_R_ms" to st.PPI_R_ms
                )

                repo.uploadRecordMap(uid, sid, data)
            }
        }

        // ALERT 업로드
        // ALERT 업로드
        repoScope.launch {
            processor.alert.collect { al ->
                val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return@collect
                val sid = repo.getSessionId() ?: return@collect
                if (sid.isBlank()) return@collect

                val s = al.ref

                // 1) type → side 추론 (UI 문구/필터에 안정적)
                val inferredSide: String? = when (al.type.lowercase()) {
                    "left_perfusion_slow"  -> "left"
                    "right_perfusion_slow" -> "right"
                    "asymmetry"            -> "asymmetry"
                    else                   -> null
                }

                // 2) Firestore 업로드 payload에 side 포함
                val data = mapOf(
                    "event" to "ALERT",
                    "ts_ms" to al.tsMsRel,
                    "alert_type" to al.type,
                    "side" to inferredSide,                 // ★ 추가
                    "reasons" to al.reasons,

                    "AmpRatio" to s.ampRatio,
                    "PAD_ms" to s.PAD_ms,
                    "dSUT_ms" to s.dSUT_ms,
                    "ampL" to s.ampL, "ampR" to s.ampR,
                    "SUTL_ms" to s.SUTL_ms, "SUTR_ms" to s.SUTR_ms,
                    "smoothed_left" to s.smoothed_left,
                    "smoothed_right" to s.smoothed_right,
                    "UpSlope_L" to s.UpSlope_L, "UpSlope_R" to s.UpSlope_R,
                    "PPI_L_ms" to s.PPI_L_ms, "PPI_R_ms" to s.PPI_R_ms
                )

                // 3) Firestore 비동기 업로드 (지연 상관없이)
                repo.uploadRecordMap(uid, sid, data)

                // 4) ★ UI에 "즉시" 알림 발사 (Firestore 반사 신호 기다리지 않음)
                repo.emitLocalAlert(
                    side = inferredSide,
                    alertType = al.type,
                    reasons = al.reasons,
                    ts = System.currentTimeMillis()
                )
            }
        }
    }

}
