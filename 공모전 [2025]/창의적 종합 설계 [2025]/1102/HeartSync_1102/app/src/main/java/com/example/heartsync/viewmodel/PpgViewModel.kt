// app/src/main/java/com/example/heartsync/viewmodel/PpgViewModel.kt
package com.example.heartsync.viewmodel

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.data.model.PpgEvent
import com.example.heartsync.data.remote.PpgRepository
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Firestore 업로드/조회 전용 ViewModel
 */
class PpgViewModel(
    private val repo: PpgRepository = PpgRepository.instance
) : ViewModel() {

    private val TAG = "PpgViewModel"

    private val _sessionId = MutableStateFlow<String?>(null)
    val sessionId: StateFlow<String?> = _sessionId.asStateFlow()

    private val _events = MutableStateFlow<List<PpgEvent>>(emptyList())
    val events: StateFlow<List<PpgEvent>> = _events.asStateFlow()

    /** Repo의 세션을 사용(없으면 생성)하고 현재 세션ID를 동기화 */
    fun startOrReuseSession(): String {
        // 컴패니언의 currentSessionId()는 보장 생성 + non-null 반환
        val sid = PpgRepository.currentSessionId()
        _sessionId.value = sid
        Log.d(TAG, "startOrReuseSession: $sid")
        return sid
    }

    fun attachSession(id: String) {
        _sessionId.value = id
        Log.d(TAG, "attachSession(local): $id")
    }

    fun clearSession() {
        _sessionId.value = null
        Log.d(TAG, "clearSession(local)")
    }

    /** PpgEvent 업로드 */
    fun saveEvent(ev: PpgEvent) {
        viewModelScope.launch {
            val uid = FirebaseAuth.getInstance().currentUser?.uid ?: run {
                Log.e(TAG, "upload aborted: no signed-in user")
                return@launch
            }
            val sid = _sessionId.value ?: startOrReuseSession()

            try {
                repo.uploadRecord(uid, sid, ev)
                _events.update { it + ev }
                Log.d(TAG, "upload OK: uid=$uid / session=$sid")
            } catch (t: Throwable) {
                Log.e(TAG, "upload failed", t)
            }
        }
        // 업로드 시점에 그래프 스트림으로도 흘려보내고 싶다면 여기서 emitSmoothed 호출 고려
        // PpgRepository.emitSmoothed(System.currentTimeMillis(), l, r)
    }

    /** Firestore 최근 N개 구독해서 events 갱신 (server_ts ASC) */
    fun observeRecent(limit: Long = 200) {
        viewModelScope.launch {
            val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return@launch
            val sid = _sessionId.value ?: startOrReuseSession()
            try {
                repo.observeRecent(userId = uid, sessionId = sid, limit = limit)
                    .collect { list -> _events.value = list }
            } catch (t: Throwable) {
                Log.e(TAG, "observeRecent failed", t)
            }
        }
    }
}
