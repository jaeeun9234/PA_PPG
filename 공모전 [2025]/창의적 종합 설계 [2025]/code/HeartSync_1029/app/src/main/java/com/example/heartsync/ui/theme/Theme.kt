package com.example.heartsync.ui.themes

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView

private val LightColors = lightColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    secondary = Secondary,
    onSecondary = OnSecondary,
    surface = Surface,
    onSurface = OnSurface,
    background = Surface,
    onBackground = OnSurface,
    outline = Outline,
)

@Composable
fun HeartSyncTheme(
    darkTheme: Boolean = false, // 앱 디자인 고정이라 다크 비활성 추천
    content: @Composable () -> Unit
) {
    val colorScheme = LightColors
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = Primary.toArgb()
        }
    }
    MaterialTheme(
        colorScheme = colorScheme,
        typography =Typography(),
        content = content
    )
}
