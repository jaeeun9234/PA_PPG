package com.example.heartsync.ppg

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * RAW(timestamp,left,right) → 평활화 → 피크/풋 탐지 → 지표 산출
 * - ampL/ampR: 최근 2초 창의 (max - min) 진폭
 * - AmpRatio  : ampR / ampL (최근 2초 진폭 비율)   <-- R/L
 * - PAD_ms    : 오른쪽 foot - 왼쪽 foot (ms)       <-- R - L
 * - SUTL/R_ms : foot→peak 시간 (CT)
 * - BPM_L/R   : 피크-피크 평균으로 계산
 * - PPI_L/R_ms: 최근 피크-피크 간격(ms)
 * - UpSlope   : (peak - foot) / SUT (ms)  — 최근 비트 기준
 */

class PpgProcessor(
    private val fs: Int = 30,
    private val statHz: Int = 1,
    private val minPeakDistanceSec: Double = 0.4,   // 150 bpm 상한
    private val minPeakProminence: Int = 8,         // ADC 12bit 대략값
    private val smoothWin: Int = 5,
    private val ampWindowSec: Double = 2.0          // amp(2초 창) 계산
) {
    data class Peak(val idx: Int, val ampBeat: Double, val footIdx: Int, val sutMs: Double)

    data class Stat(
        val tsMsRel: Long,

        // 최근 2초 창 진폭 & 비율
        val ampL: Double?, val ampR: Double?,     // (max-min) over 2s
        val ampRatio: Double?,                    // ampR / ampL  (R/L)

        // 박동 기반 지표
        val BPM_L: Double?, val BPM_R: Double?,
        val PPI_L_ms: Double?, val PPI_R_ms: Double?,
        val SUTL_ms: Double?, val SUTR_ms: Double?,
        val PAD_ms: Double?,                     // foot_R - foot_L
        val dSUT_ms: Double?,                    // SUT_R - SUT_L
        val UpSlope_L: Double?, val UpSlope_R: Double?,   // (peak-foot)/SUT

        // 시각화용
        val smoothed_left: Double,
        val smoothed_right: Double
    )

    data class Alert(
        val tsMsRel: Long,
        val type: String,
        val reasons: List<String>,
        val ref: Stat,
        val side:String? =null
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _stat = MutableSharedFlow<Stat>(extraBufferCapacity = 4)
    val stat: SharedFlow<Stat> = _stat.asSharedFlow()
    private val _alert = MutableSharedFlow<Alert>(extraBufferCapacity = 4)
    val alert: SharedFlow<Alert> = _alert.asSharedFlow()

    private val tBuf = ArrayList<Long>(fs * 30)
    private val lBuf = ArrayList<Double>(fs * 30)
    private val rBuf = ArrayList<Double>(fs * 30)

    private var lastStatMs = 0L
    private var lastPeakL = ArrayDeque<Peak>()
    private var lastPeakR = ArrayDeque<Peak>()

    // ================== ALERT 디바운싱 창 ==================
    private class ConditionWindow(private val capacity: Int) {
        private val buf = ArrayDeque<Boolean>(capacity)
        fun push(v: Boolean) {
            if (buf.size == capacity) buf.removeFirst()
            buf.addLast(v)
        }
        fun rateTrue(): Double {
            if (buf.isEmpty()) return 0.0
            val c = buf.count { it }
            return c.toDouble() / buf.size.toDouble()
        }
        fun clear() = buf.clear()
    }

    private val alertWinSeconds = 3              // 3초 창
    private val alertSustainRatio = 1.0          // 창 중 100% 이상일 때 발화
    private val winCap = max(2, alertWinSeconds * statHz)
    private val leftWin  = ConditionWindow(winCap)
    private val rightWin = ConditionWindow(winCap)
    private val asymWin  = ConditionWindow(winCap)

    private val ALERT_COOLDOWN_MS = 10_000L   // 같은 조건 재팝업 최소 간격 (10초)
    private var lastAlertTimeMs = 0L

    // ================== 임계값(초기값; 추후 튜닝 권장) ==================
    private val TH_SUT_HIGH_MS    = 120.0     // SUTL/SUTR > 120ms
    private val TH_UPSLOPE_LOW    = 0.35      // UpSlope < 0.35
    private val TH_AMP_LOW        = 30.0      // amp < 30 (최근 2초)
    private val TH_PAD_ABS_MS     = 30.0      // |PAD| > 30ms
    private val TH_dSUT_ABS_MS    = 20.0      // |ΔSUT| > 20ms
    private val TH_AMP_RATIO_DEV  = 0.20      // |AmpRatio-1| > 0.20 (R/L)
    private val TH_dUPSLOPE_ABS   = 0.25      // |UpSlope_L - UpSlope_R| > 0.25
    private val TH_dPPI_ABS_MS    = 150.0     // |PPI_L - PPI_R| > 150ms

    fun addSample(tUs: Long, left: Int, right: Int) {
        val tMs = tUs / 1000L
        tBuf.add(tMs)
        lBuf.add(left.toDouble())
        rBuf.add(right.toDouble())
        // 30초 슬라이딩
        val keep = fs * 30
        if (lBuf.size > keep) {
            val drop = lBuf.size - keep
            repeat(drop) { tBuf.removeAt(0); lBuf.removeAt(0); rBuf.removeAt(0) }
        }
        processIfNeeded()
    }

    private fun processIfNeeded() {
        if (tBuf.isEmpty()) return
        val now = tBuf.last()
        val every = 1000L / statHz
        if (now - lastStatMs < every) return
        lastStatMs = now

        // 1) 평활화
        val sl = smooth(lBuf, smoothWin)
        val sr = smooth(rBuf, smoothWin)

        // 2) 피크/풋 탐지 (최근 8개 유지)
        val pkL = detectPeaks(sl, fs, minPeakDistanceSec, minPeakProminence)
        val pkR = detectPeaks(sr, fs, minPeakDistanceSec, minPeakProminence)
        keepLastN(lastPeakL, pkL, 8)
        keepLastN(lastPeakR, pkR, 8)

        // 3) 창 진폭 (최근 2초)
        val ampWin = (ampWindowSec * fs).toInt().coerceAtLeast(1)
        val ampL2s = windowAmp(sl, ampWin)
        val ampR2s = windowAmp(sr, ampWin)
        val ampRatio = if (ampL2s != null && ampR2s != null && ampL2s > 1e-9) ampR2s / ampL2s else null  // R/L

        // 4) BPM, PPI
        val bpmL = bpm(lastPeakL, fs)
        val bpmR = bpm(lastPeakR, fs)
        val ppiL = ppiMs(lastPeakL, fs) // 최근 한 구간(ms)
        val ppiR = ppiMs(lastPeakR, fs)

        // 5) SUT, PAD(foot 차)
        val pL = lastPeakL.lastOrNull()
        val pR = lastPeakR.lastOrNull()
        val sutL = pL?.sutMs
        val sutR = pR?.sutMs
        val padMs: Double? = if (pL != null && pR != null) {
            val t0 = tBuf.first()
            val tFootL = t0 + (pL.footIdx * 1000L / fs)
            val tFootR = t0 + (pR.footIdx * 1000L / fs)
            (tFootR - tFootL).toDouble() // 정의: Right - Left
        } else null
        val dSut = if (sutL != null && sutR != null) sutR - sutL else null // SUT_R - SUT_L

        // 6) Upstroke slope (= (peak-foot)/SUT) — 최근 비트
        val upSlopeL = if (pL != null && pL.sutMs > 0.0) pL.ampBeat / pL.sutMs else null
        val upSlopeR = if (pR != null && pR.sutMs > 0.0) pR.ampBeat / pR.sutMs else null

        val st = Stat(
            tsMsRel = now - tBuf.first(),
            ampL = ampL2s, ampR = ampR2s,
            ampRatio = ampRatio,
            BPM_L = bpmL, BPM_R = bpmR,
            PPI_L_ms = ppiL, PPI_R_ms = ppiR,
            SUTL_ms = sutL, SUTR_ms = sutR,
            PAD_ms = padMs,
            dSUT_ms = dSut,
            UpSlope_L = upSlopeL, UpSlope_R = upSlopeR,
            smoothed_left = sl.last(), smoothed_right = sr.last()
        )
        _stat.tryEmit(st)

        // 7) ALERT (새 기준)
        checkAndEmitAlerts(st)
    }

    // ================== ALERT 로직 (왼/오/좌우 비교 3개) ==================
    private fun checkAndEmitAlerts(st: Stat) {
        val SUTL = st.SUTL_ms
        val SUTR = st.SUTR_ms
        val UpSlopeL = st.UpSlope_L
        val UpSlopeR = st.UpSlope_R
        val ampL = st.ampL
        val ampR = st.ampR

        val PAD = st.PAD_ms                   // R - L
        val dSUT = st.dSUT_ms                 // SUT_R - SUT_L
        val ampRatio = st.ampRatio            // R / L
        val dUpSlope = if (UpSlopeL != null && UpSlopeR != null) UpSlopeL - UpSlopeR else null
        val dPPI = if (st.PPI_L_ms != null && st.PPI_R_ms != null) st.PPI_L_ms - st.PPI_R_ms else null

        // 1) Left-only (3개 중 2개 충족)
        val cL = listOf(
            (SUTL ?: 0.0) > TH_SUT_HIGH_MS,
            (UpSlopeL ?: 1.0) < TH_UPSLOPE_LOW,
            (ampL ?: 1e9) < TH_AMP_LOW
        )
        val leftHitNow = cL.count { it } >= 2
        leftWin.push(leftHitNow)
        // 1) Left-only ...
        if (leftWin.rateTrue() >= alertSustainRatio) {
            val reasons = buildList {
                if (cL[0]) add("SUTL high(>${TH_SUT_HIGH_MS.toInt()}ms)")
                if (cL[1]) add("UpSlope_L low(<$TH_UPSLOPE_LOW)")
                if (cL[2]) add("Left amp low(<${TH_AMP_LOW.toInt()})")
            }

            if (reasons.isNotEmpty()) {
                // ampL/ampR 는 Double? 이므로 null 가드
                val inferredSide = if (st.ampL != null && st.ampR != null) {
                    when {
                        st.ampL < st.ampR -> "left"
                        st.ampR < st.ampL -> "right"
                        else -> "-"
                    }
                } else "-"

                val finalSide: String? = if (inferredSide == "-") null else inferredSide
                val sanitizedReasons = reasons.map {
                    if (it.equals("-", ignoreCase = true)) "asymmetry" else it
                }.distinct()

                _alert.tryEmit(
                    Alert(
                        tsMsRel = st.tsMsRel,          // ← 이름 정정(tsMs → tsMsRel)
                        type    = "asymmetry",
                        reasons = sanitizedReasons,
                        ref     = st,                  // ← 이름 정정(stat → ref)
                        side    = finalSide            // ← Alert에 side 추가했을 때만 유지
                    )
                )
                leftWin.clear()                         // ← 좌측 창만 초기화
            }
        }


        // 2) Right-only (3개 중 2개 충족)
        val cR = listOf(
            (SUTR ?: 0.0) > TH_SUT_HIGH_MS,
            (UpSlopeR ?: 1.0) < TH_UPSLOPE_LOW,
            (ampR ?: 1e9) < TH_AMP_LOW
        )
        val rightHitNow = cR.count { it } >= 2
        rightWin.push(rightHitNow)
        // 2) Right-only ...
        if (rightWin.rateTrue() >= alertSustainRatio) {
            val reasons = buildList {
                if (cR[0]) add("SUTR high(>${TH_SUT_HIGH_MS.toInt()}ms)")
                if (cR[1]) add("UpSlope_R low(<$TH_UPSLOPE_LOW)")
                if (cR[2]) add("Right amp low(<${TH_AMP_LOW.toInt()})")
            }
            if (reasons.isNotEmpty()) {
                val now = st.tsMsRel
                if (now - lastAlertTimeMs >= ALERT_COOLDOWN_MS) {   // ← >= 로 수정
                    lastAlertTimeMs = now
                    _alert.tryEmit(
                        Alert(
                            tsMsRel = st.tsMsRel,
                            type    = "right_perfusion_slow",
                            reasons = reasons,
                            ref     = st,
                            side    = "right"
                        )
                    )
                    rightWin.clear()
                }
            }
        }


        // 3) Left-Right asymmetry (트리거 ≥1 && 보조 ≥1)
        val trigNow = listOf(
            abs(PAD ?: 0.0) > TH_PAD_ABS_MS,
            abs(dSUT ?: 0.0) > TH_dSUT_ABS_MS
        )
        val auxNow = listOf(
            abs((ampRatio ?: 1.0) - 1.0) > TH_AMP_RATIO_DEV,  // R/L 기준
            abs(dUpSlope ?: 0.0) > TH_dUPSLOPE_ABS,
            abs(dPPI ?: 0.0) > TH_dPPI_ABS_MS
        )
        val asymNow = (trigNow.any { it }) && (auxNow.any { it })
        asymWin.push(asymNow)
        if (asymWin.rateTrue() >= alertSustainRatio) {
            val reasons = buildList {
                if (trigNow[0]) add("PAD>|${TH_PAD_ABS_MS.toInt()} ms|")
                if (trigNow[1]) add("ΔSUT>|${TH_dSUT_ABS_MS.toInt()} ms|")
                if (auxNow[0]) add("AmpRatio out-of-range(±${(TH_AMP_RATIO_DEV*100).toInt()}%)")
                if (auxNow[1]) add("ΔUpSlope>|$TH_dUPSLOPE_ABS|")
                if (auxNow[2]) add("PPI Δ>|${TH_dPPI_ABS_MS.toInt()} ms|")
            }
            // side: PAD 부호(우선) → dSUT 부호
            val side = when {
                (PAD ?: 0.0) > 0.0 -> "right"   // R 늦음
                (PAD ?: 0.0) < 0.0 -> "left"    // L 늦음
                (dSUT ?: 0.0) > 0.0 -> "right"  // SUT_R > SUT_L → R 느림
                (dSUT ?: 0.0) < 0.0 -> "left"
                else -> "uncertain"
            }
            if (reasons.isNotEmpty()) {
                // ref에 side를 넣고 싶으면 Stat에 side 필드를 추가 후 copy 사용
                val now = st.tsMsRel
                if (now - lastAlertTimeMs >= ALERT_COOLDOWN_MS) {  // 쿨다운 중이면 무시
                    lastAlertTimeMs = now

                    _alert.tryEmit(Alert(st.tsMsRel, "asymmetry", reasons, st))
                    asymWin.clear()
                }
            }
        }
    }

    // ================== 신호 처리 유틸 ==================
    private fun smooth(x: List<Double>, w: Int): List<Double> {
        if (x.isEmpty() || w <= 1) return x
        val half = w / 2
        val out = DoubleArray(x.size)
        for (i in x.indices) {
            var s = 0.0; var c = 0
            for (k in (i - half)..(i + half)) if (k in x.indices) { s += x[k]; c++ }
            out[i] = s / c
        }
        return out.asList()
    }

    private fun detectPeaks(
        x: List<Double>, fs: Int, minDistSec: Double, minProm: Int
    ): List<Peak> {
        if (x.size < 3) return emptyList()
        val minDist = (minDistSec * fs).toInt().coerceAtLeast(1)
        val peaks = ArrayList<Peak>()
        var lastIdx = -minDist
        for (i in 1 until x.lastIndex) {
            if (x[i] > x[i-1] && x[i] >= x[i+1]) {
                if (i - lastIdx < minDist) continue
                val leftMin = (max(0, i - fs/2) until i).minByOrNull { x[it] } ?: 0
                val prom = x[i] - x[leftMin]
                if (prom < minProm) continue
                val footIdx = leftMin
                val sutMs = (i - footIdx) * 1000.0 / fs
                val ampBeat = x[i] - x[footIdx]  // 비트 기반 진폭(UpSlope 계산용)
                peaks += Peak(i, ampBeat, footIdx, sutMs)
                lastIdx = i
            }
        }
        return peaks
    }

    private fun keepLastN(dst: ArrayDeque<Peak>, src: List<Peak>, n: Int) {
        dst.clear()
        src.takeLast(n).forEach { dst.addLast(it) }
    }

    private fun windowAmp(x: List<Double>, win: Int): Double? {
        if (x.isEmpty()) return null
        val n = x.size
        val from = (n - win).coerceAtLeast(0)
        var mn = Double.POSITIVE_INFINITY
        var mx = Double.NEGATIVE_INFINITY
        for (i in from until n) {
            if (x[i] < mn) mn = x[i]
            if (x[i] > mx) mx = x[i]
        }
        val amp = mx - mn
        return if (amp.isFinite()) amp else null
    }

    private fun bpm(peaks: ArrayDeque<Peak>, fs: Int): Double? {
        if (peaks.size < 2) return null
        val idxs = peaks.map { it.idx }
        val dts = idxs.zip(idxs.drop(1)).map { (a, b) -> (b - a).toDouble() / fs }
        val mean = dts.average()
        return if (mean > 0) 60.0 / mean else null
    }

    /** 최근 한 구간의 PPI(ms) */
    private fun ppiMs(peaks: ArrayDeque<Peak>, fs: Int): Double? {
        if (peaks.size < 2) return null
        val last = peaks.last().idx
        val prev = peaks.elementAt(peaks.size - 2).idx
        return (last - prev) * 1000.0 / fs
    }

    companion object {
        val instance: PpgProcessor by lazy { PpgProcessor() }
    }
}
