package com.example.heartsync.data.model

import com.google.firebase.Timestamp

data class AppUser(
    val uid: String = "",
    val id: String = "",      // 화면용 사용자 아이디(별명)
    val name: String = "",
    val phone: String = "",
    val email: String = "",
    val birth: String = "",   // "YYYY-MM-DD"
    val createdAt: Timestamp? = null,
    val updatedAt: Timestamp? = null
)
