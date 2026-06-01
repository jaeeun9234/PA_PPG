// app/src/main/java/com/example/heartsync/ui/components/BottomBar.kt
package com.example.heartsync.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.currentBackStackEntryAsState
import com.example.heartsync.util.Route
import androidx.compose.ui.graphics.vector.ImageVector

private data class BottomItem(
    val route: String,
    val label: String,
    val icon: ImageVector
)

@Composable
fun BottomBar(navController: NavController) {
    val items = listOf(
        BottomItem(Route.Home,   "홈 화면",   Icons.Default.Home),
        BottomItem(Route.Docs,   "시각화",     Icons.Default.Folder),
        BottomItem(Route.Noti,   "알림",       Icons.Default.Notifications),
        BottomItem(Route.Profile,"내 정보",    Icons.Default.Person),
    )

    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination
        ?.hierarchy
        ?.firstOrNull { it.route in items.map { it.route }.toSet() }
        ?.route

    val mainStartId = remember(navController) {
        navController.graph.findNode(Route.MAIN)?.id
            ?: navController.graph.findStartDestination().id
    }

    NavigationBar {
        items.forEach { item ->
            val selected = currentRoute == item.route
            NavigationBarItem(
                selected = selected,
                onClick = {
                    if (!selected) {
                        navController.navigate(item.route) {
                            popUpTo(mainStartId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                },
                icon = { Icon(item.icon, contentDescription = item.label) },
                // label = { Text(item.label) } // 필요하면 주석 해제
            )
        }
    }
}
