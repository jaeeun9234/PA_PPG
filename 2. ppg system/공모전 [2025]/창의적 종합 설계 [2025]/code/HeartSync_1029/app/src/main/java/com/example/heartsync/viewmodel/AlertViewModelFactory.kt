package com.example.heartsync.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.example.heartsync.data.remote.PpgRepository
import com.example.heartsync.ppg.PpgProcessor
import com.example.heartsync.ui.alert.AlertViewModel
import com.google.firebase.firestore.FirebaseFirestore

class AlertViewModelFactory : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        if (modelClass.isAssignableFrom(AlertViewModel::class.java)) {
            // ✨ 여기서 직접 생성해서 주입 (Manifest 변경 불필요)
            val repository = PpgRepository(FirebaseFirestore.getInstance())         // 생성자 다르면 맞게 수정
            val processor  = PpgProcessor.instance        // 샘플레이트 등 파라미터 있으면 넣기
            return AlertViewModel(repository, processor) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class: ${modelClass.name}")
    }
}