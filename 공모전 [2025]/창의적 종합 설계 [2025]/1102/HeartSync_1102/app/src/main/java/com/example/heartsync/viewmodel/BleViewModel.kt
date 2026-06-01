package com.example.heartsync.viewmodel

import android.app.Application
import android.content.Intent
import android.widget.Toast
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.ble.PpgBleClient
import com.example.heartsync.data.model.BleDevice
import com.example.heartsync.data.model.GraphState
import com.example.heartsync.data.remote.PpgRepository
import com.example.heartsync.service.MeasureService
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

class BleViewModel(
    app: Application
) : AndroidViewModel(app) {

    private val client = PpgBleClient(app)

    private val _graphState = MutableStateFlow(GraphState())
    val graphState: StateFlow<GraphState> = _graphState.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _scanResults = MutableStateFlow<List<BleDevice>>(emptyList())
    val scanResults: StateFlow<List<BleDevice>> = _scanResults.asStateFlow()

    private val _connectionState =
        MutableStateFlow<PpgBleClient.ConnectionState>(PpgBleClient.ConnectionState.Disconnected)
    val connectionState: StateFlow<PpgBleClient.ConnectionState> = _connectionState.asStateFlow()

    private var scanJob: Job? = null
    private var connJob: Job? = null
    private var fsJob: Job? = null

    private val MAX_GRAPH_POINTS = 1000

    init {
        // ✅ BLE 실시간 스트림(10 Hz) 수집 → 그래프 업데이트
        viewModelScope.launch(Dispatchers.Default) {
            PpgRepository.smoothedThrottled(100)   // 100 ms 간격 → 약 10 Hz
                .collect { t: Triple<Long, Float, Float> ->
                    val l = t.second
                    val r = t.third
                    appendGraphPoint(l, r)
                }
        }
    }

    /** Firestore에서 최근 기록을 읽어 그래프에 반영 */
    fun startFirestoreGraph(uid: String, sessionId: String, limit: Long = 512L) {
        fsJob?.cancel()
        fsJob = viewModelScope.launch(Dispatchers.IO) {
            val db = FirebaseFirestore.getInstance()
            val col = db.collection("ppg_events")
                .document(uid)
                .collection("sessions")
                .document(sessionId)
                .collection("records")

            col.orderBy("ts_ms", Query.Direction.ASCENDING)
                .limitToLast(limit)
                .addSnapshotListener { snap, err ->
                    if (err != null || snap == null) return@addSnapshotListener

                    // 연결 중엔 Firestore 그래프 갱신 중단 (라이브와 충돌 방지)
                    if (_connectionState.value is PpgBleClient.ConnectionState.Connected) return@addSnapshotListener

                    val ls = ArrayList<Float>()
                    val rs = ArrayList<Float>()
                    for (d in snap.documents) {
                        val l = (d.getDouble("smoothed_left") ?: d.getDouble("PPGf_L"))?.toFloat()
                        val r = (d.getDouble("smoothed_right") ?: d.getDouble("PPGf_R"))?.toFloat()
                        if (l != null && r != null) {
                            ls += l
                            rs += r
                        }
                    }
                    _graphState.value = GraphState(
                        smoothedL = ls.takeLast(MAX_GRAPH_POINTS),
                        smoothedR = rs.takeLast(MAX_GRAPH_POINTS)
                    )
                }
        }
    }

    fun startScan() {
        if (_scanning.value) return
        _scanning.value = true
        client.startScan()

        scanJob?.cancel()
        scanJob = client.scanResults
            .onEach { list -> _scanResults.value = list }
            .launchIn(viewModelScope)
    }

    fun stopScan() {
        _scanning.value = false
        scanJob?.cancel()
        client.stopScan()
    }

    fun connect(device: BleDevice) {
        stopScan()
        client.connect(device)

        connJob?.cancel()
        connJob = client.connectionState
            .onEach { state ->
                _connectionState.value = state
                if (state is PpgBleClient.ConnectionState.Connected) {
                    // 🔒 실시간 연결 시 Firestore 리스너 중단
                    fsJob?.cancel()
                }
            }
            .launchIn(viewModelScope)
    }

    fun disconnect() {
        val ctx = getApplication<Application>()
        ctx.stopService(Intent(ctx, com.example.heartsync.service.MeasureService::class.java))

        client.disconnect()
        _connectionState.value = PpgBleClient.ConnectionState.Disconnected

        connJob?.cancel()
    }

    fun clearGraph() {
        _graphState.value = GraphState()
    }

    override fun onCleared() {
        super.onCleared()
        scanJob?.cancel()
        connJob?.cancel()
        fsJob?.cancel()
        client.stopScan()
        client.disconnect()
    }

    /** 연결된 기기로 측정 시작 */
    fun startMeasure(device: BleDevice) {
        val ctx = getApplication<Application>()

        // 🚫 연결 안 되어 있으면 실행 안 함
        if (_connectionState.value !is PpgBleClient.ConnectionState.Connected) {
            Toast.makeText(ctx, "기기가 연결되지 않았습니다.", Toast.LENGTH_SHORT).show()
            return
        }

        val it = Intent(ctx, MeasureService::class.java).apply {
            putExtra(MeasureService.EXTRA_DEVICE_NAME, device.name)
            putExtra(MeasureService.EXTRA_DEVICE_ADDR, device.address)
        }

        if (android.os.Build.VERSION.SDK_INT >= 26) {
            ctx.startForegroundService(it)
        } else {
            ctx.startService(it)
        }
    }

    /** 측정 중지 */
    fun stopMeasure() {
        val ctx = getApplication<Application>()
        ctx.stopService(Intent(ctx, MeasureService::class.java))
    }

    // ───────────────────────── helpers ─────────────────────────

    private fun appendGraphPoint(l: Float, r: Float) {
        val cur = _graphState.value
        val lNew = (cur.smoothedL + l).takeLast(MAX_GRAPH_POINTS)
        val rNew = (cur.smoothedR + r).takeLast(MAX_GRAPH_POINTS)
        _graphState.value = cur.copy(smoothedL = lNew, smoothedR = rNew)
    }

    private var lastGraphState: GraphState? = null

    fun updateGraph(newState: GraphState) {
        lastGraphState = newState
        _graphState.value = newState
    }

    fun onDisconnected() {
        _graphState.value = lastGraphState ?: GraphState(emptyList(), emptyList())
    }
}
