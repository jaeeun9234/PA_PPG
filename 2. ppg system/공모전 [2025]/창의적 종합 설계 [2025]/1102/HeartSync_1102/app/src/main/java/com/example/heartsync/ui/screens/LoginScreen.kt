package com.example.heartsync.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.example.heartsync.ui.components.PasswordField
import com.example.heartsync.ui.components.TopBar
import com.example.heartsync.ui.themes.NavyHeader
import com.example.heartsync.util.Route
import com.example.heartsync.viewmodel.AuthEvent
import com.example.heartsync.viewmodel.AuthViewModel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.receiveAsFlow

@Composable
fun LoginScreen(nav: NavHostController, vm: AuthViewModel) {
    var id by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(vm) {
        vm.events.receiveAsFlow().collectLatest { e ->
            when (e) {
                is AuthEvent.LoggedIn -> {
                    err = null
                    nav.navigate(Route.MAIN) {
                        // 스플래시가 있다면 이쪽을 권장
                        // popUpTo(Route.Splash) { inclusive = false }
                        popUpTo(Route.Login) { inclusive = true }
                        launchSingleTop = true
                        restoreState = true
                    }
                }
                is AuthEvent.Error -> err = e.msg
                else -> Unit
            }
        }
    }

    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center) {
        OutlinedTextField(
            value = id,
            onValueChange = { id = it },
            label = { Text("ID") },
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))
        PasswordField(
            value = pw,
            onValueChange = { pw = it },
            label = "비밀번호",
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(16.dp))
        Button(
            onClick = {
                if (id.isBlank() || pw.isBlank()) {
                    err = "ID와 비밀번호를 입력하세요."
                } else {
                    err = null // ✅ 이전 에러 초기화
                    vm.loginWithId(id.trim(), pw) // ⚠️ 여기 구현 확인 (ID→이메일 매핑 필요)
                }
            },
            colors = ButtonDefaults.buttonColors(containerColor = NavyHeader),
            modifier = Modifier.fillMaxWidth()
        ) { Text("로그인") }

        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = { nav.navigate(Route.Register) }, modifier = Modifier.fillMaxWidth()) {
            Text("회원가입")
        }

        err?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
