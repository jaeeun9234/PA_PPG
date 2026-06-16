package com.example.heartsync.data.remote

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await

class AuthRepository(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val db: FirebaseFirestore = FirebaseFirestore.getInstance()
) {
    val currentUser get() = auth.currentUser

    // ✅ (NEW) ID 중복 확인: usernames/{id} 문서 존재 여부만 확인
    suspend fun checkIdAvailable(id: String): Boolean {
        //ensureAnonymousSignIn() // ★ 중요: 미인증이면 익명 로그인
        val doc = db.collection("usernames").document(id).get().await()
        return !doc.exists()
    }

    // ✅ ID + 비밀번호 로그인
    suspend fun loginWithId(id: String, password: String) {
        //ensureAnonymousSignIn() // 익명 토큰 확보(권장)

        // users 쿼리 금지 → usernames/{id} 단일 GET
        val doc = db.collection("usernames").document(id).get().await()
        if (!doc.exists()) throw IllegalStateException("해당 ID가 없습니다.")

        val email = doc.getString("email")
            ?: throw IllegalStateException("이 ID에 연결된 이메일이 없습니다.")

        auth.signInWithEmailAndPassword(email, password).await()
    }

    // 보조 함수 추가
    suspend fun ensureAnonymousSignIn() {
        val auth = FirebaseAuth.getInstance()
        if (auth.currentUser == null) auth.signInAnonymously().await()
    }

    // ✅ FirebaseAuth 회원가입 (Auth 계정만 생성)
    suspend fun register(email: String, password: String): String {
        val res = auth.createUserWithEmailAndPassword(email, password).await()
        return res.user?.uid ?: error("UID is null")
    }

    fun logout() = auth.signOut()
}
