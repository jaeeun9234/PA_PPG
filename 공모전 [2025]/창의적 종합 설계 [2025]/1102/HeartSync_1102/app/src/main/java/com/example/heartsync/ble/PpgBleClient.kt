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
import com.example.heartsync.data.model.PpgEvent
import com.example.heartsync.data.model.toMap
import com.example.heartsync.data.remote.PpgRepository
import com.example.heartsync.service.OnDeviceProcessor
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue

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

    // ===== 상태 =====
    @Volatile private var liveActive = false
    @Volatile private var manualDisconnect = false
    @Volatile private var lastBleRxMs: Long = 0L
    @Volatile private var lastAlertKey: String? = null
    @Volatile private var lastAlertAt: Long = 0L

    private fun shouldSaveAlertOnce(evt: com.example.heartsync.data.model.PpgEvent): Boolean {
        if (evt.event != "ALERT") return true
        val sec = (evt.ts_ms / 1000L)
        val reasonsKey = evt.reasons?.sorted()?.joinToString(",") ?: "-"
        val key = "${sec}|${evt.risk}|${evt.alert_type ?: "-"}|${evt.side ?: "-"}|${reasonsKey}"
        val isNew = (key != lastAlertKey) || (evt.ts_ms - lastAlertAt > 3000L) // 3초 쿨다운
        if (isNew) {
            lastAlertKey = key
            lastAlertAt = evt.ts_ms
        }
        return isNew
    }
    private fun isBleFresh(timeoutMs: Long = 1000L): Boolean =
        System.currentTimeMillis() - lastBleRxMs <= timeoutMs

    private val repoScope = CoroutineScope(Dispatchers.IO)

    // ===== 안드로이드 측 지표 계산기 =====
    private val odp = OnDeviceProcessor(
        fsHz = 50,
        dcWinSec = 1.5,
        smoothN = 5,
        foiAlpha = 0.1,
        ausprSmoothK = 5
    )

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

    private var lastAppendTimeMs = 0L

    // ===== 라인 프레이머 =====
    private val lineBuf = StringBuilder()
    private fun StringBuilder.indexOfAny(chars: CharArray): Int {
        for (i in 0 until this.length) {
            val c = this[i]
            for (t in chars) if (c == t) return i
        }
        return -1
    }

    // ===== 파서 유틸 =====
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
                sb.append(ch); i++
            } else break
        }
        return sb.toString().toDoubleOrNull()
    }

    private fun parseCsvLeftRight(line: String): Pair<Double, Double>? {
        val t = line.split(',', ';', '\t').map { it.trim() }.filter { it.isNotEmpty() }
        if (t.size >= 3) { // t,left,right
            val l = t[1].toDoubleOrNull()
            val r = t[2].toDoubleOrNull()
            if (l != null && r != null) return l to r
        } else if (t.size == 2) { // left,right
            val l = t[0].toDoubleOrNull()
            val r = t[1].toDoubleOrNull()
            if (l != null && r != null) return l to r
        }
        return null
    }

    // ===== CSV/KV 라인 처리 → 그래프 + 지표계산 + 저장 =====
//    private fun feedBytesAndEmitLines(bytes: ByteArray) {
//        val s = try { String(bytes, StandardCharsets.UTF_8) } catch (_: Exception) { return }
//        lineBuf.append(s)
//        lastAppendTimeMs = System.currentTimeMillis()
//        val delims = charArrayOf('\n', '\r')
//        while (true) {
//            val idx = lineBuf.indexOfAny(delims)
//            if (idx < 0) break
//            val oneLine = lineBuf.substring(0, idx).trim()
//            lineBuf.delete(0, idx + 1)
//            if (oneLine.isEmpty()) continue
//
//            var lVal: Double? = null
//            var rVal: Double? = null
//            try {
//                val obj = JSONObject(oneLine)
//                if (obj.optString("type") == "PPGf") {
//                    lVal = obj.optDouble("L", Double.NaN).takeIf { !it.isNaN() }
//                    rVal = obj.optDouble("R", Double.NaN).takeIf { !it.isNaN() }
//                }
//            } catch (_: Exception) { /* not JSON */ }
//            if (lVal == null || rVal == null) {
//                lVal = parseNumKV(oneLine, "PPGf_L") ?: lVal
//                rVal = parseNumKV(oneLine, "PPGf_R") ?: rVal
//                if (lVal == null || rVal == null) {
//                    parseCsvLeftRight(oneLine)?.let { (l, r) -> lVal = l; rVal = r }
//                }
//            }
//
//            if (lVal != null && rVal != null) {
//                // 1) 그래프 반영
//                PpgRepository.emitSmoothed(System.currentTimeMillis(), lVal!!, rVal!!)
//
//                // 2) 지표 계산 → STAT 라인 → 저장
//                val tsRel: Long = (parseNumKV(oneLine, "ts_ms")?.toLong()
//                    ?: parseNumKV(oneLine, "ts")?.toLong()
//                    ?: System.currentTimeMillis())
//
//                val csv = "$tsRel,$lVal,$rVal"
//                val lines = odp.onCsvLine(csv)
//
//                repoScope.launch {
//                    if (!isBleFresh()) return@launch
//                    val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
//                        ?: return@launch
//                    PpgRepository.setSessionIdIfEmpty()
//
//                    PpgRepository.currentSessionId() // 보장만
//
//                    for (ln in lines) {
//                        try {
//                            PpgRepository.instance.trySaveFromLine(ln)
//
//                            // ✅ 여기서 가공된 PPGf를 그래프로 emit (원시 대신)
//                            val l = parseNumKV(ln, "PPGf_L")
//                            val r = parseNumKV(ln, "PPGf_R")
//                            if (l != null && r != null) {
//                                PpgRepository.emitSmoothed(System.currentTimeMillis(), l, r)
//                            }
//                        } catch (t: Throwable) {
//                            Log.e("BLE", "trySaveFromLine fail", t)
//                        }
//                    }
//                }
//                continue
//            }
//
//            // 3) 이미 "STAT/ALERT" 라인이면 그대로 저장
//            if (oneLine.startsWith("STAT") || oneLine.startsWith("ALERT")) {
//                repoScope.launch {
//                    if (!isBleFresh()) return@launch
//                    try {
//                        PpgRepository.setSessionIdIfEmpty()
//                        PpgRepository.instance.trySaveFromLine(oneLine)
//                    } catch (t: Throwable) {
//                        Log.e("BLE", "save from STAT/ALERT fail", t)
//                    }
//                }
//            }
//        }
//    }
    private fun feedBytesAndEmitLines(bytes: ByteArray) {
        val s = try { String(bytes, StandardCharsets.UTF_8) } catch (_: Exception) { return }
        lineBuf.append(s)
        lastAppendTimeMs = System.currentTimeMillis()
        val delims = charArrayOf('\n', '\r')
        while (true) {
            val idx = lineBuf.indexOfAny(delims)
            if (idx < 0) break
            val oneLine = lineBuf.substring(0, idx).trim()
            lineBuf.delete(0, idx + 1)
            if (oneLine.isEmpty()) continue

            var lVal: Double? = null
            var rVal: Double? = null
            var fromPpgf = false   // ✅ 추가: PPGf(이미 스무딩) 출처인지 표기

            try {
                val obj = JSONObject(oneLine)
                if (obj.optString("type") == "PPGf") {
                    lVal = obj.optDouble("L", Double.NaN).takeIf { !it.isNaN() }
                    rVal = obj.optDouble("R", Double.NaN).takeIf { !it.isNaN() }
                    fromPpgf = (lVal != null && rVal != null)      // ✅ JSON PPGf
                }
            } catch (_: Exception) { /* not JSON */ }

            if (lVal == null || rVal == null) {
                val lKV = parseNumKV(oneLine, "PPGf_L")
                val rKV = parseNumKV(oneLine, "PPGf_R")
                if (lKV != null && rKV != null) {
                    lVal = lKV; rVal = rKV
                    fromPpgf = true                                 // ✅ KV PPGf
                } else {
                    // 마지막으로 CSV 시도 (원시)
                    parseCsvLeftRight(oneLine)?.let { (l, r) ->
                        lVal = l; rVal = r
                        fromPpgf = false                            // ✅ CSV(원시)
                    }
                }
            }

            if (lVal != null && rVal != null) {
                // ✅ 여기서 핵심: PPGf에서 온 값만 즉시 emit
                if (fromPpgf) {
                    PpgRepository.emitSmoothed(System.currentTimeMillis(), lVal!!, rVal!!)
                }

                // 이후 공통: ODP로 가공 → STAT 라인 저장
                val tsRel: Long = (parseNumKV(oneLine, "ts_ms")?.toLong()
                    ?: parseNumKV(oneLine, "ts")?.toLong()
                    ?: System.currentTimeMillis())

                val csv = "$tsRel,$lVal,$rVal"
                val lines = odp.onCsvLine(csv)

                repoScope.launch {
                    if (!isBleFresh()) return@launch
                    PpgRepository.setSessionIdIfEmpty()
                    for (ln in lines) {
                        try {
                            PpgRepository.instance.trySaveFromLine(ln)

                            // ✅ 여기서 가공된 PPGf_L/R 있으면 그래프 emit
                            val l = parseNumKV(ln, "PPGf_L")
                            val r = parseNumKV(ln, "PPGf_R")
                            if (l != null && r != null) {
                                // 가능하면 같은 타임스탬프를 써서 연속성 유지
                                PpgRepository.emitSmoothed(tsRel, l, r)
                            }
                        } catch (t: Throwable) {
                            Log.e("BLE", "trySaveFromLine fail", t)
                        }
                    }
                }
                continue
            }

            // STAT/ALERT 원문 라인은 저장만
            if (oneLine.startsWith("STAT") || oneLine.startsWith("ALERT")) {
                repoScope.launch {
                    if (!isBleFresh()) return@launch
                    try {
                        PpgRepository.setSessionIdIfEmpty()
                        PpgRepository.instance.trySaveFromLine(oneLine)
                    } catch (t: Throwable) {
                        Log.e("BLE", "save from STAT/ALERT fail", t)
                    }
                }
            }
        }
    }


    // ===== 재시도 =====
    private var targetDevice: BleDevice? = null
    private var backoffMs = 1500

    // ===== 권한 =====
    private fun hasScanPerm(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED

    private fun hasConnectPerm(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED

    private fun hasLegacyLocation(): Boolean =
        Build.VERSION.SDK_INT < 31 &&
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED

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
        closeGatt()
        Log.d("BLE", "connect() to ${device.address}")
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            btDev.connectGatt(ctx, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            btDev.connectGatt(ctx, false, gattCallback)
        }
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        manualDisconnect = true
        liveActive = false
        disableNotifications()
        lineBuf.clear()
        lastAppendTimeMs = 0L
        Log.d("BLE", "disconnect()")
        closeGatt()
        _connectionState.value = ConnectionState.Disconnected
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt() {
        if (!hasConnectPerm()) { gatt = null; return }
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
                    liveActive = false
                    lastBleRxMs = 0L
                    manualDisconnect = false
                    backoffMs = 1500
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    liveActive = false
                    lastBleRxMs = 0L
                    lastAppendTimeMs = 0L
                    closeGatt()
                    _connectionState.value = ConnectionState.Disconnected
                    if (!manualDisconnect) retryConnectWithBackoff()
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
            Log.d("BLE", "requestMtu(185) -> $ok")
            if (!ok) enableNotifications(g, svc)
            PpgRepository.onBleConnected()
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            Log.d("BLE", "onMtuChanged mtu=$mtu status=$status")
            val svc = g.getService(this@PpgBleClient.serviceUuid) ?: return
            enableNotifications(g, svc)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            Log.d("BLE", "onDescriptorWrite status=$status desc=${descriptor.uuid}")
            this@PpgBleClient.writeNextDescriptor()
            if (descriptorQueue.isEmpty()) {
                Log.d("BLE", "All CCCDs written. Waiting for onCharacteristicChanged...")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (!liveActive) return
            lastBleRxMs = System.currentTimeMillis()

            val bytes = ch.value ?: return
            val text = try { String(bytes, Charsets.UTF_8).trim() } catch (_: Exception) { return }
            var handled = false

            try {
                val obj = JSONObject(text)
                if (obj.optString("type") == "PPGf") {
                    val ts  = obj.optLong("ts_ms", System.currentTimeMillis())
                    val l   = obj.optDouble("L", Double.NaN)
                    val r   = obj.optDouble("R", Double.NaN)
                    if (!l.isNaN() && !r.isNaN()) {
                        // 그래프 즉시 반영
                        PpgRepository.emitSmoothed(ts, l, r)

                        // 지표 포함 여부
                        fun hasMetric(o: JSONObject): Boolean {
                            val keys = arrayOf(
                                "AUSPR","HSI","RT_L_ms","RT_R_ms","SUTL_ms","SUTR_ms",
                                "DeltaTD_ms","PAD_ms","dSUT_ms","risk","alert_type","side"
                            )
                            for (k in keys) if (o.has(k)) return true
                            return false
                        }

                        if (!hasMetric(obj)) {
                            // 지표 없음 → odp 계산 → trySaveFromLine
                            val csv = "$ts,$l,$r"
                            val lines = odp.onCsvLine(csv)
                            repoScope.launch {
                                if (!isBleFresh()) return@launch
                                PpgRepository.setSessionIdIfEmpty()
                                for (ln in lines) {
                                    try { PpgRepository.instance.trySaveFromLine(ln) }
                                    catch (t: Throwable) { Log.e("BLE", "trySaveFromLine(JSON) fail", t) }
                                }
                            }
                        } else {
                            // 지표 이미 포함 → PpgEvent로 직저장
                            fun jDouble(key: String): Double? =
                                obj.optDouble(key, Double.NaN).let { if (it.isNaN()) null else it }
                            fun jInt(key: String): Int? =
                                if (obj.has(key) && !obj.isNull(key)) obj.optInt(key) else null
                            fun jStr(key: String): String? =
                                obj.optString(key, null)?.takeIf { it.isNotEmpty() }
                            fun jReasons(): List<String>? =
                                if (obj.has("reasons") && obj.optJSONArray("reasons") != null) {
                                    val arr = obj.optJSONArray("reasons")
                                    (0 until arr.length()).mapNotNull { i -> arr.optString(i, null) }
                                        .filter { it.isNotBlank() }
                                        .takeIf { it.isNotEmpty() }
                                } else null

                            val riskVal = jStr("risk")
                            val sideVal = jStr("side")
                            val sideFinal = if (riskVal == "OK") "-" else sideVal

                            val evt = com.example.heartsync.data.model.PpgEvent(
                                event          = obj.optString("event", "STAT"),
                                host_time_iso  = isoNowUtc(),
                                ts_ms          = ts,
                                alert_type     = jStr("alert_type"),
                                reasons        = jReasons(),
                                AmpRatio       = jDouble("AmpRatio"),
                                PAD_ms         = jDouble("PAD_ms"),
                                dSUT_ms        = jDouble("dSUT_ms"),
                                ampL           = jDouble("ampL"),
                                ampR           = jDouble("ampR"),
                                SUTL_ms        = jDouble("SUTL_ms"),
                                SUTR_ms        = jDouble("SUTR_ms"),
                                BPM_L          = jDouble("BPM_L"),
                                BPM_R          = jDouble("BPM_R"),
                                PQIL           = jInt("PQIL"),
                                PQIR           = jInt("PQIR"),
                                side           = sideVal,
                                smoothed_left  = jDouble("smoothed_left") ?: l,
                                smoothed_right = jDouble("smoothed_right") ?: r,
                                AUSPR          = jDouble("AUSPR"),
                                HSI            = jDouble("HSI"),
                                risk           = jStr("risk"),
                            )
//                            repoScope.launch {
//                                if (!isBleFresh()) return@launch
//                                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
//                                    ?: return@launch
//                                PpgRepository.setSessionIdIfEmpty()
//                                val sid = PpgRepository.currentSessionId()
//                                try {
//                                    PpgRepository.instance.uploadRecord(uid, sid, evt)
//
//                                    Log.d("BLE", "savePpgEvent ok (${evt.ts_ms})")
//                                } catch (t: Throwable) {
//                                    Log.e("BLE", "savePpgEvent fail", t)
//                                }
//                            }
                        }
                        handled = true
                    }
                }
            } catch (_: Exception) {
                // not JSON
            }

            if (!handled) {
                // CSV/KV 라인 폴백 (→ odp 계산 포함)
                feedBytesAndEmitLines(bytes)
            }
        }
    } // 콜백 끝

    // ===== Descriptor write helper =====
    @SuppressLint("MissingPermission")
    private fun writeNextDescriptor() {
        val d = descriptorQueue.poll() ?: return
        try {
            val value = d.value ?: BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= 33) {
                gatt?.writeDescriptor(d, value)
            } else {
                @Suppress("DEPRECATION")
                run { d.value = value; gatt?.writeDescriptor(d) }
            }
        } catch (_: SecurityException) {
            onError("Descriptor write 권한 오류")
        } catch (t: Throwable) {
            Log.e("BLE", "writeNextDescriptor fail", t)
        }
    }

    // ===== Notify/Indicate 등록 =====
    @SuppressLint("MissingPermission")
    private fun enableNotifications(g: BluetoothGatt, svc: BluetoothGattService) {
        descriptorQueue.clear()
        for (uuid in notifyCharUuids) {
            val ch = svc.getCharacteristic(uuid) ?: continue
            val ok = try { g.setCharacteristicNotification(ch, true) } catch (_: SecurityException) { false }
            if (!ok) continue
            val cccd = ch.getDescriptor(cccdUuid) ?: continue
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            descriptorQueue.add(cccd)
        }
        writeNextDescriptor()
        liveActive = true
    }

    @SuppressLint("MissingPermission")
    private fun disableNotifications() {
        val g = gatt ?: return
        try {
            val svc = g.getService(serviceUuid) ?: return
            for (uuid in notifyCharUuids) {
                val ch = svc.getCharacteristic(uuid) ?: continue
                try { g.setCharacteristicNotification(ch, false) } catch (_: SecurityException) {}
                val cccd = ch.getDescriptor(cccdUuid) ?: continue
                try {
                    val value = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(cccd, value)
                    else {
                        @Suppress("DEPRECATION")
                        run { cccd.value = value; g.writeDescriptor(cccd) }
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    private fun isoNowUtc(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return sdf.format(java.util.Date())
    }
}
