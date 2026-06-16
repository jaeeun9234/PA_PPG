package com.example.heartsync.data.model

data class GraphState(
    val smoothedL: List<Float> = emptyList(),
    val smoothedR: List<Float> = emptyList()
)
