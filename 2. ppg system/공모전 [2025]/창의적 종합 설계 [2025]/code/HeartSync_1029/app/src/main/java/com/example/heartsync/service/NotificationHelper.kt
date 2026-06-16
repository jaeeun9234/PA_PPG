// app/src/main/java/com/example/heartsync/service/NotificationHelper.kt
package com.example.heartsync.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

object NotificationHelper {
    fun ensureChannel(ctx: Context, id: String, name: String) {
        if (Build.VERSION.SDK_INT >= 26) {
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW)
            mgr.createNotificationChannel(ch)
        }
    }
}
