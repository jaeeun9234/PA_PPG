package com.example.heartsync.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.example.heartsync.R
import kotlinx.coroutines.delay

@Composable
fun SplashSequence(
    nextRoute: String,
    onFinished: (String) -> Unit
) {
    var stage by remember { mutableStateOf(0) }

    LaunchedEffect(Unit) {
        delay(120)  // 시스템 스플래시에서 넘어온 짧은 텀
        stage = 1
        delay(1000) // 워드마크 노출 시간 (원하면 조절)
        onFinished(nextRoute)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFFFFFFF)), // 앱 배경과 통일
        contentAlignment = Alignment.Center
    ) {
        Image(
            painter = painterResource(R.drawable.heartsync_word), // 배경 투명 권장
            contentDescription = "HeartSync 워드마크"
        )
    }
}
