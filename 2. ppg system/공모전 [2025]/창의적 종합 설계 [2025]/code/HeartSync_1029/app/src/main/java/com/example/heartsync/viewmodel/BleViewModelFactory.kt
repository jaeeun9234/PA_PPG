package com.example.heartsync.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.CreationExtras
import com.example.heartsync.data.remote.PpgRepository

class BleViewModelFactory(
    private val repo: PpgRepository   // ← 반드시 같은 타입/패키지
) : ViewModelProvider.Factory {

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
        if (modelClass.isAssignableFrom(BleViewModel::class.java)) {
            return BleViewModel(repo) as T   // ← repo를 넣어서 생성
        }
        throw IllegalArgumentException("Unknown ViewModel class: ${modelClass.name}")
    }

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T { // 구버전 호환
        if (modelClass.isAssignableFrom(BleViewModel::class.java)) {
            return BleViewModel(repo) as T
        }
        throw IllegalArgumentException("Unknown ViewModel class: ${modelClass.name}")
    }
}
