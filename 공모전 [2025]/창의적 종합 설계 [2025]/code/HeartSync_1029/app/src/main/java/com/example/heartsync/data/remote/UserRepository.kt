package com.example.heartsync.data.remote

import com.example.heartsync.data.model.UserProfile
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await

class UserRepository(
    private val db: FirebaseFirestore = FirebaseFirestore.getInstance()
) {
    // ✅ ID 중복 확인
    suspend fun isIdAvailable(id: String): Boolean {
        val doc = db.collection("usernames").document(id).get().await()
        return !doc.exists()
    }


    // ✅ 유저 프로필 생성
    suspend fun createUserProfile(
        uid: String,
        id: String,
        name: String,
        phone: String,
        birth: String,
        email: String
    ) {
        val doc = hashMapOf(
            "uid" to uid,
            "id" to id,
            "name" to name,
            "phone" to phone,
            "birth" to birth,
            "email" to email,
            "createdAt" to FieldValue.serverTimestamp(),
            "updatedAt" to FieldValue.serverTimestamp()
        )
        db.collection("users").document(uid).set(doc).await()
    }

    // ✅ 유저 프로필 조회 → UserProfile 객체로 매핑
    suspend fun getUserProfile(uid: String): UserProfile {
        val snap = db.collection("users").document(uid).get().await()
        return if (snap.exists()) {
            UserProfile(
                uid = snap.getString("uid") ?: "",
                id = snap.getString("id") ?: "",
                name = snap.getString("name") ?: "",
                phone = snap.getString("phone") ?: "",
                birth = snap.getString("birth") ?: "",
                email = snap.getString("email") ?: ""
            )
        } else {
            throw Exception("User profile not found")
        }
    }

    // ✅ 유저 프로필 업데이트 (전화번호 등 수정)
    suspend fun updateUserProfile(profile: UserProfile) {
        val updates = mapOf(
            "phone" to profile.phone,
            "updatedAt" to FieldValue.serverTimestamp()
        )
        db.collection("users").document(profile.uid).update(updates).await()
    }

    suspend fun createUserWithUsernameClaim(
        uid: String,
        id: String,
        name: String,
        phone: String,
        birth: String,
        email: String
    ) {
        val batch = db.batch()
        val usernamesRef = db.collection("usernames").document(id)
        val usersRef = db.collection("users").document(uid)

        batch.set(usernamesRef, mapOf("uid" to uid, "email" to email))
        batch.set(usersRef, mapOf(
            "uid" to uid, "id" to id, "name" to name, "phone" to phone,
            "birth" to birth, "email" to email,
            "createdAt" to com.google.firebase.Timestamp.now(),
            "updatedAt" to com.google.firebase.Timestamp.now()
        ))
        batch.commit().await()
    }

}
