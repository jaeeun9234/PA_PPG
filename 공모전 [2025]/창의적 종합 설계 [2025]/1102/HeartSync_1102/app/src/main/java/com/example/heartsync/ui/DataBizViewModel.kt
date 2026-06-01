// app/src/main/java/com/example/heartsync/ui/DataBizViewModel.kt
package com.example.heartsync.ui

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.ui.model.MetricStat
import com.example.heartsync.ui.model.DayMetrics
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.time.*
import java.time.format.DateTimeFormatter
import kotlin.math.* // ln, abs, max

/**
 * 날짜별 요약 집계 전용 ViewModel
 * - Firestore collectionGroup("records")에서 server_ts로 날짜 필터
 * - 러닝 통계로 요약 (O(1) 메모리)
 * - 지표: AUSPR / PWTT(ms) / HSI
 *   (※ PWTT는 DB의 PAD_ms를 alias로 읽음: PpgRepository에서 좌/우 피크 시차를 PAD_ms로 저장중)
 */
class DataBizViewModel : ViewModel() {

    private val db = FirebaseFirestore.getInstance()

    private var fullJob: Job? = null
    private var metricsStopper: (() -> Unit)? = null

    private companion object {
        private const val TAG = "DataViz"
    }

    // 상태
    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _lastFullCount = MutableStateFlow(0)
    val lastFullCount: StateFlow<Int> = _lastFullCount.asStateFlow()

    private val _debugStatus = MutableStateFlow("idle")
    val debugStatus: StateFlow<String> = _debugStatus.asStateFlow()

    private val _dayMetrics = MutableStateFlow<DayMetrics?>(null)
    val dayMetrics: StateFlow<DayMetrics?> = _dayMetrics.asStateFlow()

    /**
     * 버튼/사용자 트리거로: 하루치 전체를 페이지네이션으로 읽어 정확 요약
     * - AUSPR / PWTT / HSI 집계
     * - PWTT(ms)는 PAD_ms alias 사용
     */
    fun refreshDaySummaryPaged(
        uid: String,
        date: LocalDate,
        zone: ZoneId = ZoneId.of("Asia/Seoul"),
        pageSize: Long = 3000L,
        force: Boolean = false
    ) {
        if (_isLoading.value && !force) return
        if (force) fullJob?.cancel()

        fullJob = viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            try {
                val (startTs, endTs) = dayRangeAsTimestamps(date, zone)

                val ausprs = RunningStat()
                val pwtts  = RunningStat()
                val hsis   = RunningStat()

                var q: Query = db.collectionGroup("records")
                    .whereEqualTo("user_id", uid) // 저장 스키마와 일치
                    .whereGreaterThanOrEqualTo("server_ts", startTs)
                    .whereLessThan("server_ts", endTs)
                    .orderBy("server_ts", Query.Direction.ASCENDING)
                    .limit(pageSize)

                var total = 0

                while (true) {
                    val snap = q.get().awaitCatching() ?: break
                    if (snap.isEmpty) break

                    for (doc in snap.documents) {
                        total++
                        val m = doc.data ?: continue

                        // AUSPR (백워드 호환 포함)
                        extractAuspr(m)?.let { ausprs.add(it) }

                        // PWTT(ms) ← PAD_ms alias
                        extractPwttMs(m)?.let { pwtts.add(it) }

                        // HSI (필드 없으면 재계산)
                        extractHsi(m)?.let { hsis.add(it) }
                    }

                    val lastDoc = snap.documents.lastOrNull() ?: break
                    q = q.startAfter(lastDoc)
                }

                withContext(Dispatchers.Main) {
                    _lastFullCount.value = total
                    // 0건이면 기존 값(리스너)이 덮이지 않도록 가드
                    if (total > 0) {
                        _dayMetrics.value = DayMetrics(
                            auspr  = ausprs.toMetricStat(),
                            pwttMs = pwtts.toMetricStat(),
                            hsi    = hsis.toMetricStat()
                        )
                    }
                }
            } catch (_: CancellationException) {
                // 강제취소
            } catch (t: Throwable) {
                Log.e(TAG, "refreshDaySummaryPaged ERROR", t)
                withContext(Dispatchers.Main) {
                    _lastFullCount.value = 0
                    // ⛔ 여기서 _dayMetrics를 초기화하지 말아야 리스너 값이 유지됨
                    _debugStatus.value = "paged-error: ${t.message}"
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    /**
     * 날짜별 요약 실시간 리스너 시작
     * - server_ts로 하루 범위 필터
     * - AUSPR / PWTT / HSI 집계
     */
    fun startListenDayMetrics(
        uid: String,
        date: LocalDate,
        zone: ZoneId = ZoneId.of("Asia/Seoul")
    ) {
        metricsStopper?.invoke()
        metricsStopper = null

        // ✅ 날짜 바뀌면 화면 리셋
        _dayMetrics.value = null
        _lastFullCount.value = 0
        _debugStatus.value = "listening($uid @ $date)"

        val (startTs, endTs) = dayRangeAsTimestamps(date, zone)
        _debugStatus.value = "listening($uid @ $date)"

        val qBase = db.collectionGroup("records")
            .whereEqualTo("user_id", uid)
            .whereGreaterThanOrEqualTo("server_ts", startTs)
            .whereLessThan("server_ts", endTs)
            .orderBy("server_ts", Query.Direction.ASCENDING)

        val reg = qBase.addSnapshotListener { snap, err ->
            if (err != null) {
                Log.e(TAG, "listen ERROR", err)
                _debugStatus.value = "error: ${err.message}"
                // ⛔ 리스너 오류라도 기존 데이터 유지
                return@addSnapshotListener
            }
            if (snap == null || snap.isEmpty) {
                _debugStatus.value = "empty"
                val today = LocalDate.now(zone)
                if (date != today) {
                    _dayMetrics.value = DayMetrics(
                        auspr  = MetricStat(0,0.0,0.0,0.0),
                        pwttMs = MetricStat(0,0.0,0.0,0.0),
                        hsi    = MetricStat(0,0.0,0.0,0.0),
                    )
                }
                // ⛔ empty일 때도 기존 데이터 유지
                return@addSnapshotListener
            }

            // 러닝 통계
            val ausprs = RunningStat()
            val pwtts  = RunningStat()
            val hsis   = RunningStat()

            for (doc in snap.documents) {
                val m = doc.data ?: continue

                extractAuspr(m)?.let { ausprs.add(it) }
                extractPwttMs(m)?.let { pwtts.add(it) }
                extractHsi(m)?.let { hsis.add(it) }
            }

            _dayMetrics.value = DayMetrics(
                auspr  = ausprs.toMetricStat(),
                pwttMs = pwtts.toMetricStat(),
                hsi    = hsis.toMetricStat(),
            )
            _debugStatus.value = "ok/${snap.size()}"
        }

        metricsStopper = { reg.remove() }
    }

    fun stopAll() {
        metricsStopper?.invoke()
        metricsStopper = null
        fullJob?.cancel()
        fullJob = null
    }

    /* ------------------------- Helpers ------------------------- */

    private fun dayRangeAsTimestamps(date: LocalDate, zone: ZoneId): Pair<Timestamp, Timestamp> {
        val start = date.atStartOfDay(zone)
        val end = start.plusDays(1)
        return Timestamp(start.toInstant().epochSecond, 0) to Timestamp(end.toInstant().epochSecond, 0)
    }
}

/* ======================= 유틸들 (이 파일 안에 포함) ======================= */

/** 여러 이름으로 섞여있는 숫자 필드 안전 추출 (dot-path 지원) */
private fun getNum(
    map: Map<String, Any?>,
    primary: String,
    vararg aliases: String
): Double? {
    fun getByPath(path: String, m: Map<String, Any?>): Any? {
        var cur: Any? = m
        for (seg in path.split('.')) {
            cur = when (cur) {
                is Map<*, *> -> (cur as Map<*, *>)[seg]
                else -> return null
            }
        }
        return cur
    }

    fun asDouble(v: Any?): Double? = when (v) {
        is Number -> v.toDouble()
        is String -> v.toDoubleOrNull()
        else -> null
    }

    (asDouble(map[primary]) ?: asDouble(getByPath(primary, map)))?.let { return it }
    for (a in aliases) {
        (asDouble(map[a]) ?: asDouble(getByPath(a, map)))?.let { return it }
    }

    // 키 정규화(소문자 + 영숫자만)로 느슨 매칭
    val norm = { s: String -> s.lowercase().filter { it.isLetterOrDigit() } }
    val want = buildSet {
        add(norm(primary))
        aliases.forEach { add(norm(it)) }
    }

    for ((k, v) in map) {
        val nk = norm(k)
        if (nk in want) return asDouble(v)
        if (v is Map<*, *>) {
            for ((k2, v2) in v) {
                if (k2 is String && norm(k2) in want) return asDouble(v2)
            }
        }
    }
    return null
}

/** PWTT(ms) = 좌/우 '피크 시점' 차이.
 *  현재 저장은 PpgRepository에서 PAD_ms 로 되어 있으므로,
 *  컬럼명은 그대로 두고 alias로 읽는다.
 */
private fun extractPwttMs(map: Map<String, Any?>): Double? {
    // PAD_ms가 사실상 PWTT(peak-to-peak Δt)이므로 최우선
    getNum(map, "PAD_ms", "PAD", "pad", "padMs")?.let { return it }

    // 혹시 과거/다른 버전에서 피크 기반 PWTT를 별도 키로 저장했다면 보완
    getNum(map,
        "PWTT_peak_ms", "PWTT_pk_ms",
        "PWTT_ms", "PWTT",
        "RTms", "RT_ms",
        "peakDiff_ms", "peak_delta_ms",
        "metrics.PWTT_ms", "metrics.PWTT_peak_ms"
    )?.let { return it }

    return null
}

/** AUSPR: 1) AUSPR 2) AUSP_R/AUSP_L 3) (백업) AmpRatio */
private fun extractAuspr(map: Map<String, Any?>): Double? {
    // 1) 직접 필드
    getNum(map, "AUSPR", "auspr", "metrics.AUSPR")?.let { return it }

    // 2) 면적 비로 복원
    val l = getNum(map, "AUSP_L", "metrics.AUSP_L")
    val r = getNum(map, "AUSP_R", "metrics.AUSP_R")
    if (l != null && r != null && l > 1e-9) {
        val v = r / l
        if (v.isFinite()) return v
    }

    // 3) (구버전 호환) 진폭비를 임시 프록시로 사용
    getNum(map, "AmpRatio","ampratio","Amp_Ratio","ARatio","metrics.AmpRatio")?.let { return it }

    return null
}

/** HSI: 1) HSI 2) AUSPR/PWTT로 재계산 */
private fun extractHsi(map: Map<String, Any?>): Double? {
    // 1) 직접 필드
    getNum(map, "HSI", "hsi", "metrics.HSI")?.let { return it }

    // 2) 재계산 (AUSPR/PWTT 필요)
    val auspr = extractAuspr(map) ?: return null
    val pwtt  = extractPwttMs(map) ?: return null

    val term1 = abs(ln(max(auspr, 1e-6))) / ln(1.0 + 0.30) // AUSPR_NORMAL_BAND=0.30
    val term2 = max(0.0, pwtt - 60.0) / 30.0               // HSI_TD_BASE=60, HSI_TD_SCALE=30
    val hsi = term1 + term2
    return if (hsi.isFinite()) hsi else null
}

/** O(1) 메모리 러닝 통계 */
private data class RunningStat(
    var n: Int = 0,
    var mean: Double = 0.0,
    var min: Double = Double.POSITIVE_INFINITY,
    var max: Double = Double.NEGATIVE_INFINITY
) {
    fun add(x: Double) {
        n += 1
        val d = x - mean
        mean += d / n
        if (x < min) min = x
        if (x > max) max = x
    }
}

private fun RunningStat.toMetricStat(): MetricStat =
    if (n == 0) MetricStat(0, 0.0, 0.0, 0.0) else MetricStat(n, mean, min, max)

/* ======================= 확장: awaitCatching ======================= */

private suspend fun <T> com.google.android.gms.tasks.Task<T>.awaitCatching(): T? =
    try { this.await() } catch (t: Throwable) { Log.w("DataViz","task failed: ${t.message}"); null }
