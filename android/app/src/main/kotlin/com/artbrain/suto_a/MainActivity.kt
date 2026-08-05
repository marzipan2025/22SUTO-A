package com.artbrain.suto_a

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * - 다른 앱에서 "공유 → 22SUTO-A"로 보낸 글을 Flutter로 전달
 * - 화면이 꺼져도 재생이 이어지도록 포그라운드 서비스를 켜고 끈다
 */
class MainActivity : FlutterActivity() {

    private val shareChannelName = "suto_a/share"
    private val shareEventsName = "suto_a/share_events"
    private val playbackChannelName = "suto_a/playback"

    private val notificationPermissionCode = 9101

    private var initialText: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private var playbackChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initialText = extractText(intent)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ---- 공유 수신 ----
        MethodChannel(messenger, shareChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    result.success(initialText)
                    initialText = null
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, shareEventsName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            }
        )

        // ---- 백그라운드 재생 제어 ----
        playbackChannel = MethodChannel(messenger, playbackChannelName).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        requestNotificationPermissionIfNeeded()
                        sendServiceIntent(
                            PlaybackService.ACTION_START,
                            call.argument<String>("text") ?: "읽는 중",
                            call.argument<String>("progress") ?: ""
                        )
                        result.success(true)
                    }
                    "update" -> {
                        sendServiceIntent(
                            PlaybackService.ACTION_UPDATE,
                            call.argument<String>("text") ?: "읽는 중",
                            call.argument<String>("progress") ?: ""
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, PlaybackService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // 알림의 "정지" 버튼 → Flutter에 전달
        PlaybackService.onStopRequested = {
            runOnUiThread { playbackChannel?.invokeMethod("stopFromNotification", null) }
        }
    }

    override fun onDestroy() {
        PlaybackService.onStopRequested = null
        stopService(Intent(this, PlaybackService::class.java))
        super.onDestroy()
    }

    private fun sendServiceIntent(action: String, text: String, progress: String) {
        val intent = Intent(this, PlaybackService::class.java)
            .setAction(action)
            .putExtra(PlaybackService.EXTRA_TEXT, text)
            .putExtra(PlaybackService.EXTRA_PROGRESS, progress)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionCode
            )
        }
    }

    // ------------------------------------------------------------ 공유 수신
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractText(intent)?.let { text ->
            val sink = eventSink
            if (sink != null) sink.success(text) else initialText = text
        }
    }

    /** ACTION_SEND(텍스트 공유)와 PROCESS_TEXT(텍스트 선택 후 처리)를 모두 지원 */
    private fun extractText(intent: Intent?): String? {
        if (intent == null) return null
        val text: CharSequence? = when (intent.action) {
            Intent.ACTION_SEND ->
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
                    ?: intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)
            Intent.ACTION_PROCESS_TEXT ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            else -> null
        }
        return text?.toString()?.takeIf { it.isNotBlank() }
    }
}
