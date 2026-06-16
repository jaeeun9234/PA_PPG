package com.example.heartsync.data.remote

import android.util.Log
import com.example.heartsync.data.model.PpgEvent
import com.example.heartsync.data.model.toMap
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.tasks.await
import java.util.UUID
import kotlin.math.*

class PpgRepository(private val db: FirebaseFirestore) {

    companion object {
        private const val TAG = "PpgRepo"

        // ===== Collector와 동기화된 상수 =====
        private const val FS_HZ = 50
        private const val REFRACT_MS = 350.0
        private const val PEAK_WIN = 15
        private const val FOI_ALPHA = 0.1

        // 타이트한 튠
        private const val PAIR_TOL_MS = 100.0
        private const val MIN_RT_MS = 100.0

        private const val AUSPR_NORMAL_BAND = 0.30
        private const val HSI_TD_BASE = 40.0
        private const val HSI_TD_SCALE = 25.0
        private const val HSI_WARN = 1.5
        private const val HSI_HIGH = 3.0

        private const val AUSPR_SMOOTH_K = 5
        private const val AUSPR_CLAMP_LOW = 0.5
        private const val AUSPR_CLAMP_HIGH = 2.0

        // 저장 스로틀 (STAT 주기) — 현재는 5초 루프가 저장을 담당하므로 참고값
        private const val MIN_SAVE_INTERVAL_MS = 5_000L

        // ---- Live gate (BLE 연결 생존 타임아웃) ----
        private const val LIVE_GRACE_MS = 1500L
        @Volatile private var liveUntilMs: Long = 0L
        @Volatile private var writeEnabled: Boolean = false

        // === ALERT 디바운스 ===
        private const val ALERT_SUPPRESS_MS = 10_000L

        // === Transient(과도) 억제 ===
        private const val TRANSIENT_SUPPRESS_MS = 5_000L   // 압력 가한 뒤 15초간 팝업 완화
        @Volatile private var transientUntilMs: Long = 0L

        @Volatile private var lastAlertShownAt: Long = 0L
        @Volatile private var lastAlertSavedAt: Long = 0L
        @Volatile private var lastAlertRiskOrd: Int = 0


        private val recentRisks: ArrayDeque<String> = ArrayDeque()
        private const val RISK_WIN = 4          // 최근 4번 판단을 보고
        private const val RISK_NEED = 2         // 그 중 2번 이상이 WARN/HIGH면 팝업 허용
        private const val WARN_EXIT  = 1.0      // HSI가 여기까지 내려오면 “해제”로 보고 창 초기화

        private fun riskOrd(r: String?): Int = when (r) {
            "HIGH" -> 2
            "WARN" -> 1
            else -> 0
        }

        private fun markTransient(extraMs: Long = TRANSIENT_SUPPRESS_MS) {
            transientUntilMs = System.currentTimeMillis() + extraMs
            // 과도 진입 시, 최근 리스크 창도 리셋해서 연속조건이 바로 충족되지 않도록
            recentRisks.clear()
            lastAlertRiskOrd = 0
        }

        private fun isTransient(): Boolean = System.currentTimeMillis() <= transientUntilMs

        fun enableWrites(v: Boolean) { writeEnabled = v }
        fun isWriteEnabled(): Boolean = writeEnabled
        fun markLive() { liveUntilMs = System.currentTimeMillis() + LIVE_GRACE_MS }
        fun isLive(): Boolean = System.currentTimeMillis() <= liveUntilMs

        fun resetAlertDebounce(){
            lastAlertShownAt = 0L
            lastAlertRiskOrd = 0
            recentRisks.clear()
            transientUntilMs = 0L
        }

        fun onBleConnected() {
            enableWrites(true); markLive();
            instance.clearEngineState()
            resetAlertDebounce()
        }

        fun onBleDisconnected() {
            enableWrites(false); liveUntilMs = 0L;
            instance.clearEngineState()
            resetAlertDebounce()
        }

        // 그래프 스트림
        private val _smoothed = MutableSharedFlow<Triple<Long, Float, Float>>(replay = 1, extraBufferCapacity = 512)
        fun smoothed(): Flow<Triple<Long, Float, Float>> = _smoothed.asSharedFlow()
        fun smoothedThrottled(periodMs: Long): Flow<Triple<Long, Float, Float>> = _smoothed.sample(periodMs)
        fun emitSmoothed(ts: Long, l: Double, r: Double) { _smoothed.tryEmit(Triple(ts, l.toFloat(), r.toFloat())) }

        // ⚠️ ALERT 브로드캐스트 (팝업용)
        data class AlertInfo(
            val ts: Long,
            val hsi: Double,
            val risk: String,
            val auspr: Double?,
            val padMs: Double?,
            val side: String?
        )
        private val _alerts = MutableSharedFlow<AlertInfo>(extraBufferCapacity = 64)
        fun alerts(): Flow<AlertInfo> = _alerts.asSharedFlow()

        // 세션
        private var _sessionId: String? = null
        private var _lastRecordSavedAt: Long = 0L

        fun startNewSessionNow(): String {
            val now = System.currentTimeMillis()
            val stamp = java.text.SimpleDateFormat("yyyyMMdd_HHmmss_SSS", java.util.Locale.US)
                .format(java.util.Date(now))
            _sessionId = "S_$stamp"
            return _sessionId!!
        }
        fun canSaveNow(now: Long = System.currentTimeMillis()): Boolean {
            if (now - _lastRecordSavedAt >= MIN_SAVE_INTERVAL_MS) {
                _lastRecordSavedAt = now
                return true
            }
            return false
        }
        fun getSessionId(): String? = _sessionId
        fun setSessionIdIfEmpty() { if (_sessionId == null) startNewSessionNow() }
        fun currentSessionId(): String { setSessionIdIfEmpty(); return _sessionId!! }

        // AUSPR 안정화
        private val ausprHist = ArrayDeque<Double>()

        // 싱글턴
        @Volatile private var _instance: PpgRepository? = null
        val instance: PpgRepository
            get() = _instance ?: synchronized(this) {
                _instance ?: PpgRepository(FirebaseFirestore.getInstance()).also { _instance = it }
            }

        // === [ADD] ALERT 팝업 브로드캐스트(중복 방지 포함) ===
        @Volatile private var lastAlertEmitKey: String? = null
        @Volatile private var lastAlertEmitAt: Long = 0L
        private const val ALERT_COOLDOWN_MS = 10_000L

        @JvmStatic
        fun emitAlertOnce(
            ts: Long,
            hsi: Double?,
            risk: String?,
            auspr: Double?,
            padMs: Double?,
            side: String?
        ) {
            val now = System.currentTimeMillis()
            val ord = riskOrd(risk)
            val r = risk ?: "OK"
            val h = hsi ?: 0.0

            // [히스테리시스 해제]: HSI가 충분히 내려오면 최근 창과 등급 메모리 리셋
            if (h <= WARN_EXIT) {
                recentRisks.clear()
                lastAlertRiskOrd = 0
                Log.d(TAG, "ALERT window reset by hysteresis: HSI=$h <= $WARN_EXIT")
                return
            }

            // [과도 억제]: 과도 구간에선 WARN(등급1)은 팝업 억제, HIGH(등급2)만 허용
            if (isTransient() && ord < 1) {
                Log.d(TAG, "ALERT suppressed in transient window (risk=$r, HSI=$h)")
                return
            }

            // [최근 판단 창 업데이트]
            recentRisks.addLast(r)
            while (recentRisks.size > RISK_WIN) recentRisks.removeFirst()

            // WARN/HIGH 개수 집계
            val warnCnt = recentRisks.count { it == "WARN" || it == "HIGH" }
            val canEnter = warnCnt >= RISK_NEED

//            // [팝업 허용판단] : 지속성 조건 + (등급상승 즉시) + (시간 억제 종료)
//            val allow = when {
//                !canEnter -> false
//                ord > lastAlertRiskOrd -> true
//                (now - lastAlertShownAt) >= ALERT_SUPPRESS_MS -> true
//                else -> false
//            }

            val allow = canEnter && (now - lastAlertShownAt) >= ALERT_SUPPRESS_MS

            if (!allow) {
                Log.d(
                    TAG,
                    "ALERT popup suppressed (warnCnt=$warnCnt/$RISK_WIN, " +
                            "dt=${now - lastAlertShownAt}ms < $ALERT_SUPPRESS_MS, ord=$ord, last=$lastAlertRiskOrd)"
                )
                return
            }

            // [실제 브로드캐스트]
            _alerts.tryEmit(AlertInfo(ts, h, r, auspr, padMs, side))
            lastAlertShownAt = now
            lastAlertRiskOrd = max(lastAlertRiskOrd, ord)
        }

    }

    // ========= Firestore helpers =========
    private fun rootCol() = db.collection("ppg_events")
    private fun userDoc(uid: String) = rootCol().document(uid)
    private fun sessionsCol(uid: String) =
        db.collection("ppg_events").document(uid).collection("sessions")
    private fun sessionDoc(uid: String, sid: String) = sessionsCol(uid).document(sid)
    private fun recordsCol(uid: String, sid: String) = sessionDoc(uid, sid).collection("records")

    // 세션 문서는 최초 1회만 생성 (created_at 고정)
    private suspend fun ensureSession(uid: String, sid: String) {
        // 연결/저장 허용 아닐 때는 절대 세션 문서도 만들지 않음
        require(sid.isNotBlank()) { "sessionId must not be blank" }  // ✅ 안전장치
        val doc = sessionDoc(uid, sid)
        db.runTransaction { tr ->
            val snap = tr.get(doc)
            if (!snap.exists()) {
                tr.set(doc, mapOf(
                    "id" to sid,
                    "created_at" to FieldValue.serverTimestamp()
                ))
            }
            // 존재하면 created_at 포함 아무 것도 수정하지 않음
        }.await()
    }

    suspend fun uploadRecord(userId: String, sessionId: String, ev: PpgEvent): String {
        ensureSession(userId, sessionId)
        val uniqueId = "${ev.ts_ms}_${UUID.randomUUID().toString().take(8)}" // 🔹 랜덤 suffix 추가
        val doc = recordsCol(userId, sessionId).document(uniqueId)
        val data = ev.toMap(userId) + mapOf("server_ts" to FieldValue.serverTimestamp())
        doc.set(data, SetOptions.merge()).await()
        return doc.id
    }


    // ========= Beat Engine =========
    private data class Beat(val footIdx: Int, val peakIdx: Int, val AUSP: Double, val RTms: Double, val amp: Double)
    private data class SideState(
        val hist: MutableList<Double> = mutableListOf(),
        val buf: ArrayDeque<Pair<Int, Double>> = ArrayDeque(),
        val baseBuf: ArrayDeque<Double> = ArrayDeque(),
        val rtList: ArrayDeque<Int> = ArrayDeque(),
        var lastPeakIdx: Int = -9999,
        val lastPeaks: ArrayDeque<Int> = ArrayDeque(),   // BPM 계산용
        var lastBaseAmp: Double = 0.0
    )

    private val L = SideState()
    private val R = SideState()
    private val pendingL = ArrayDeque<Beat>()
    private val pendingR = ArrayDeque<Beat>()
    private var globalIdx = 0

    // ----- 최근 이벤트 스냅샷(5초 저장용) -----
    @Volatile private var lastEvent: PpgEvent? = null


    // ----- 엔진 초기화 -----
    fun clearEngineState() {
        L.hist.clear(); R.hist.clear()
        L.buf.clear(); R.buf.clear()
        L.baseBuf.clear(); R.baseBuf.clear()
        L.rtList.clear(); R.rtList.clear()
        L.lastPeakIdx = -9999; R.lastPeakIdx = -9999
        L.lastPeaks.clear(); R.lastPeaks.clear()
        pendingL.clear(); pendingR.clear()
        ausprHist.clear()
        globalIdx = 0
        _lastRecordSavedAt = 0L
        lastEvent = null
    }

    fun peekLastEvent(): PpgEvent? = lastEvent

    private fun idxToMs(idx: Int) = idx * 1000.0 / FS_HZ
    private fun msToIdx(ms: Double) = (ms * FS_HZ / 1000.0).toInt()

    private fun baseAmp(buf: ArrayDeque<Double>, hist: MutableList<Double>): Double {
        if (buf.isNotEmpty()) {
            val pos = buf.map { max(0.0, it) }
            return pos.average().coerceAtLeast(1e-6)
        }
        val n = minOf(hist.size, FS_HZ * 2)
        if (n > 0) {
            val seg = hist.takeLast(n).map { max(0.0, it) }
            val mean = seg.average()
            if (mean.isFinite() && mean > 0) return mean
        }
        return 1.0
    }

    private fun foiArea(hist: List<Double>, i0: Int, i1: Int, alpha: Double = FOI_ALPHA): Double {
        if (i1 <= i0 || i1 > hist.lastIndex) return 0.0
        val seg = hist.subList(i0, i1 + 1).map { max(0.0, it) }
        val n = seg.size
        val k = DoubleArray(n) { j -> (j + 1.0).pow(alpha - 1.0) }
        val sumK = k.sum().coerceAtLeast(1e-9)
        var acc = 0.0
        for (j in 0 until n) acc += seg[j] * (k[j] / sumK)
        return acc * n * (1.0 / FS_HZ)
    }

    private fun stableAuspr(raw: Double?): Double? {
        if (raw == null || !raw.isFinite()) return null
        ausprHist.addLast(raw)
        while (ausprHist.size > AUSPR_SMOOTH_K) ausprHist.removeFirst()
        val sorted = ausprHist.sorted()
        val med = sorted[sorted.size / 2]
        return med.coerceIn(AUSPR_CLAMP_LOW, AUSPR_CLAMP_HIGH)
    }

    // 최근 0.6s에서 foot→peak 추정 + FOI 적분
    private fun approxSide(hist: List<Double>): Triple<Double, Double, Double>? {
        val n = (0.6 * FS_HZ).toInt().coerceAtLeast(8)
        if (hist.size < n) return null
        val seg = hist.takeLast(n)

        val yMax = seg.maxOrNull() ?: return null
        val iMax = seg.indexOf(yMax)
        if (iMax < 2) return null
        val pre = seg.subList(0, iMax)
        val yMin = pre.minOrNull() ?: return null
        val iMin = pre.indexOf(yMin)

        val amp = (yMax - yMin).coerceAtLeast(0.0)
        val rtMs = ((iMax - iMin).coerceAtLeast(1)) * 1000.0 / FS_HZ

        val localBase = seg.map { max(0.0, it - yMin) }.average().coerceAtLeast(1e-6)

        var acc = 0.0
        val len = (iMax - iMin + 1).coerceAtLeast(1)
        val k = DoubleArray(len) { j -> (j + 1.0).pow(FOI_ALPHA - 1.0) }
        val sumK = k.sum().coerceAtLeast(1e-9)
        for (j in 0 until len) {
            val v = max(0.0, seg[iMin + j] - yMin)
            acc += v * (k[j] / sumK)
        }
        val ausp = (acc * len * (1.0 / FS_HZ)) / localBase
        return Triple(amp, rtMs, ausp)
    }

    private fun bpmFromPeaks(peaks: ArrayDeque<Int>): Double? {
        if (peaks.size < 2) return null
        val i2 = peaks.elementAt(peaks.size - 1)
        val i1 = peaks.elementAt(peaks.size - 2)
        val ibiSec = (i2 - i1).coerceAtLeast(1) / FS_HZ.toDouble()
        if (ibiSec <= 0.0) return null
        return 60.0 / ibiSec
    }

    private fun decideSide(auspr: Double?, signedDtMs: Double?): String {
        var score = 0
        val eps = 0.08 // AUSPR 8% 이상 편차일 때만 방향 반영
        if (auspr != null) {
            if (auspr > 1.0 + eps) score += 1   // Right 우세
            if (auspr < 1.0 - eps) score -= 1   // Left 우세
        }
        if (signedDtMs != null) {
            // tR - tL: 양수면 R이 늦음(=L 우세), 음수면 L이 늦음(=R 우세)
            if (signedDtMs > 20.0) score -= 1
            if (signedDtMs < -20.0) score += 1
        }
        return when {
            score > 0 -> "R"
            score < 0 -> "L"
            else -> "-"
        }
    }

    private fun pushOne(S: SideState, y: Double) {
        S.hist.add(y)
        S.buf.addLast(globalIdx to y)
        if (S.buf.size > PEAK_WIN) S.buf.removeFirst()

        S.baseBuf.addLast(y)
        while (S.baseBuf.size > FS_HZ * 10) S.baseBuf.removeFirst()

        if (S.buf.size == PEAK_WIN) {
            val mid = PEAK_WIN / 2
            val (iMid, yMid) = S.buf.elementAt(mid)
            val yPrev = S.buf.elementAt(mid - 1).second
            val yNext = S.buf.elementAt(mid + 1).second
            if (yMid > yPrev && yMid > yNext && (iMid - S.lastPeakIdx) >= msToIdx(REFRACT_MS)) {
                // prominence 기반 동적 임계 (타이트)
                val footRange = min(8, mid)
                val (minIdx, minVal) = (0 until footRange).map { S.buf.elementAt(it) }.minByOrNull { p -> p.second }!!
                val prom = yMid - minVal
                val ampScale = baseAmp(S.baseBuf, S.hist)
                if (prom < max(30.0, 0.20 * ampScale)) return // 피크로 취급 안 함

                val absThresh = 1.2
                val relThresh = 0.15 * ampScale
                val promThresh = max(absThresh, relThresh)

                if (prom >= promThresh && (iMid - S.lastPeakIdx) >= msToIdx(REFRACT_MS)) {
                    val rt = (iMid - minIdx) * 1000.0 / FS_HZ
                    if (rt >= MIN_RT_MS) {
                        val ausp = foiArea(S.hist, minIdx, iMid) / ampScale
                        val b = Beat(minIdx, iMid, ausp, rt, prom)
                        if (S === L) pendingL.add(b) else pendingR.add(b)
                        S.lastPeakIdx = iMid

                        // BPM 계산용 peak 히스토리
                        S.lastPeaks.addLast(iMid)
                        while (S.lastPeaks.size > 6) S.lastPeaks.removeFirst()

                        val prev = S.lastBaseAmp
                        if (prev > 1e-6) {
                            val relJump = kotlin.math.abs(ampScale - prev) / prev
                            // 25% 이상 급변하면 과도 구간으로 간주 (양쪽 손가락 중 하나라도)
                            if (relJump >= 0.25) {
                                markTransient() // 기본 15초
                                Log.d(TAG, "Transient marked (relJump=${"%.2f".format(relJump)}, side=${if (S===L) "L" else "R"})")
                            }
                        }
                        S.lastBaseAmp = if (ampScale.isFinite()) ampScale else prev
                    }
                }
            }
        }
    }

    private fun pairBeats(): Pair<Beat, Beat>? {
        if (pendingL.isEmpty() || pendingR.isEmpty()) return null
        val bL = pendingL.removeFirst()
        var bestJ = -1
        var bestD = Double.POSITIVE_INFINITY
        for (j in pendingR.indices) {
            val d = abs(idxToMs(bL.peakIdx) - idxToMs(pendingR[j].peakIdx))
            if (d <= PAIR_TOL_MS && d < bestD) { bestD = d; bestJ = j }
        }
        return if (bestJ >= 0) {
            val bR = pendingR.removeAt(bestJ)
            bL to bR
        } else null
    }

    // ========= 외부에서 호출: 1줄 파싱 → 처리 (저장은 하지 않음) =========
    suspend fun trySaveFromLine(line: String) {
        if (line.isBlank() || line == "null") return

        // 이 줄은 BLE notify 기반 수신임을 갱신
        markLive()

        // key=value 토큰 파싱
        val kv = mutableMapOf<String, String>()
        line.split(' ', '\t', ',').forEach { tok ->
            val i = tok.indexOf('=')
            if (i in 1 until tok.lastIndex) kv[tok.substring(0, i)] = tok.substring(i + 1)
        }

        // 공통 파싱
        val ts  = (kv["ts_ms"] ?: kv["ts"])?.toLongOrNull() ?: System.currentTimeMillis()
        val l   = kv["smoothed_left"]?.toDoubleOrNull() ?: kv["PPGf_L"]?.toDoubleOrNull()
        val r   = kv["smoothed_right"]?.toDoubleOrNull()?: kv["PPGf_R"]?.toDoubleOrNull()
        // 그래프 스트림(옵션)
        if (l != null && r != null) emitSmoothed(ts, l, r)

        // ==== [1] ODP(온디바이스) 산출치가 있으면 "그대로" 사용 (팝업/캐시/저장) ====
        //  - 파이썬/OnDeviceProcessor가 이미 HSI, risk, AUSPR, DeltaTD_ms 등을 계산해 보낸 경우
        val riskStr  = kv["risk"]
        val hsiVal   = kv["HSI"]?.toDoubleOrNull()
        val ausprVal = kv["AUSPR"]?.toDoubleOrNull()
        val padVal   = (kv["DeltaTD_ms"] ?: kv["PAD_ms"])?.toDoubleOrNull()
        val sideRaw  = kv["side"]?.lowercase()

        // side 정규화: "left/right/null" -> "L/R/-"
        val sideNorm: String? = when (sideRaw) {
            "left", "l"  -> "L"
            "right", "r" -> "R"
            "null", "none", "-", "", null -> "-"
            else -> sideRaw // 혹시 다른 문자열이 오면 그대로 보존
        }

        if (!riskStr.isNullOrBlank() && hsiVal != null) {
            // ODP가 risk를 계산해 보냈다면 그걸 신뢰
            val eventType = if (riskStr != "OK") "ALERT" else "STAT"

            // 팝업: 위험이면 즉시
            if (riskStr != "OK") {
                emitAlertOnce(ts, hsiVal, riskStr, ausprVal, padVal, sideNorm)
            }

            // 최신 이벤트 캐시 (저장 루프가 5초마다 스냅샷 저장)
            lastEvent = PpgEvent(
                event = eventType,
                host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString(),
                ts_ms = ts,
                smoothed_left  = l,
                smoothed_right = r,
                AUSPR = ausprVal,
                PAD_ms = padVal,
                HSI = hsiVal,
                risk = riskStr,
                alert_type = if (riskStr != "OK") "asymmetry" else null,
                side = sideNorm
            )

            // ✅ ODP 값을 존중하고 여기서 종료 — 아래 BeatEngine 재계산으로 내려가지 않음
            globalIdx++
            return
        }

        // ==== [2] (ODP 산출치가 없을 경우에만) 기존 BeatEngine 경로 ====
        if (l == null || r == null) {
            // 입력이 부족하면 더 진행 불가
            return
        }

        // BeatEngine 처리
        pushOne(L, l); pushOne(R, r)
        val pair = pairBeats()

        var ev = PpgEvent(
            event = "STAT",
            host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString(),
            ts_ms = ts,
            smoothed_left = l,
            smoothed_right = r,
        )
        var outRisk = "OK"
        var outHsi = 0.0
        var outAuspr: Double? = null
        var outPadMs: Double? = null
        var outSide: String? = null

        if (pair != null) {
            val (bL, bR) = pair

            val tL = idxToMs(bL.peakIdx)
            val tR = idxToMs(bR.peakIdx)
            val signedDtMs = tR - tL
            val dt_ms = kotlin.math.abs(signedDtMs)

            val ampRatio = if (bL.amp > 1e-6) bR.amp / bL.amp else null
            val ausprRaw = if (bL.AUSP > 1e-9) bR.AUSP / bL.AUSP else null
            val auspr = stableAuspr(ausprRaw)

            val tol = ln(1.0 + AUSPR_NORMAL_BAND)
            val term1 = if (auspr != null) abs(ln(max(auspr, 1e-6))) / tol else 0.0
            val term2 = max(0.0, dt_ms - HSI_TD_BASE) / HSI_TD_SCALE
            val hsi = term1 + term2
            val risk = when {
                hsi >= HSI_HIGH -> "HIGH"
                hsi >= HSI_WARN -> "WARN"
                else -> "OK"
            }

            val reasons = mutableListOf<String>()
            if (auspr != null && term1 >= 1.0) reasons += "AUSPR off-range"
            if (dt_ms > 60.0) reasons += "PWTT high"
            val reasonsOut: List<String>? = if (reasons.isEmpty()) null else reasons

            val bpmL = bpmFromPeaks(L.lastPeaks)
            val bpmR = bpmFromPeaks(R.lastPeaks)
            val side = decideSide(auspr, signedDtMs)

            ev = PpgEvent(
                event = if (risk != "OK") "ALERT" else "STAT",
                host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString(),
                ts_ms = ts,
                smoothed_left = l, smoothed_right = r,
                ampL = bL.amp, ampR = bR.amp,
                AmpRatio = ampRatio,
                AUSP_L = bL.AUSP, AUSP_R = bR.AUSP,
                AUSPR = auspr, PAD_ms = dt_ms,
                SUTL_ms = bL.RTms, SUTR_ms = bR.RTms,
                dSUT_ms = bR.RTms - bL.RTms,
                HSI = hsi, risk = risk,
                alert_type = if (risk != "OK") "asymmetry" else null,
                reasons = reasonsOut,
                BPM_L = bpmL, BPM_R = bpmR,
                side = side
            )

            outRisk = risk; outHsi = hsi; outAuspr = auspr; outPadMs = dt_ms; outSide = side
        } else {
            // ---- approx 저장 조건 엄격화 ----
            val lastPL = L.lastPeaks.lastOrNull()
            val lastPR = R.lastPeaks.lastOrNull()
            val approxAllowed =
                lastPL != null && lastPR != null &&
                        kotlin.math.abs(idxToMs(lastPR) - idxToMs(lastPL)) <= 400.0 // 좌우 최근 피크 시차 제한

            val approxL = approxSide(L.hist)
            val approxR = approxSide(R.hist)
            val canComputeAuspr =
                approxL != null && approxR != null &&
                        approxL.first > 1e-6 && approxR.first > 1e-6 // amp>0

            val signedDtMs: Double? =
                if (lastPL != null && lastPR != null) idxToMs(lastPR) - idxToMs(lastPL) else null
            val dt_ms = signedDtMs?.let { kotlin.math.abs(it) }

            if (!(approxAllowed && canComputeAuspr && dt_ms != null)) {
                globalIdx++
                return
            }

            val (ampL, rtL, auspL) = approxL!!
            val (ampR, rtR, auspR) = approxR!!

            val auspr = if (auspL > 1e-9) stableAuspr(auspR / auspL) else null

            val term1 = if (auspr != null) abs(ln(max(auspr, 1e-6))) / ln(1.0 + AUSPR_NORMAL_BAND) else 0.0
            val term2 = max(0.0, dt_ms!! - HSI_TD_BASE) / HSI_TD_SCALE
            val hsi = term1 + term2
            val risk = when {
                hsi >= HSI_HIGH -> "HIGH"
                hsi >= HSI_WARN -> "WARN"
                else -> "OK"
            }

            val reasons = mutableListOf<String>()
            if (auspr != null && term1 >= 1.0) reasons += "AUSPR off-range"
            if (dt_ms > 40.0) reasons += "PWTT high"
            val reasonsOut: List<String>? = if (reasons.isEmpty()) null else reasons

            val bpmL = bpmFromPeaks(L.lastPeaks)
            val bpmR = bpmFromPeaks(R.lastPeaks)
            val side = decideSide(auspr, signedDtMs)

            ev = ev.copy(
                event = if (risk != "OK") "ALERT" else "STAT",
                host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString(),
                ts_ms = ts,
                smoothed_left = l, smoothed_right = r,
                ampL = ampL, ampR = ampR,
                AmpRatio = if (ampL > 1e-6) ampR / ampL else null,
                AUSP_L = auspL, AUSP_R = auspR,
                AUSPR = auspr, PAD_ms = dt_ms,
                SUTL_ms = rtL, SUTR_ms = rtR, dSUT_ms = if (rtL > 0 && rtR > 0) rtR - rtL else null,
                HSI = hsi, risk = risk,
                alert_type = if (risk != "OK") "asymmetry" else null,
                reasons = reasonsOut,
                BPM_L = bpmL, BPM_R = bpmR,
                side = side
            )

            outRisk = risk; outHsi = hsi; outAuspr = auspr; outPadMs = dt_ms; outSide = side
        }

        // 🔹 최신 이벤트 캐시 (5초 주기 저장에서 사용)
        lastEvent = ev

        // 🔔 팝업 브로드캐스트: 위험이면 즉시
        if (outRisk != "OK") {
            emitAlertOnce(ts, outHsi, outRisk, outAuspr, outPadMs, outSide)
        }

        globalIdx++
    }


    // 🔹 5초 주기 스냅샷 저장: 마지막 이벤트 기반으로 현재 시각으로 기록
    suspend fun savePeriodicSnapshot() {
        if (!isWriteEnabled()) return
        val baseEv = lastEvent ?: return

        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return
        setSessionIdIfEmpty()
        val sid = currentSessionId()
        ensureSession(uid, sid)

        val nowTs = System.currentTimeMillis()
        val snap = baseEv.copy(
            ts_ms = nowTs,
            host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString()
        )
        val data = snap.toMap(uid) + mapOf("server_ts" to FieldValue.serverTimestamp())
        recordsCol(uid, sid).document(snap.ts_ms.toString())
            .set(data, SetOptions.merge()).await()
        Log.d(TAG, "Saved periodic snapshot: event=${snap.event}")
    }

    // 🔹 MeasureService 전용: uid/sid가 이미 있을 때 호출하는 5초 저장 API
    suspend fun writeSnapshotEvery5s(uid: String, sid: String) {
        if (!isWriteEnabled()) return
        //if (!canSaveNow()) return
        val baseEv = lastEvent ?: return
        ensureSession(uid, sid)

        val nowTs = System.currentTimeMillis()
        val snap = baseEv.copy(
            ts_ms = nowTs,
            host_time_iso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString()
        )

        // 🔹 event, alert_type 등은 그대로 두되, 모든 데이터를 단일 스트림으로 저장
        val data = snap.toMap(uid) + mapOf(
            "server_ts" to FieldValue.serverTimestamp(),
            "source" to "snapshot"
        )

        // 🔹 항상 SNAP_ prefix로 ID 생성
        val docId = "${nowTs}"

        recordsCol(uid, sid).document(docId)
            .set(data, SetOptions.merge()).await()

        Log.d(TAG, "Saved snapshot (every 5s) ts=$nowTs")
    }


    // (옵션) 최근 기록 observe — 필요 시 유지
    fun observeRecent(userId: String, sessionId: String, limit: Long = 512L): Flow<List<PpgEvent>> = callbackFlow {
        val ref = recordsCol(userId, sessionId)
            .orderBy("server_ts", Query.Direction.ASCENDING)
            .limit(limit)

        val reg = ref.addSnapshotListener { snap, err ->
            if (err != null || snap == null) { trySend(emptyList()).isSuccess; return@addSnapshotListener }
            val list = snap.documents.mapNotNull { d ->
                try {
                    val ts = d.getLong("ts_ms") ?: d.getTimestamp("server_ts")?.toDate()?.time ?: 0L
                    PpgEvent(
                        event = d.getString("event") ?: "STAT",
                        host_time_iso = d.getString("host_time_iso") ?: "",
                        ts_ms = ts,
                        ampL = d.getDouble("ampL"),
                        ampR = d.getDouble("ampR"),
                        AmpRatio = d.getDouble("AmpRatio"),
                        AUSP_L = d.getDouble("AUSP_L"),
                        AUSP_R = d.getDouble("AUSP_R"),
                        AUSPR = d.getDouble("AUSPR"),
                        PAD_ms = d.getDouble("PAD_ms"),
                        SUTL_ms = d.getDouble("SUTL_ms"),
                        SUTR_ms = d.getDouble("SUTR_ms"),
                        dSUT_ms = d.getDouble("dSUT_ms"),
                        HSI = d.getDouble("HSI"),
                        risk = d.getString("risk"),
                        smoothed_left = d.getDouble("smoothed_left"),
                        smoothed_right = d.getDouble("smoothed_right"),
                        alert_type = d.getString("alert_type"),
                        reasons = (d.get("reasons") as? List<*>)?.mapNotNull { it as? String }
                    )
                } catch (_: Throwable) { null }
            }
            trySend(list).isSuccess
        }
        awaitClose { reg.remove() }
    }
}
