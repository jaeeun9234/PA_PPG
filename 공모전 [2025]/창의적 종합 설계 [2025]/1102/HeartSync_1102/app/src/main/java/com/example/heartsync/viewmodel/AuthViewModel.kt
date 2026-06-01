package com.example.heartsync.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.data.remote.AuthRepository
import com.example.heartsync.data.remote.UserRepository
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

sealed interface AuthEvent {
    data object LoggedIn : AuthEvent
    data object LoggedOut : AuthEvent
    data class Error(val msg: String) : AuthEvent
    data class IdCheckResult(val id: String, val available: Boolean) : AuthEvent
}

class AuthViewModel(
    private val authRepo: AuthRepository = AuthRepository(),
    private val userRepo: UserRepository = UserRepository()
) : ViewModel() {

    private val _isLoggedIn = MutableStateFlow(authRepo.currentUser != null)
    val isLoggedIn: StateFlow<Boolean> = _isLoggedIn.asStateFlow()
    val events = Channel<AuthEvent>(Channel.BUFFERED)

    private val listener = FirebaseAuth.AuthStateListener { fb ->
        val u = fb.currentUser
        val logged = (u != null && !u.isAnonymous)   // ★ 익명 제외
        _isLoggedIn.value = logged
        viewModelScope.launch {
            events.send(if (logged) AuthEvent.LoggedIn else AuthEvent.LoggedOut)
        }
    }


    init {
        FirebaseAuth.getInstance().addAuthStateListener(listener)
    }

    override fun onCleared() {
        FirebaseAuth.getInstance().removeAuthStateListener(listener)
        super.onCleared()
    }


    // ✅ ID + PW 로그인
    fun loginWithId(id: String, pw: String) = viewModelScope.launch {
        runCatching {
            authRepo.loginWithId(id, pw)   // AuthRepository에서 ID → email 변환 후 로그인
        }.onFailure {
            events.send(AuthEvent.Error(it.message ?: "로그인 실패"))
        }
    }

    // ✅ ID 중복 확인
    fun checkIdAvailability(id: String) = viewModelScope.launch {
        try {
            val available = authRepo.checkIdAvailable(id)  // ← 핵심: authRepo로 일원화
            events.send(AuthEvent.IdCheckResult(id, available))
        } catch (e: Exception) {
            events.send(AuthEvent.Error(e.message ?: "ID 확인 실패"))
        }
    }


    // ✅ 회원가입 (Auth 계정 생성 + Firestore 프로필 저장)
    fun register(
        id: String,
        name: String,
        phone: String,
        birth: String,
        email: String,
        pw: String
    ) = viewModelScope.launch {
        try {
            if (!userRepo.isIdAvailable(id)) {
                events.send(AuthEvent.Error("이미 존재하는 ID입니다."))
                return@launch
            }

            // 1) FirebaseAuth 계정 생성
            val uid = authRepo.register(email, pw)

            // 2) Firestore에 유저 프로필 저장
            //userRepo.createUserProfile(uid, id, name, phone, birth, email)
            userRepo.createUserWithUsernameClaim(uid, id, name, phone, birth, email)
            events.send(AuthEvent.LoggedIn)

        } catch (e: Exception) {
            events.send(AuthEvent.Error(e.message ?: "회원가입 실패"))
        }
    }

    // ✅ 로그아웃
    fun logout() = authRepo.logout()
}
