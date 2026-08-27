package com.artbrain.suto_a

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.ZipInputStream
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

/**
 * - 다른 앱에서 "공유 → 22SUTO-A"로 보낸 글을 Flutter로 전달
 * - 화면이 꺼져도 재생이 이어지도록 포그라운드 서비스를 켜고 끈다
 * - 첫 화면의 "문서 불러오기" 버튼 → 시스템 파일 선택창을 열고 글을 뽑아 전달
 * - 새 버전 확인에 필요한 지금 버전을 알려주고, 내려받은 APK 를 설치 화면에 넘긴다
 */
class MainActivity : FlutterActivity() {

    private val shareChannelName = "suto_a/share"
    private val shareEventsName = "suto_a/share_events"
    private val playbackChannelName = "suto_a/playback"
    private val fileChannelName = "suto_a/file"
    private val updateChannelName = "suto_a/update"

    private val notificationPermissionCode = 9101
    private val pickDocumentRequestCode = 9201

    private var initialText: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private var playbackChannel: MethodChannel? = null
    private var pendingFileResult: MethodChannel.Result? = null

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

        // ---- 문서 불러오기 ----
        // ---- 새 버전 ----
        // 확인·내려받기는 Flutter 쪽(lib/update_check.dart)이 한다. 여기서는
        // Flutter 가 알 수 없는 두 가지만 맡는다 — 지금 깔린 버전, 그리고 설치 화면 띄우기.
        MethodChannel(messenger, updateChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                // pubspec 의 version 이 그대로 versionName 으로 들어간다
                "version" -> result.success(
                    packageManager.getPackageInfo(packageName, 0).versionName
                )

                // 내려받은 APK 를 시스템 설치 화면에 넘긴다.
                // 설치 자체는 시스템이 하고 사용자가 확인을 누른다 — 앱이 몰래 깔 수는 없다.
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("no_path", "설치할 파일 경로가 없다", null)
                        return@setMethodCallHandler
                    }
                    val file = File(path)
                    if (!file.exists()) {
                        result.error("not_found", "받아둔 파일을 찾을 수 없다", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", file
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                // 넘겨받은 쪽이 이 파일을 읽을 수 있게 한 번만 열어 준다
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                // 받아둔 것이 없거나 설치가 막혔을 때 릴리스 페이지로 보낸다
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("no_url", "열 주소가 없다", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, fileChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> {
                    if (pendingFileResult != null) {
                        result.success(mapOf("ok" to false, "error" to "파일 선택창이 이미 열려 있어요"))
                    } else {
                        pendingFileResult = result
                        openDocumentPicker()
                    }
                }
                else -> result.notImplemented()
            }
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

    // ------------------------------------------------------------ 문서 불러오기
    private fun openDocumentPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, pickDocumentRequestCode)
        } catch (e: Exception) {
            pendingFileResult?.success(mapOf("ok" to false, "error" to "파일 선택창을 열 수 없어요"))
            pendingFileResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickDocumentRequestCode) return
        val result = pendingFileResult
        pendingFileResult = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(mapOf("ok" to false, "cancelled" to true))
            return
        }

        // 압축 풀기·XML 파싱은 짧아도 메인 스레드를 막지 않도록 별도 스레드에서 처리
        Thread {
            val response = try {
                extractDocument(uri)
            } catch (e: DocError) {
                mapOf("ok" to false, "error" to (e.message ?: "읽을 수 없는 파일"))
            } catch (e: Exception) {
                mapOf("ok" to false, "error" to "읽을 수 없는 파일")
            }
            runOnUiThread { result?.success(response) }
        }.start()
    }

    private class DocError(message: String) : Exception(message)

    private fun extractDocument(uri: Uri): Map<String, Any?> {
        val name = queryDisplayName(uri) ?: "문서"
        val ext = name.substringAfterLast('.', "").lowercase()

        val raw = when (ext) {
            "docx" -> readDocx(uri)
            "doc" -> throw DocError("예전 .doc 형식은 읽을 수 없어요. Word에서 .docx로 저장한 뒤 다시 시도해주세요.")
            "pdf" -> throw DocError("PDF는 아직 지원하지 않아요. 텍스트로 옮겨서 넣어주세요.")
            "html", "htm", "xhtml" -> stripHtml(readPlain(uri))
            "rtf" -> stripRtf(readPlain(uri))
            else -> readPlain(uri) // txt·md·csv·log·확장자 없음 등은 그대로 텍스트로 읽는다
        }

        val text = tidyText(raw)
        if (text.isEmpty()) throw DocError("읽을 글이 없어요")

        var finalText = text
        var note = ""
        if (finalText.length > MAX_CHARS) {
            finalText = finalText.substring(0, MAX_CHARS)
            note = "너무 길어 앞 ${"%,d".format(MAX_CHARS)}자만 가져왔어요"
        }

        return mapOf(
            "ok" to true,
            "text" to finalText,
            "name" to name,
            "chars" to finalText.length,
            "note" to note
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        var name: String? = null
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) name = cursor.getString(idx)
                }
            }
        } catch (_: Exception) {
            // 이름을 못 읽어도 본문은 계속 시도한다
        }
        return name?.takeIf { it.isNotBlank() }
    }

    private fun readPlain(uri: Uri): String {
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw DocError("파일을 열 수 없어요.")
        return decodeBestEffort(bytes)
    }

    /** 한글 문서는 UTF-8이 아닌 경우가 흔해서 차례로 시도한다 */
    private fun decodeBestEffort(bytes: ByteArray): String {
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
            return String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
        }
        for (enc in ENCODINGS) {
            try {
                val decoder = Charset.forName(enc).newDecoder()
                decoder.onMalformedInput(CodingErrorAction.REPORT)
                decoder.onUnmappableCharacter(CodingErrorAction.REPORT)
                return decoder.decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) {
                continue
            }
        }
        // 그래도 안 되면 읽을 수 없는 글자는 버리고 진행
        return String(bytes, Charsets.UTF_8)
    }

    private fun readDocx(uri: Uri): String {
        val input = contentResolver.openInputStream(uri)
            ?: throw DocError("Word 파일을 열 수 없어요.")
        try {
            ZipInputStream(input).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    if (entry.name == "word/document.xml") {
                        return parseDocxXml(zip.readBytes())
                    }
                    entry = zip.nextEntry
                }
            }
        } catch (e: DocError) {
            throw e
        } catch (e: Exception) {
            throw DocError("Word 파일을 열 수 없어요. 파일이 손상되었을 수 있어요.")
        }
        throw DocError("Word 파일을 열 수 없어요. 파일이 손상되었을 수 있어요.")
    }

    /** docx는 zip 안의 word/document.xml에 본문이 들어 있다 (문단 <w:p> 안에 <w:t> 텍스트 조각들) */
    private fun parseDocxXml(bytes: ByteArray): String {
        val factory = XmlPullParserFactory.newInstance()
        factory.isNamespaceAware = true
        val parser = factory.newPullParser()
        parser.setInput(ByteArrayInputStream(bytes), "UTF-8")

        val paragraphs = mutableListOf<String>()
        val sb = StringBuilder()
        var insideT = false
        var eventType = parser.eventType
        while (eventType != XmlPullParser.END_DOCUMENT) {
            when (eventType) {
                XmlPullParser.START_TAG -> {
                    if (parser.namespace == WORD_NS) {
                        when (parser.name) {
                            "p" -> sb.setLength(0)
                            "t" -> insideT = true
                            "br", "cr" -> sb.append("\n")
                            "tab" -> sb.append(" ")
                        }
                    }
                }
                XmlPullParser.TEXT -> {
                    if (insideT) sb.append(parser.text)
                }
                XmlPullParser.END_TAG -> {
                    if (parser.namespace == WORD_NS) {
                        when (parser.name) {
                            "t" -> insideT = false
                            "p" -> {
                                val line = sb.toString().trim()
                                if (line.isNotEmpty()) paragraphs.add(line)
                            }
                        }
                    }
                }
            }
            eventType = parser.next()
        }
        return paragraphs.joinToString("\n")
    }

    private fun stripHtml(text: String): String {
        var t = Regex("(?is)<(script|style)[^>]*>.*?</\\1>").replace(text, " ")
        t = Regex("(?i)<(br|/p|/div|/li|/h[1-6])[^>]*>").replace(t, "\n")
        t = Regex("<[^>]+>").replace(t, " ")
        return unescapeHtml(t)
    }

    private fun unescapeHtml(s: String): String {
        var t = Regex("&#x([0-9a-fA-F]+);").replace(s) { m ->
            runCatching { String(Character.toChars(m.groupValues[1].toInt(16))) }.getOrDefault(" ")
        }
        t = Regex("&#([0-9]+);").replace(t) { m ->
            runCatching { String(Character.toChars(m.groupValues[1].toInt())) }.getOrDefault(" ")
        }
        return t
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
    }

    private fun stripRtf(text: String): String {
        if (!text.take(200).contains("\\rtf")) return text
        var t = Regex("\\\\'([0-9a-fA-F]{2})").replace(text, " ")
        t = Regex("\\\\[a-zA-Z]+-?\\d* ?").replace(t, " ")
        return t.replace("{", " ").replace("}", " ")
    }

    private fun tidyText(text: String): String {
        var t = text.replace("\r\n", "\n").replace("\r", "\n")
        t = Regex("[ \\t]+").replace(t, " ")
        t = Regex("\\n{3,}").replace(t, "\n\n") // 빈 줄이 너무 많으면 줄인다
        return t.trim()
    }

    companion object {
        private const val WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        private val ENCODINGS = listOf("UTF-8", "MS949", "EUC-KR", "UTF-16")
        private const val MAX_CHARS = 300_000 // 너무 큰 파일은 잘라서 앱이 멈추지 않게 한다
    }
}
