// app/src/main/java/com/example/heartsync/viewmodel/HomeViewModel.kt
package com.example.heartsync.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.example.heartsync.data.remote.PpgRepository
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneId
import java.util.ArrayDeque

/** 그래프에만 쓰는 경량 포인트 (새 파일 추가 없이 이 안에서만 사용) */
data class GraphPoint(
    val time: Long,          // epochMillis (x축 라벨)
    val left: Double?,       // PPGf_L / smoothed_left
    val right: Double?       // PPGf_R / smoothed_right
)

class HomeViewModel(
    private val repo: PpgRepository
) : ViewModel() {

    private val db = FirebaseFirestore.getInstance()

    // ===== Firestore (오늘 날짜) 데이터 =====
    private val _today = MutableStateFlow<List<GraphPoint>>(emptyList())
    val today: StateFlow<List<GraphPoint>> = _today.asStateFlow()

    // ===== BLE 실시간 데이터 (메모리 버퍼) =====
    private val _live = MutableStateFlow<List<GraphPoint>>(emptyList())
    val live: StateFlow<List<GraphPoint>> = _live.asStateFlow()

    // 로그인 여부
    private val _isLoggedIn = MutableStateFlow(false)
    val isLoggedIn: StateFlow<Boolean> = _isLoggedIn.asStateFlow()

    /**
     * 화면에 뿌릴 최종 시리즈
     * - live가 비어있지 않으면 live 우선
     * - 아니면 today 사용
     */
    val display: StateFlow<List<GraphPoint>> =
        combine(today, live) { day, livePoints ->
            if (livePoints.isNotEmpty()) livePoints else day
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = emptyList()
        )

    // ---- 실시간 버퍼 설정(최근 N개만 유지) ----
    private val liveBuffer = ArrayDeque<GraphPoint>()
    private val LIVE_WINDOW = 600  // 필요 시 300/600/1000 등으로 조절

    init {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        _isLoggedIn.value = uid != null

        // 1) 오늘 날짜의 Firestore 데이터 구독 (기존 기록 + 백필)
        if (uid != null) {
            viewModelScope.launch(Dispatchers.IO) {
                observeTodayPpg(uid, LocalDate.now())
                    .collect { _today.value = it }
            }
        }

        // 2) BLE → 실시간 smoothed 스트림 (epochMillis, left, right)
        startLiveStream()
    }

    /** BLE에서 방금 받은 smoothed L/R 값을 바로 그래프에 반영하는 스트림 */
    private fun startLiveStream() {
        viewModelScope.launch {
            PpgRepository.smoothed().collect { triple: Triple<Long, Float, Float> ->
                val (t, l, r) = triple
                // 버퍼에 최신 포인트 추가 (윈도우 초과 시 가장 오래된 것 제거)
                if (liveBuffer.size >= LIVE_WINDOW) liveBuffer.removeFirst()
                liveBuffer.addLast(
                    GraphPoint(
                        time = t,
                        left = l.toDouble(),
                        right = r.toDouble()
                    )
                )
                _live.value = liveBuffer.toList()
            }
        }
    }

    /** 오늘 날짜의 records를 collectionGroup으로 읽어 그래프 포인트로 변환 */
    private fun observeTodayPpg(
        uid: String,
        date: LocalDate,
        zone: ZoneId = ZoneId.of("Asia/Seoul")
    ): Flow<List<GraphPoint>> = callbackFlow {
        val (startTs, endTs) = dayRangeAsTimestamps(date, zone)
        val q = db.collectionGroup("records")
            .whereEqualTo("ownerUid", uid)
            .whereGreaterThanOrEqualTo("server_ts", startTs)
            .whereLessThan("server_ts", endTs)
            .orderBy("server_ts", Query.Direction.ASCENDING)

        val reg = q.addSnapshotListener { snap, err ->
            if (err != null || snap == null) {
                trySend(emptyList()).isSuccess
                return@addSnapshotListener
            }
            val list = snap.documents.mapNotNull { d ->
                val l = (d.getDouble("PPGf_L") ?: d.getDouble("smoothed_left")) ?: return@mapNotNull null
                val r = (d.getDouble("PPGf_R") ?: d.getDouble("smoothed_right")) ?: return@mapNotNull null
                val serverMillis = d.getTimestamp("server_ts")?.toDate()?.time ?: return@mapNotNull null
                GraphPoint(serverMillis, l, r)
            }
            trySend(list).isSuccess
        }
        awaitClose { reg.remove() }
    }

    private fun dayRangeAsTimestamps(date: LocalDate, zone: ZoneId): Pair<Timestamp, Timestamp> {
        val start = date.atStartOfDay(zone)
        val end = start.plusDays(1)
        // seconds 단위로 충분 (Firestore Timestamp(nanos=0))
        return Timestamp(start.toInstant().epochSecond, 0) to Timestamp(end.toInstant().epochSecond, 0)
    }
}

/** Factory */
class HomeVmFactory(
    private val repo: PpgRepository
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return HomeViewModel(repo) as T
    }
}
