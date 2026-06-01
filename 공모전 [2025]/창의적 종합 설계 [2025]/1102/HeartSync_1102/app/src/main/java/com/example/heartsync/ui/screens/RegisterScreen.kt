package com.example.heartsync.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.example.heartsync.util.Route
import com.example.heartsync.viewmodel.AuthEvent
import com.example.heartsync.viewmodel.AuthViewModel
import kotlinx.coroutines.flow.receiveAsFlow
import com.example.heartsync.ui.components.PasswordField
import kotlinx.coroutines.flow.collectLatest

@Composable
fun RegisterScreen(nav: NavHostController, vm: AuthViewModel) {
    var id by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var phone by remember { mutableStateOf(TextFieldValue("")) }
    var birth by remember { mutableStateOf(TextFieldValue("")) }
    var email by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var pwConfirm by remember { mutableStateOf("") }
    val pwMismatch = pw.isNotBlank() && pwConfirm.isNotBlank() && pw != pwConfirm

    // ✅ 개선된 ID 확인 상태
    var checkedId by remember { mutableStateOf<String?>(null) }        // 마지막으로 "확인"을 눌러 검증한 ID(trim)
    var isIdAvailable by remember { mutableStateOf<Boolean?>(null) }   // true/false/null(미확인)

    // 다이얼로그 & 에러
    var showDialog by remember { mutableStateOf(false) }
    var dialogMsg by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }

    // 이벤트 수신
    LaunchedEffect(vm) {
        vm.events.receiveAsFlow().collectLatest { e ->
            when (e) {
                is AuthEvent.LoggedIn -> {
                    val popped = nav.popBackStack(Route.Login, inclusive = false)
                    if (!popped) {
                        nav.navigate(Route.Login) {
                            popUpTo(Route.Splash) { inclusive = false }
                            launchSingleTop = true
                        }
                    }
                }
                is AuthEvent.Error -> err = e.msg
                is AuthEvent.IdCheckResult -> {
                    checkedId = e.id.trim()
                    isIdAvailable = e.available
                    dialogMsg = if (e.available) "사용 가능한 ID 입니다." else "이미 사용 중인 ID 입니다."
                    showDialog = true
                }
                else -> Unit
            }
        }
    }

    // ID가 바뀌면(공백 포함) 재확인 필요 상태로
    LaunchedEffect(id) {
        val cur = id.trim()
        if (cur != checkedId) isIdAvailable = null
    }

    // 🔽 스크롤 가능 + 키보드/네비게이션 바 회피
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .imePadding()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // ID 입력 + 중복확인
        Row(Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = id,
                onValueChange = { id = it },
                label = { Text("ID") },
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = {
                    val curId = id.trim()
                    if (curId.isBlank()) {
                        dialogMsg = "ID를 입력해 주세요."
                        showDialog = true
                    } else {
                        vm.checkIdAvailability(curId)
                    }
                },
                modifier = Modifier.width(110.dp)
            ) { Text("중복 확인") }
        }

        // 보조 문구(선택)
        if (checkedId != null && checkedId == id.trim()) {
            when (isIdAvailable) {
                true  -> Text("사용 가능한 ID입니다.", color = MaterialTheme.colorScheme.primary)
                false -> Text("이미 사용 중인 ID입니다.", color = MaterialTheme.colorScheme.error)
                null  -> {}
            }
        }

        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("이름") },
            modifier = Modifier.fillMaxWidth()
        )

        // 전화번호
        OutlinedTextField(
            value = phone,
            onValueChange = { input ->
                val digits = input.text.filter { it.isDigit() }.take(11)
                val formatted = when {
                    digits.length >= 11 -> "${digits.substring(0,3)}-${digits.substring(3,7)}-${digits.substring(7,11)}"
                    digits.length >= 7  -> "${digits.substring(0,3)}-${digits.substring(3,7)}-${digits.substring(7)}"
                    digits.length >= 3  -> "${digits.substring(0,3)}-${digits.substring(3)}"
                    else -> digits
                }
                phone = TextFieldValue(formatted, TextRange(formatted.length))
            },
            label = { Text("전화번호") },
            placeholder = { Text("010-1234-5678") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
        )

        // 생년월일
        OutlinedTextField(
            value = birth,
            onValueChange = { input ->
                val digits = input.text.filter { it.isDigit() }.take(8)
                val formatted = when {
                    digits.length >= 8 -> "${digits.substring(0,4)}-${digits.substring(4,6)}-${digits.substring(6,8)}"
                    digits.length >= 6 -> "${digits.substring(0,4)}-${digits.substring(4,6)}-${digits.substring(6)}"
                    digits.length >= 4 -> "${digits.substring(0,4)}-${digits.substring(4)}"
                    else -> digits
                }
                birth = TextFieldValue(formatted, TextRange(formatted.length))
            },
            label = { Text("생년월일 (YYYY-MM-DD)") },
            placeholder = { Text("YYYY-MM-DD") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
        )

        OutlinedTextField(
            value = email,
            onValueChange = { email = it },
            label = { Text("이메일") },
            modifier = Modifier.fillMaxWidth()
        )

        // 비밀번호
        PasswordField(
            value = pw,
            onValueChange = { pw = it },
            label = "비밀번호",
            modifier = Modifier.fillMaxWidth()
        )

        // 비밀번호 확인
        OutlinedTextField(
            value = pwConfirm,
            onValueChange = { pwConfirm = it },
            label = { Text("비밀번호 확인") },
            modifier = Modifier.fillMaxWidth(),
            visualTransformation = PasswordVisualTransformation(),
            isError = pwMismatch,
            supportingText = { if (pwMismatch) Text("비밀번호가 일치하지 않습니다.") }
        )

        Spacer(Modifier.height(6.dp))

        Button(
            onClick = {
                val curId = id.trim()
                when {
                    id.isBlank() || name.isBlank() || phone.text.isBlank() ||
                            birth.text.isBlank() || email.isBlank() ||
                            pw.isBlank() || pwConfirm.isBlank() -> {
                        dialogMsg = "모든 항목을 입력해 주세요."
                        showDialog = true
                    }
                    checkedId == null || checkedId != curId -> {
                        dialogMsg = "ID 중복 확인을 진행해 주세요."
                        showDialog = true
                    }
                    isIdAvailable == false -> {
                        dialogMsg = "이미 사용 중인 ID 입니다. 다른 ID를 입력해 주세요."
                        showDialog = true
                    }
                    pwMismatch -> {
                        dialogMsg = "비밀번호가 일치하지 않습니다."
                        showDialog = true
                    }
                    else -> {
                        vm.register(
                            curId,
                            name.trim(),
                            phone.text.trim(),
                            birth.text.trim(),
                            email.trim(),
                            pw
                        )
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
        ) { Text("OK") }

        err?.let { Text(it, color = MaterialTheme.colorScheme.error) }

        Spacer(Modifier.height(24.dp))
    }

    if (showDialog) {
        AlertDialog(
            onDismissRequest = { showDialog = false },
            confirmButton = { TextButton(onClick = { showDialog = false }) { Text("확인") } },
            title = { Text("알림") },
            text = { Text(dialogMsg) }
        )
    }
}
