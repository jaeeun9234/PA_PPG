package com.example.heartsync.viewmodel

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.ble.PpgBleClient
import com.example.heartsync.data.model.BleDevice
import com.example.heartsync.data.model.GraphState
import com.example.heartsync.data.remote.PpgRepository
import com.example.heartsync.service.MeasureService
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

class BleViewModel(

    private val repo: PpgRepository
) : ViewModel() {

    // ⚠️ 권한 이슈로 즉시 생성 시 죽는 경우가 있어 lazy 권장
    private val client by lazy { PpgBleClient(getApplication()) }

    // ✅ 싱글턴 레포지토리 사용 (object PpgRepository 또는 PpgRepository.get())
    //private val repo = PpgRepository.instance
    // private val repo = PpgRepository.get() // 만약 companion get() 패턴이면 이 줄로

    private var smoothedJob: Job? = null
    private var scanJob: Job? = null
    private var connJob: Job? = null
    private var fsJob: Job? = null

    private val MAX_GRAPH_POINTS = 512

    // 실시간 그래프 상태 (L/R 시퀀스)
    private val _graphState = MutableStateFlow(GraphState())
    val graphState: StateFlow<GraphState> = _graphState.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _scanResults = MutableStateFlow<List<BleDevice>>(emptyList())
    val scanResults: StateFlow<List<BleDevice>> = _scanResults.asStateFlow()

    private val _connectionState =
        MutableStateFlow<PpgBleClient.ConnectionState>(PpgBleClient.ConnectionState.Disconnected)
    val connectionState: StateFlow<PpgBleClient.ConnectionState> = _connectionState.asStateFlow()

    /** 팝업용 ALERT 스트림 (repo가 방출) */
    val alerts: SharedFlow<PpgRepository.UiAlert> = repo.alerts

    /** Firestore에서 smoothed를 읽어 그래프에 반영 */
    fun startFirestoreGraph(uid: String, sessionId: String, limit: Long = 512L) {
        fsJob?.cancel()
        fsJob = viewModelScope.launch {
            repo.observeSmoothedFromFirestore(uid, sessionId, limit)
                .onEach { (l, r) ->
                    val cap = limit.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    _graphState.update { prev ->
                        prev.copy(
                            smoothedL = (prev.smoothedL + l).takeLast(cap),
                            smoothedR = (prev.smoothedR + r).takeLast(cap)
                        )
                    }
                }
                .catch { e -> android.util.Log.e("BleVM", "observeSmoothedFromFirestore error", e) }
                .collect()
        }
    }

    fun startScan() {
        if (_scanning.value) return
        try {
            _scanning.value = true
            client.startScan()

            scanJob?.cancel()
            scanJob = client.scanResults
                .onEach { list -> _scanResults.value = list }
                .launchIn(viewModelScope)
        } catch (se: SecurityException) {
            _scanning.value = false
            android.util.Log.e("BleVM", "Missing BLE permission", se)
            // TODO: UI에서 권한 요청 트리거
        }
    }

    fun stopScan() {
        _scanning.value = false
        scanJob?.cancel()
        client.stopScan()
    }

    fun connect(device: BleDevice) {
        stopScan()
        try {
            client.connect(device)

            connJob?.cancel()
            connJob = client.connectionState
                .onEach { state -> _connectionState.value = state }
                .launchIn(viewModelScope)
        } catch (se: SecurityException) {
            android.util.Log.e("BleVM", "Missing BLE permission", se)
        }
    }

    fun disconnect(){
        stopMeasure()

        client.disconnect()

        _connectionState.value = PpgBleClient.ConnectionState.Disconnected
        connJob?.cancel()
        clearGraph()
    }

    fun clearGraph() {
        _graphState.value = GraphState()
    }

    /** BLE 연결 상태 변화에 맞춰 수집 시작/중단 + 그래프 초기화 */
    fun onBleConnectionChanged(
        isConnected: Boolean,
        uid: String?,
        sessionId: String?
    ) {
        // 기존 수집 중단
        smoothedJob?.cancel()
        smoothedJob = null

        if (!isConnected) {
            // 연결 해제 시 그래프 클리어
            _graphState.value = GraphState()
            return
        }

        // 연결된 경우에만 수집 시작
        if (uid != null && sessionId != null) {
            smoothedJob = viewModelScope.launch {
                repo.observeSmoothedFromFirestore(uid, sessionId, limit = 1000)
                    .collect { (l, r) ->
                        _graphState.update { cur ->
                            cur.copy(
                                smoothedL = (cur.smoothedL + l).takeLast(300),
                                smoothedR = (cur.smoothedR + r).takeLast(300)
                            )
                        }
                    }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        scanJob?.cancel()
        connJob?.cancel()
        fsJob?.cancel()
        smoothedJob?.cancel()
        client.stopScan()
        client.disconnect()
    }

    /** 연결된 기기로 측정 시작 */
    fun startMeasure(device: BleDevice) {
        val ctx = getApplication<Application>()
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
}
