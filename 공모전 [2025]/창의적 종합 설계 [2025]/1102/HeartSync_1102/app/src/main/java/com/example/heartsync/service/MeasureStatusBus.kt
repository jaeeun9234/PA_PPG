package com.example.heartsync.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object MeasureStatusBus {
    // 서비스가 업데이트함
    private val _isConnected = MutableStateFlow(false)
    val isConnected = _isConnected.asStateFlow()

    private val _isMeasuring = MutableStateFlow(false)
    val isMeasuring = _isMeasuring.asStateFlow()

    // 서비스에서 세터 노출
    fun setConnected(v: Boolean) { _isConnected.value = v }
    fun setMeasuring(v: Boolean) { _isMeasuring.value = v }
}
