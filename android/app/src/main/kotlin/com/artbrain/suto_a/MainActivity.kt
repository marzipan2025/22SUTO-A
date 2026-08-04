package com.artbrain.suto_a

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 다른 앱(구글드라이브·문서 등)에서 "공유 → 22SUTO-A"로 보낸 글을 Flutter로 넘긴다.
 * - MethodChannel: 앱이 꺼져 있다가 공유로 열린 경우 최초 텍스트 조회
 * - EventChannel: 앱이 켜져 있는 동안 추가로 들어오는 공유 수신
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "suto_a/share"
    private val eventChannelName = "suto_a/share_events"

    private var initialText: String? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initialText = extractText(intent)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialText" -> {
                        result.success(initialText)
                        initialText = null // 한 번만 전달
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })
    }

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
