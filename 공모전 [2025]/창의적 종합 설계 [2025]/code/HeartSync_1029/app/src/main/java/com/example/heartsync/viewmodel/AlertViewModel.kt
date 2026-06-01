// AlertViewModel.kt
package com.example.heartsync.ui.alert   // ← 네 패키지 경로에 맞게

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.heartsync.data.remote.PpgRepository
import com.example.heartsync.ppg.PpgProcessor
import com.example.heartsync.ppg.PpgProcessor.Alert
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class AlertViewModel(
    private val repository: PpgRepository,
    private val processor: PpgProcessor
) : ViewModel() {

    private val _popup = MutableSharedFlow<Alert>(extraBufferCapacity = 1)
    val popup: SharedFlow<Alert> = _popup

    private val lastSavedAt = mutableMapOf<String, Long>()
    private val cooldownMs = 10_000L

    init {
        viewModelScope.launch {
            processor.alert.collectLatest { alert ->
                _popup.tryEmit(alert)

                val key = "${alert.type}:${alert.side ?: "asymmetry"}"
                val now = System.currentTimeMillis()
                val last = lastSavedAt[key] ?: 0L
                if (now - last >= cooldownMs) {
                    try {
                        repository.saveAlert(alert)
                        lastSavedAt[key] = now
                    } catch (_: Exception) { }
                }
            }
        }
    }
}
