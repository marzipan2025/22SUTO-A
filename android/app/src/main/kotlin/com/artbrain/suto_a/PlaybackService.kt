package com.artbrain.suto_a

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 화면이 꺼져 있거나 다른 앱을 쓰는 동안에도 재생이 계속되도록 유지하는 포그라운드 서비스.
 * 알림에 현재 읽고 있는 문장을 표시하고, 정지 버튼을 제공한다.
 */
class PlaybackService : Service() {

    companion object {
        const val ACTION_START = "com.artbrain.suto_a.START"
        const val ACTION_UPDATE = "com.artbrain.suto_a.UPDATE"
        const val ACTION_STOP = "com.artbrain.suto_a.STOP"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"

        private const val CHANNEL_ID = "suto_a_playback"
        private const val NOTIFICATION_ID = 2201

        /** 알림의 정지 버튼이 눌렸을 때 Flutter 쪽에 알리기 위한 콜백 */
        var onStopRequested: (() -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                onStopRequested?.invoke()
                stopSelfSafely()
                return START_NOT_STICKY
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "읽는 중"
                val progress = intent?.getStringExtra(EXTRA_PROGRESS) ?: ""
                startForegroundCompat(buildNotification(text, progress))
                acquireWakeLock()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ 알림
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "읽어주기",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "22SUTO-A가 글을 읽는 동안 표시됩니다."
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String, progress: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(if (progress.isEmpty()) "22SUTO-A" else "22SUTO-A · $progress")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                Notification.Action.Builder(null, "정지", stopIntent).build()
            )
            .build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopSelfSafely() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    // -------------------------------------------------------------- WakeLock
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "22SUTO-A::playback"
        ).apply { acquire(3 * 60 * 60 * 1000L) } // 최대 3시간 안전장치
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }
}
