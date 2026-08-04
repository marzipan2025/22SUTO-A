import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart';

/// 네이티브(MainActivity.kt)에서 공유된 글을 받아오는 통로
const _shareMethod = MethodChannel('suto_a/share');
const _shareEvents = EventChannel('suto_a/share_events');

void main() => runApp(const SutoApp());

const kBg = Color(0xFF101418);
const kCard = Color(0xFF1A2129);
const kLine = Color(0xFF2A3441);
const kAccent = Color(0xFFE53935); // 아이콘과 맞춘 레드

class SutoApp extends StatelessWidget {
  const SutoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '22SUTO-A',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TTSPage(),
    );
  }
}

class TTSPage extends StatefulWidget {
  const TTSPage({super.key});

  @override
  State<TTSPage> createState() => _TTSPageState();
}

class _TTSPageState extends State<TTSPage> {
  final _textController = TextEditingController();
  final _audioPlayer = AudioPlayer();

  TextToSpeech? _tts;
  final Map<String, Style> _styleCache = {};
  StreamSubscription? _intentSub;

  String _voice = 'M1';
  String _lang = 'na';
  int _steps = 8;
  double _speed = 1.05;
  bool _busy = false;
  bool _ready = false;
  String _status = '음성 엔진 준비 중...';

  static const _voices = {
    'M1': '남성 1', 'M2': '남성 2', 'M3': '남성 3', 'M4': '남성 4', 'M5': '남성 5',
    'F1': '여성 1', 'F2': '여성 2', 'F3': '여성 3', 'F4': '여성 4', 'F5': '여성 5',
  };

  @override
  void initState() {
    super.initState();
    _loadModels();
    _initShareIntent();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _audioPlayer.dispose();
    _textController.dispose();
    super.dispose();
  }

  // ---- 공유 수신 (구글드라이브/문서 앱 등에서 "공유 → 22SUTO-A") ----
  void _initShareIntent() {
    if (!Platform.isAndroid) return;

    // 앱이 켜져 있는 동안 들어오는 공유
    _intentSub = _shareEvents.receiveBroadcastStream().listen(
          (event) => _onShared(event as String?),
          onError: (e) => logger.e('share event error', error: e),
        );

    // 공유로 앱이 처음 열린 경우
    _shareMethod
        .invokeMethod<String>('getInitialText')
        .then(_onShared)
        .catchError((e) => logger.e('initial share error', error: e));
  }

  void _onShared(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return;
    _textController.text = t;
    if (_ready && !_busy) _speak();
  }

  // ---- 모델/목소리 로드 ----
  Future<void> _loadModels() async {
    try {
      _tts = await loadTextToSpeech('assets/onnx', useGpu: false);
      await _loadStyle(_voice);
      setState(() {
        _ready = true;
        _status = '준비 완료. 문장을 입력하거나 다른 앱에서 공유하세요.';
      });
    } catch (e, st) {
      logger.e('model load failed', error: e, stackTrace: st);
      setState(() => _status = '엔진 준비 실패: $e');
    }
  }

  Future<Style> _loadStyle(String voice) async {
    return _styleCache[voice] ??=
        await loadVoiceStyle(['assets/voice_styles/$voice.json']);
  }

  // ---- 합성 + 재생 ----
  Future<void> _speak() async {
    final text = _textController.text.trim();
    if (_tts == null || text.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _status = '음성 만드는 중...';
    });

    try {
      final style = await _loadStyle(_voice);
      final result =
          await _tts!.call(text, _lang, style, _steps, speed: _speed);
      final wav = (result['wav'] as List).cast<double>();
      final durationS = (result['duration'] as List).cast<double>()[0];

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/suto_${DateTime.now().millisecondsSinceEpoch}.wav';
      writeWavFile(path, wav, _tts!.sampleRate);

      await _audioPlayer.setAudioSource(AudioSource.uri(Uri.file(path)));
      await _audioPlayer.play();
      setState(
          () => _status = '재생 중 (${durationS.toStringAsFixed(1)}초)');
    } catch (e, st) {
      logger.e('synthesis failed', error: e, stackTrace: st);
      setState(() => _status = '오류: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await _audioPlayer.stop();
    setState(() => _status = '정지했어요.');
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('22',
                      style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800)),
                  const Text('SUTO-A',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: kAccent)),
                ],
              ),
              const Text('Supertonic 3 · 내 폰에서 바로 만드는 음성',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kLine),
                ),
                child: TextField(
                  controller: _textController,
                  maxLines: 7,
                  minLines: 5,
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(14),
                    border: InputBorder.none,
                    hintText:
                        '여기에 읽어줄 글을 입력하세요.\n구글드라이브·문서 앱에서 "공유 → 22SUTO-A"를 눌러도 돼요.',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _voice,
                      decoration: _dec('목소리'),
                      items: _voices.entries
                          .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text('${e.value} (${e.key})')))
                          .toList(),
                      onChanged: (v) => setState(() => _voice = v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _lang,
                      decoration: _dec('언어'),
                      items: availableLangs
                          .map((l) => DropdownMenuItem(
                              value: l,
                              child: Text(l == 'na' ? '자동 (na)' : l)))
                          .toList(),
                      onChanged: (v) => setState(() => _lang = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _slider('속도', _speed.toStringAsFixed(2), _speed, 0.7, 2.0,
                  (v) => setState(() => _speed = v)),
              _slider('품질', '$_steps', _steps.toDouble(), 5, 12,
                  (v) => setState(() => _steps = v.round())),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: kAccent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: (_ready && !_busy) ? _speak : null,
                      child: const Text('▶ 읽어주기',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _stop,
                      child: const Text('■ 정지'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: _status.startsWith('오류') ||
                            _status.startsWith('엔진 준비 실패')
                        ? const Color(0xFFFF7676)
                        : Colors.white54,
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: kCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kLine),
        ),
      );

  Widget _slider(String label, String value, double v, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 44, child: Text(label)),
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            activeColor: kAccent,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
            width: 44,
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(color: kAccent))),
      ],
    );
  }
}
