package com.example.heartsync.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.heartsync.viewmodel.ProfileEvent
import com.example.heartsync.viewmodel.ProfileViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UserInfoScreen(
    vm: ProfileViewModel = viewModel(),
    onLogout: () -> Unit = {}
) {
    val snackbar = remember { SnackbarHostState() }
    val profile by vm.profile.collectAsState()

    // 수정 상태 (수정 모드로 들어갈지 말지)
    var editMode by remember { mutableStateOf(false) }
    var phone by remember(profile) { mutableStateOf(profile?.phone.orEmpty()) }

    // 비밀번호 수정 필드
    var currentPw by remember { mutableStateOf("") }
    var newPw by remember { mutableStateOf("") }
    var newPw2 by remember { mutableStateOf("") }

    LaunchedEffect(Unit) { vm.load() }
    LaunchedEffect(Unit) {
        for (e in vm.events) {
            when (e) {
                is ProfileEvent.Error -> snackbar.showSnackbar(e.msg)
                ProfileEvent.Updated -> {
                    snackbar.showSnackbar("전화번호 수정 완료")
                    editMode = false  // 수정 후 비활성화
                }
                ProfileEvent.PasswordChanged -> {
                    snackbar.showSnackbar("비밀번호가 변경되었습니다. 다시 로그인이 필요할 수 있어요.")
                    currentPw = ""; newPw = ""; newPw2 = ""  // 비밀번호 수정 후 초기화
                }
                ProfileEvent.Loaded -> {}
            }
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text("내 정보") },
                actions = {
                    // 🔹 로그아웃 버튼 추가
                    TextButton(onClick = onLogout) {
                        Text("로그아웃")
                    }
                    // 기존 편집 토글 유지
                    IconButton(onClick = { editMode = !editMode }) {
                        Icon(Icons.Default.Edit, contentDescription = "수정")
                    }
                }
            )
        }
    ) { inner ->
        // 🔽 스크롤 가능 + 키보드/네비게이션 바 회피
        Column(
            modifier = Modifier
                .padding(inner)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .imePadding()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // 이름, 아이디, 생년월일, 이메일 (읽기 전용)
            OutlinedTextField(
                value = profile?.name.orEmpty(),
                onValueChange = {},
                label = { Text("이름") },
                modifier = Modifier.fillMaxWidth(),
                enabled = false
            )
            OutlinedTextField(
                value = profile?.id.orEmpty(),
                onValueChange = {},
                label = { Text("아이디") },
                modifier = Modifier.fillMaxWidth(),
                enabled = false
            )
            OutlinedTextField(
                value = profile?.birth.orEmpty(),
                onValueChange = {},
                label = { Text("생년월일") },
                modifier = Modifier.fillMaxWidth(),
                enabled = false
            )
            OutlinedTextField(
                value = profile?.email.orEmpty(),
                onValueChange = {},
                label = { Text("이메일") },
                modifier = Modifier.fillMaxWidth(),
                enabled = false
            )

            // 수정 가능한: 전화번호 + 비밀번호
            OutlinedTextField(
                value = phone,
                onValueChange = { phone = it },
                label = { Text("전화번호") },
                modifier = Modifier.fillMaxWidth(),
                enabled = editMode
            )

            // 비밀번호 수정 필드
            if (editMode) {
                OutlinedTextField(
                    value = currentPw,
                    onValueChange = { currentPw = it },
                    label = { Text("현재 비밀번호") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                )
                OutlinedTextField(
                    value = newPw,
                    onValueChange = { newPw = it },
                    label = { Text("새 비밀번호 (6자 이상)") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                )
                OutlinedTextField(
                    value = newPw2,
                    onValueChange = { newPw2 = it },
                    label = { Text("새 비밀번호 확인") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    isError = newPw2.isNotEmpty() && newPw2 != newPw,
                    supportingText = {
                        if (newPw2.isNotEmpty() && newPw2 != newPw)
                            Text("비밀번호가 일치하지 않습니다.")
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                )
            }

            // 버튼들 – 맨 아래로 밀리도록 Spacer 추가 가능
            Spacer(Modifier.height(8.dp))

            Button(
                onClick = { vm.updatePhone(phone) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                enabled = editMode && profile != null
            ) { Text("저장") }

            // 하단 여백 (바텀바/제스처영역과 겹치지 않도록)
            Spacer(Modifier.height(24.dp))
        }
    }
}
