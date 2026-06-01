package com.example.heartsync.data.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

enum class MeasureMode { SPOT }

@Parcelize
data class SessionConfig(
    val mode: MeasureMode,
    val durationSec: Int,         // 스팟 측정 필수
    val batchSize: Int = 200,     // Firestore 배치 크기
    val sps: Int = 100            // 샘플링 주파수 메타
) : Parcelable
