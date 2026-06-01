// app/src/main/java/com/example/heartsync/ui/model/DayMetrics.kt
package com.example.heartsync.ui.model

data class DayMetrics(
    val auspr:  MetricStat?,  // AUSPR
    val pwttMs: MetricStat?,  // PWTT (기존 컬럼 alias 또는 SUTL/SUTR 평균으로 계산)
    val hsi:    MetricStat?,  // HSI
)

data class MetricStat(
    val count: Int,
    val avg: Double,
    val min: Double,
    val max: Double
)
