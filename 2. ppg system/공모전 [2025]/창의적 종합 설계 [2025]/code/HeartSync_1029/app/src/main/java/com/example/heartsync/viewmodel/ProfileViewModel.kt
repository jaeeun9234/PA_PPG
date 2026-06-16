// app/src/main/java/com/example/heartsync/viewmodel/ProfileViewModel.kt
package com.example.heartsync.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.data.model.UserProfile
import com.example.heartsync.data.remote.UserRepository
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

sealed interface ProfileEvent {
    data object Loaded : ProfileEvent
    data object Updated : ProfileEvent          // 전화번호 수정 완료
    data object PasswordChanged : ProfileEvent  // 비밀번호 변경 완료
    data class Error(val msg: String) : ProfileEvent
}

class ProfileViewModel(
    private val userRepo: UserRepository = UserRepository()
) : ViewModel() {

    private val _profile = MutableStateFlow<UserProfile?>(null)
    val profile: StateFlow<UserProfile?> = _profile.asStateFlow()

    val events = Channel<ProfileEvent>(Channel.BUFFERED)

    fun load() = viewModelScope.launch {
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) { events.send(ProfileEvent.Error("로그인이 필요합니다.")); return@launch }
        runCatching { userRepo.getUserProfile(user.uid) }
            .onSuccess { _profile.value = it; events.send(ProfileEvent.Loaded) }
            .onFailure { events.send(ProfileEvent.Error(it.message ?: "프로필 로드 실패")) }
    }

    /** 전화번호만 수정 */
    fun updatePhone(newPhone: String) = viewModelScope.launch {
        val user = FirebaseAuth.getInstance().currentUser ?: return@launch
        val cur = _profile.value ?: return@launch
        val updated = cur.copy(phone = newPhone)
        runCatching { userRepo.updateUserProfile(updated) }
            .onSuccess { _profile.value = updated; events.send(ProfileEvent.Updated) }
            .onFailure { events.send(ProfileEvent.Error(it.message ?: "전화번호 수정 실패")) }
    }

    /** 비밀번호 변경: 현재 비번 재인증 → 새 비번으로 변경 */
    fun changePassword(currentPw: String, newPw: String) = viewModelScope.launch {
        val user = FirebaseAuth.getInstance().currentUser
        val email = user?.email ?: _profile.value?.email
        if (user == null || email.isNullOrBlank()) {
            events.send(ProfileEvent.Error("재인증 정보가 없습니다. 다시 로그인해 주세요.")); return@launch
        }
        runCatching {
            val cred = EmailAuthProvider.getCredential(email, currentPw)
            user.reauthenticate(cred).await()
            user.updatePassword(newPw).await()
        }.onSuccess {
            events.send(ProfileEvent.PasswordChanged)
        }.onFailure {
            events.send(ProfileEvent.Error(it.message ?: "비밀번호 변경 실패(재인증 필요)"))
        }
    }
}
