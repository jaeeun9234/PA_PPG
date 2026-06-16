// app/src/main/java/com/example/heartsync/service/NotificationHelper.kt
package com.example.heartsync.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat

object NotificationHelper {

    fun ensureChannel(ctx: Context, id: String, name: String) {
        if (Build.VERSION.SDK_INT >= 26) {
            val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(id) == null) {
                val ch = NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW)
                mgr.createNotificationChannel(ch)
            }
        }
    }

    /**
     * 포그라운드 알림 업데이트/표시
     *
     * @param notifyId  Notification ID (예: MeasureService.NOTI_ID)
     * @param channelId 알림 채널 ID (예: MeasureService.NOTI_CHANNEL_ID)
     * @param title     알림 제목
     * @param text      알림 내용
     * @param smallIcon 아이콘 리소스 (없으면 시스템 기본 아이콘 사용)
     */
    fun update(
        ctx: Context,
        notifyId: Int,
        channelId: String,
        title: String,
        text: String,
        smallIcon: Int = android.R.drawable.stat_notify_sync
    ) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif = NotificationCompat.Builder(ctx, channelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .build()
        nm.notify(notifyId, notif)
    }

    /** 필요하면 알림 취소용 */
    fun cancel(ctx: Context, notifyId: Int) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(notifyId)
    }

    /** 필요하면 startForeground용으로 Notification 객체만 만들고 싶을 때 */
    fun build(
        ctx: Context,
        channelId: String,
        title: String,
        text: String,
        smallIcon: Int = android.R.drawable.stat_notify_sync
    ): Notification {
        return NotificationCompat.Builder(ctx, channelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .build()
    }
}
