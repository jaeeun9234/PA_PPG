package com.example.heartsync.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.example.heartsync.R
import com.example.heartsync.ui.themes.NavyHeader

@Composable
fun TopBar() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(NavyHeader)
            .statusBarsPadding()   // 상태바 높이만큼 자동 패딩 → 화면 최상단
            .height(72.dp),
        contentAlignment = Alignment.Center
    ) {
        Image(
            painter = painterResource(R.drawable.topbar), // ← drawable에 실제 파일명
            contentDescription = null,
            modifier = Modifier.height(28.dp),
            contentScale = androidx.compose.ui.layout.ContentScale.Fit,
            // 투명 배경 PNG라면 픽셀만 흰색으로 보임
            colorFilter = ColorFilter.tint(Color.White, BlendMode.SrcIn)
        )
    }
}
