// app/src/main/java/com/example/heartsync/service/MeasureService.kt
package com.example.heartsync.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ContentValues.TAG
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.heartsync.ble.PpgBleClient
import com.example.heartsync.data.model.BleDevice
import com.example.heartsync.data.model.PpgEvent
import com.example.heartsync.data.remote.PpgRepository
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import java.time.OffsetDateTime
import java.time.ZoneOffset
import kotlin.coroutines.cancellation.CancellationException

class MeasureService : Service() {

    companion object {
        const val EXTRA_DEVICE_NAME = "extra_device_name"
        const val EXTRA_DEVICE_ADDR = "extra_device_addr"
        const val NOTI_ID = 1001
        const val NOTI_CHANNEL_ID = "measuresvc"

        private const val ALERT_CHANNEL_ID = "heartsync_alerts"
        private const val ALERT_CHANNEL_NAME = "HeartSync Alerts"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private lateinit var client: PpgBleClient
    private val repo: PpgRepository = PpgRepository.instance

    private var userId: String = ""
    private var sessionId: String = ""

    private var lastShownMs = 0L
    private var lastBand = 0               // 0=OK, 1=WARN, 2=HIGH
    private val RETRIGGER_MS = 15_000L

    // 최근 라인(그래프 EMA만 사용)
    @Volatile private var latestStatLine: String? = null

    // 5초 주기 저장 루프
    private var saverJob: Job? = null
    // Firestore ALERT 백업 트리거 (5초 저장을 감시)
    private var firestoreAlertLastTs: Long = 0L
    private var firestoreAlertReg: ListenerRegistration? = null

    // 그래프용 EMA (선택)
    private var emaL: Double? = null
    private var emaR: Double? = null
    private val EMA_ALPHA = 0.2
    private fun emaUpdate(prev: Double?, x: Double): Double =
        if (prev == null) x else EMA_ALPHA * x + (1 - EMA_ALPHA) * prev

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.ensureChannel(this, NOTI_CHANNEL_ID, "HeartSync Measure")
        ensureAlertChannel()

        startForeground(
            NOTI_ID,
            NotificationCompat.Builder(this, NOTI_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle("측정 중")
                .setContentText("시작 준비…")
                .setOngoing(true)
                .build()
        )
    }

    private fun registerFirestoreAlertListener() {
        val uid = userId
        if (uid.isBlank()) return

        val db = FirebaseFirestore.getInstance()
        // 기존 리스너 있으면 제거
        firestoreAlertReg?.remove()
        firestoreAlertReg = db.collectionGroup("records")
            .whereEqualTo("ownerUid", uid)
            .whereEqualTo("event", "ALERT")
            .orderBy("ts_ms")
            .limit(1) // 최신 1건만 감시
            .addSnapshotListener { snap, e ->
                if (e != null || snap == null) return@addSnapshotListener
                val doc = snap.documents.lastOrNull() ?: return@addSnapshotListener

                val ts = (doc.getLong("ts_ms") ?: 0L)
                val risk = doc.getString("risk") ?: return@addSnapshotListener
                if (risk == "OK") return@addSnapshotListener

                // 중복 방지 (같은 ts 재발행 차단)
                if (ts <= firestoreAlertLastTs) return@addSnapshotListener
                firestoreAlertLastTs = ts

                val hsi   = (doc.getDouble("HSI") ?: 0.0)
                val auspr = doc.getDouble("AUSPR")
                val padMs = doc.getDouble("PAD_ms")
                val side  = doc.getString("side")

                showAlertHeadsUp(
                    title = "혈류 비대칭 $risk",
                    text = buildString {
                        append("HSI ${"%.2f".format(hsi)}")
                        auspr?.let { append(" • AUSPR ${"%.2f".format(it)}") }
                        padMs?.let { append(" • PWTT ${"%.0f".format(it)}ms") }
                        side?.let { if (it != "-") append(" • 의심: $it") }
                    }
                )
            }
    }

    private lateinit var odp: OnDeviceProcessor

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val devName = intent?.getStringExtra(EXTRA_DEVICE_NAME) ?: ""
        val devAddr = intent?.getStringExtra(EXTRA_DEVICE_ADDR) ?: ""

        if (devName.isBlank() || devAddr.isBlank()) {
            Log.e("MeasureService", "No BLE device info, stopping service")
            stopSelf()
            return START_NOT_STICKY
        }

        scope.launch {
            // 사용자 확인
            val uid = FirebaseAuth.getInstance().currentUser?.uid
            if (uid == null) { stopSelf(); return@launch }
            userId = uid

            //registerFirestoreAlertListener()

            // ✅ ODP 인스턴스 생성 (파이썬과 동일 파라미터)
            odp = OnDeviceProcessor(
                fsHz = 50,
                dcWinSec = 1.5,
                smoothN = 5,
                foiAlpha = 0.1,
                ausprSmoothK = 5,        // 파이썬과 동일
                ausprClampLow = 0.5,
                ausprClampHigh = 2.0,
                minPeakProm = 30.0,
                refractSec = 0.35,
                pairTolSec = 0.10,
                minRtMs = 100.0,
                hsiTdBase = 40.0,        // 40/25 유지
                hsiTdScale = 25.0,
                hsiWarn = 1.5,           // 유지
                hsiHigh = 3.0,           // 유지
                ausprBand = 0.30         // ln(1+0.30) 분모
            )

            // BLE 시작
            client = PpgBleClient(
                ctx = this@MeasureService,
                onLine = { line ->
                    if (line.isNullOrBlank() || line == "null") return@PpgBleClient

                    // 1) 그래프 스무딩/브로드캐스트 (PPGf_* 있으면 EMA 업데이트)
                    try {
                        val kv = mutableMapOf<String, String>()
                        line.split(' ', '\t', ',').forEach { token ->
                            val i = token.indexOf('=')
                            if (i in 1 until token.lastIndex) {
                                kv[token.substring(0, i)] = token.substring(i + 1)
                            }
                        }
                        val l = kv["smoothed_left"]?.toDoubleOrNull() ?: kv["PPGf_L"]?.toDoubleOrNull()
                        val r = kv["smoothed_right"]?.toDoubleOrNull() ?: kv["PPGf_R"]?.toDoubleOrNull()
                        if (l != null && r != null) {
                            emaL = emaUpdate(emaL, l)
                            emaR = emaUpdate(emaR, r)
                            PpgRepository.emitSmoothed(System.currentTimeMillis(), emaL!!, emaR!!)
                        }
                    } catch (_: Throwable) {}

                    // 2) CSV -> ODP로 처리하여 "STAT key=value ..." 라인들 생성
                    //    (여기에 HSI/risk/AUSPR/PAD_ms/side 등이 포함됨)
                    val statLines: List<String> = try {
                        odp.onCsvLine(line)
                    } catch (t: Throwable) {
                        Log.w("MeasureService", "ODP error: ${t.message}")
                        emptyList()
                    }

                    // 3) 저장/팝업 플로우로 위임 (ODP 산출치가 있으면 그것을 우선 사용)
                    scope.launch(Dispatchers.IO) {
                        try {
                            if (statLines.isEmpty()) {
                                // 초기 구간 등 ODP가 아직 산출 안 했으면 원본 라인도 시도
                                repo.trySaveFromLine(line)
                            } else {
                                statLines.forEach { repo.trySaveFromLine(it) }
                            }
                        } catch (t: Throwable) {
                            Log.w("MeasureService", "save error: ${t.message}")
                        }
                    }
                },
                onError = { e -> Log.e("MeasureService", "BLE error: $e") },
                filterByService = true
            )

            // suspend connect는 IO 컨텍스트에서
            withContext(Dispatchers.IO) {
                client.connect(BleDevice(devName, devAddr))
            }
            Log.d("MeasureService", "CONNECT TRY name=$devName addr=$devAddr")

            // 연결 상태 모니터링 + ALERT 팝업 수신
            scope.launch {
                // ALERT 브로드캐스트 수신 → 팝업
                launch {
                    PpgRepository.alerts().collectLatest { a ->
                        showAlertHeadsUp(
                            title = "혈류 비대칭 ${a.risk}",
                            text = buildString {
                                append("HSI ${"%.2f".format(a.hsi)}")
                                a.auspr?.let { append(" • AUSPR ${"%.2f".format(it)}") }
                                a.padMs?.let { append(" • PWTT ${"%.0f".format(it)}ms") }
                                a.side?.let { if (it != "-") append(" • 의심: $it") }
                            }
                        )
                    }
                }

                client.connectionState.collectLatest { st ->
                    when (st) {
                        is PpgBleClient.ConnectionState.Connected -> {
                            // 연결되면: 저장 게이트 ON + 세션 보장 + 5초 루프 시작
                            PpgRepository.onBleConnected()  // 내부에서 엔진/디바운스 리셋 권장
                            sessionId = PpgRepository.getSessionId() ?: PpgRepository.startNewSessionNow()
                            startSaverLoop()
                        }
                        is PpgBleClient.ConnectionState.Disconnected,
                        is PpgBleClient.ConnectionState.Failed -> {
                            // 연결 종료/실패: 저장 게이트 OFF + 캐시 클리어 + 루프 정지
                            PpgRepository.onBleDisconnected()
                            latestStatLine = null
                            stopSaverLoop()
                            runCatching { client.disconnect() }
                        }
                        is PpgBleClient.ConnectionState.Connecting -> {
                            // 연결 중: 저장 OFF + 루프 정지
                            PpgRepository.onBleDisconnected()
                            latestStatLine = null
                            stopSaverLoop()
                        }
                    }
                    val text = when (st) {
                        is PpgBleClient.ConnectionState.Connecting -> "연결 중…"
                        is PpgBleClient.ConnectionState.Connected  -> "연결됨"
                        is PpgBleClient.ConnectionState.Disconnected -> "연결 종료"
                        is PpgBleClient.ConnectionState.Failed -> "오류: ${st.reason}"
                    }
                    NotificationHelper.update(
                        this@MeasureService, NOTI_ID, NOTI_CHANNEL_ID,
                        title = "측정 중", text = text
                    )
                }
            }
        }
        return START_STICKY
    }


    // === 5초 주기 스냅샷 저장 루프 ===
    private fun startSaverLoop() {
        if (saverJob?.isActive == true) return
        saverJob = scope.launch(Dispatchers.IO) {

            // ① BLE 연결 게이트가 켜질 때까지 대기
            while (isActive && !(PpgRepository.isWriteEnabled() && PpgRepository.isLive())) {
                delay(100)
            }

            // ② 첫 이벤트(lastEvent)가 들어올 때까지 대기
            while (isActive && repo.peekLastEvent() == null) {
                delay(100)
            }

            // ③ 첫 저장은 "첫 이벤트 수신 후 5초 뒤"에 수행
            delay(5_000)

            // ④ 이후 5초 간격으로만 저장
            while (isActive) {
                try {
                    if (PpgRepository.isWriteEnabled() && repo.peekLastEvent() != null) {
                        val uid = FirebaseAuth.getInstance().currentUser?.uid
                        val sid = PpgRepository.getSessionId() ?: PpgRepository.startNewSessionNow()
                        if (uid != null) {
                            repo.writeSnapshotEvery5s(uid, sid)   // 내부에서 5초 가드 한 번 더
                            Log.d(TAG, "STAT snapshot saved (5s)")
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    Log.w(TAG, "Saver loop tick failed", t)
                } finally {
                    delay(5_000) // 다음 틱까지 5초
                }
            }
        }
    }

    private fun stopSaverLoop() {
        saverJob?.cancel()
        saverJob = null
    }

    private fun ensureAlertChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(
                ALERT_CHANNEL_ID,
                ALERT_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            )
            ch.enableVibration(true)
            mgr.createNotificationChannel(ch)
        }
    }

    private fun showAlertHeadsUp(title: String, text: String) {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val n = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .build()
        mgr.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), n)
    }

    private fun utcIsoNow(): String = OffsetDateTime.now(ZoneOffset.UTC).toString()

    @Suppress("unused")
    private suspend fun handleStructuredEventUpload(ev: PpgEvent) {
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        if (sessionId.isBlank()) {
            PpgRepository.setSessionIdIfEmpty()
            sessionId = PpgRepository.currentSessionId()
        }
        val lSrc: Double? = ev.ampL ?: ev.BPM_L
        val rSrc: Double? = ev.ampR ?: ev.BPM_R
        if (lSrc != null && rSrc != null) {
            emaL = emaUpdate(emaL, lSrc)
            emaR = emaUpdate(emaR, rSrc)
            PpgRepository.emitSmoothed(System.currentTimeMillis(), emaL!!, emaR!!)
        }
        runCatching { repo.uploadRecord(uid, sessionId, ev) }
            .onFailure { Log.e("MeasureService", "structured upload fail", it) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        try { PpgRepository.onBleDisconnected() } catch (_: Throwable) {
            PpgRepository.enableWrites(false)
        }
        latestStatLine = null
        stopSaverLoop()

        firestoreAlertReg?.remove()
        firestoreAlertReg = null

        runCatching { client.disconnect() }
        scope.cancel()
    }

}
