import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/narration_engine.dart';
import 'package:suto_a/settings_store.dart';
import 'package:suto_a/status_icon.dart';

/// 네이티브(MainActivity.kt)와 주고받는 통로
const _shareMethod = MethodChannel('suto_a/share');
const _shareEvents = EventChannel('suto_a/share_events');
const _playback = MethodChannel('suto_a/playback');
const _fileMethod = MethodChannel('suto_a/file');

void main() => runApp(const SutoApp());

const kBg = Color(0xFF101418);
const kCard = Color(0xFF1A2129);
const kLine = Color(0xFF2A3441);
const kAccent = Color(0xFFE53935); // 아이콘과 맞춘 레드 (버튼)
const kSynth = Color(0xFFB9C4CF); // 합성 트랙 (중립)
const kPlay = Color(0xFF4DA3FF); // 재생 트랙 (파랑 = 지금 재생 중)

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
        colorScheme:
            ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
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
  final _engine = NarrationEngine();
  final _listController = ScrollController();

  StreamSubscription? _intentSub;
  Timer? _saveTimer;
  Timer? _userScrollTimer;

  // 문장 전체를 줄임 없이 보여주므로 항목 높이가 제각각이다.
  // 정확한 자동 스크롤을 위해 각 항목의 높이를 직접 계산해 캐시한다.
  static const _bodyStyle = TextStyle(fontSize: 13, height: 1.4);
  static const _itemVerticalPadding = 16.0; // 위아래 안쪽 여백
  static const _itemGap = 8.0; // 항목 사이 간격
  static const _itemMinHeight = 44.0;
  final Map<int, double> _extentCache = {};
  double _cachedWidth = 0;

  int _lastScrolledIndex = -1;
  bool _userScrolling = false;

  Settings _settings = Settings();
  bool _ready = false;
  bool _showList = false; // 입력 화면 ↔ 진행 화면
  bool _pickingFile = false;
  String? _menuHint;

  static const _voiceNames = {
    'M1': '남성 1', 'M2': '남성 2', 'M3': '남성 3', 'M4': '남성 4', 'M5': '남성 5',
    'F1': '여성 1', 'F2': '여성 2', 'F3': '여성 3', 'F4': '여성 4', 'F5': '여성 5',
  };

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _engine.onSentenceChanged = _onSentenceChanged;
    _playback.setMethodCallHandler(_onPlaybackCall);
    _boot();
    _initShareIntent();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _saveTimer?.cancel();
    _userScrollTimer?.cancel();
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    _textController.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// 지난번 설정을 불러온 뒤 모델을 준비한다
  Future<void> _boot() async {
    _settings = await loadSettings();
    _applySettingsToEngine();
    if (mounted) setState(() {});
    try {
      await _engine.loadModels();
      if (mounted) setState(() => _ready = true);
    } catch (e, st) {
      logger.e('모델 로드 실패', error: e, stackTrace: st);
      if (mounted) setState(() {});
    }
  }

  void _applySettingsToEngine() {
    final at = _engine.setParams(
      voice: _settings.voice,
      lang: _settings.lang,
      speed: _settings.speed,
      steps: _settings.steps,
    );
    if (_engine.isRunning && at != null) {
      _menuHint = '바뀐 설정은 $at번째 문장부터 적용됩니다.';
    }
  }

  /// 슬라이더를 움직이는 동안 파일을 계속 쓰지 않도록 잠시 모아서 저장
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      saveSettings(_settings);
    });
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
    _autoScroll();
  }

  void _onSentenceChanged(SentenceItem item) {
    _playback.invokeMethod('update', {
      'text': item.text,
      'progress': '${item.index + 1}/${_engine.total}',
    }).catchError((_) => null);
  }

  Future<dynamic> _onPlaybackCall(MethodCall call) async {
    if (call.method == 'stopFromNotification') await _stop();
    return null;
  }

  // ---- 항목 높이 계산 ----
  /// 글 전체가 몇 줄로 그려지는지 실제로 재서 항목 높이를 구한다.
  double _extentFor(int index, double listWidth) {
    if (listWidth != _cachedWidth) {
      _extentCache.clear();
      _cachedWidth = listWidth;
    }
    final cached = _extentCache[index];
    if (cached != null) return cached;

    final items = _engine.items;
    if (index < 0 || index >= items.length) return _itemMinHeight + _itemGap;

    // 항목 안쪽 구성: 좌우 여백 12+12, 아이콘 20, 간격 10, 테두리 2
    final textWidth = (listWidth - 12 - 12 - 20 - 10 - 2).clamp(40.0, listWidth);
    final painter = TextPainter(
      text: TextSpan(text: items[index].text, style: _bodyStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textWidth);

    final h = (painter.height + _itemVerticalPadding + 2)
            .clamp(_itemMinHeight, double.infinity) +
        _itemGap;
    _extentCache[index] = h;
    return h;
  }

  double _offsetOf(int index, double listWidth) {
    var sum = 0.0;
    for (var i = 0; i < index; i++) {
      sum += _extentFor(i, listWidth);
    }
    return sum;
  }

  // ---- 스크롤 ----
  void _autoScroll() {
    if (!_showList || _userScrolling || !_listController.hasClients) return;
    final i = _engine.currentIndex;
    if (i < 0 || i == _lastScrolledIndex) return;
    if (_cachedWidth <= 0) return;
    _lastScrolledIndex = i;

    // 현재 문장이 화면 위쪽에 오도록 (앞 한 항목만큼 여유를 둔다)
    final target = _offsetOf(i, _cachedWidth) - _extentFor(i, _cachedWidth);
    _listController.animateTo(
      target.clamp(0.0, _listController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  bool _onScrollNotification(UserScrollNotification n) {
    if (n.direction != ScrollDirection.idle) {
      _userScrolling = true;
      _userScrollTimer?.cancel();
      _userScrollTimer = Timer(const Duration(seconds: 5), () {
        _userScrolling = false;
        _lastScrolledIndex = -1;
      });
    }
    return false;
  }

  // ---- 공유 수신 ----
  void _initShareIntent() {
    if (!Platform.isAndroid) return;
    _intentSub = _shareEvents.receiveBroadcastStream().listen(
          (event) => _onShared(event as String?),
          onError: (e) => logger.e('share event error', error: e),
        );
    _shareMethod
        .invokeMethod<String>('getInitialText')
        .then(_onShared)
        .catchError((e) {
      logger.e('initial share error', error: e);
      return null;
    });
  }

  void _onShared(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return;
    _textController.text = t;
    if (_ready && !_engine.isRunning) _start();
  }

  // ---- 문서 불러오기 (txt·docx·html 등) ----
  Future<void> _pickFile() async {
    if (_pickingFile) return;
    setState(() => _pickingFile = true);
    try {
      final raw = await _fileMethod.invokeMethod<Map<Object?, Object?>>('pickDocument');
      final map = (raw ?? const <Object?, Object?>{})
          .map((k, v) => MapEntry(k.toString(), v));
      if (map['cancelled'] == true) return;
      if (map['ok'] != true) {
        _showSnack(map['error']?.toString() ?? '파일을 열 수 없어요.');
        return;
      }
      final text = map['text']?.toString() ?? '';
      final name = map['name']?.toString() ?? '문서';
      final chars = map['chars'] ?? text.length;
      final note = map['note']?.toString() ?? '';
      setState(() => _textController.text = text);
      _showSnack('$name — $chars자를 가져왔어요.${note.isNotEmpty ? ' $note' : ''}');
    } catch (e) {
      logger.e('file pick error', error: e);
      _showSnack('파일을 열 수 없어요: $e');
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- 재생 제어 ----
  Future<void> _start() async {
    // 뒤로가기로 나왔다가 다시 눌렀을 때는 이미 재생 중이므로 그냥 화면만 보여준다
    if (_engine.isRunning) {
      if (mounted) setState(() => _showList = true);
      return;
    }

    final text = _textController.text.trim();
    if (!_ready || text.isEmpty) return;

    setState(() {
      _showList = true;
      _lastScrolledIndex = -1;
      _menuHint = null;
    });
    await _playback.invokeMethod('start', {
      'text': '읽을 준비 중...',
      'progress': '',
    }).catchError((_) => null);

    await _engine.start(text);
  }

  Future<void> _stop() async {
    await _engine.stop();
    await _playback.invokeMethod('stop').catchError((_) => null);
    if (mounted) setState(() => _showList = false);
  }

  /// 뒤로가기는 입력 화면으로 돌아가기만 할 뿐, 재생 중인 소리는 멈추지 않는다.
  void _back() {
    if (mounted) setState(() {
      _showList = false;
      _menuHint = null;
    });
  }

  Future<void> _togglePause() async {
    if (_engine.isPlaying) {
      await _engine.pause();
    } else {
      await _engine.resume();
    }
  }

  // ---- 설정 시트 ----
  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void update(VoidCallback change) {
            change();
            _settings.clamp();
            _applySettingsToEngine();
            _scheduleSave();
            setSheet(() {});
            if (mounted) setState(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
                20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: kLine,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('설정',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _settings.voice,
                  decoration: _dec('목소리'),
                  items: _voiceNames.entries
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text('${e.value} (${e.key})')))
                      .toList(),
                  onChanged: (v) => update(() => _settings.voice = v!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _settings.lang,
                  decoration: _dec('언어'),
                  items: [
                    const DropdownMenuItem(value: 'auto', child: Text('자동')),
                    ...availableLangs.map(
                      (l) => DropdownMenuItem(
                        value: l,
                        child: Text(l == 'na' ? 'na (미지정)' : l),
                      ),
                    ),
                  ],
                  onChanged: (v) => update(() => _settings.lang = v!),
                ),
                const SizedBox(height: 6),
                _slider('속도', _settings.speed.toStringAsFixed(2),
                    _settings.speed, 0.7, 2.0,
                    (v) => update(() => _settings.speed = v)),
                _slider('품질', '${_settings.steps}',
                    _settings.steps.toDouble(), 2, 12,
                    (v) => update(() => _settings.steps = v.round())),
                const SizedBox(height: 8),
                Text(
                  _menuHint ?? '읽는 중에 바꾸면 아직 만들지 않은 문장부터 반영됩니다.',
                  style: TextStyle(
                    fontSize: 12,
                    color: _menuHint == null ? Colors.white38 : kPlay,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 12),
              Expanded(child: _showList ? _progressView() : _inputView()),
              const SizedBox(height: 10),
              _controls(),
              const SizedBox(height: 8),
              Text(
                _engine.error ?? _engine.status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: _engine.error != null
                      ? const Color(0xFFFF7676)
                      : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 아이콘 없이 글자만 담은 작은 버튼 (헤더에서 공용으로 쓴다)
  Widget _chipButton({required String label, required VoidCallback? onPressed}) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: kCard,
        side: const BorderSide(color: kLine),
        foregroundColor: Colors.white70,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 진행 화면에서는 로고 자리에 뒤로 버튼이 나타난다 (눌러도 재생은 멈추지 않는다)
        if (_showList)
          _chipButton(label: '뒤로', onPressed: _back)
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: '22',
                      style: TextStyle(
                          fontSize: 23, fontWeight: FontWeight.w800)),
                  TextSpan(
                      text: 'SUTO-A',
                      style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          color: kAccent)),
                ]),
              ),
              Text('Supertonic 3 · 내 폰에서 바로 만드는 음성',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        const Spacer(),
        if (_showList)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '${_engine.lang} · ${_engine.doneCount}/${_engine.total}',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
        // 문서 불러오기는 입력 화면에서만 필요하다
        if (!_showList)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _chipButton(
              label: _pickingFile ? '여는 중' : '문서',
              onPressed: _pickingFile ? null : _pickFile,
            ),
          ),
        // 설정 메뉴는 입력 화면과 진행 화면 모두에서 열 수 있다
        _chipButton(label: '설정', onPressed: _openSettings),
      ],
    );
  }

  // ---- 입력 화면 ----
  Widget _inputView() {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLine),
      ),
      child: TextField(
        controller: _textController,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.all(14),
          border: InputBorder.none,
          hintText:
              '읽어줄 글을 붙여넣으세요. 아무리 길어도 괜찮아요.\n\n구글드라이브·문서 앱에서 "공유 → 22SUTO-A"를 눌러도 됩니다.',
        ),
      ),
    );
  }

  // ---- 진행 화면 ----
  Widget _progressView() {
    return Column(
      children: [
        _trackBoard(),
        const SizedBox(height: 12),
        Expanded(child: _sentenceList()),
      ],
    );
  }

  // 합성중 번호 · 재생중 번호 · 대기열 숫자만 보여준다 (문장 미리보기·막대는 뺐다)
  Widget _trackBoard() {
    final synthIdx = _engine.synthesizingIndex;
    final playIdx = _engine.currentIndex;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLine),
      ),
      child: Row(
        children: [
          _trackRow(
            label: '합성',
            color: kSynth,
            active: synthIdx >= 0,
            index: synthIdx,
          ),
          const SizedBox(width: 20),
          _trackRow(
            label: '재생',
            color: kPlay,
            active: _engine.isPlaying && !_engine.isStalled,
            index: playIdx,
          ),
          const Spacer(),
          const Text('대기열',
              style: TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(width: 6),
          Text('${_engine.readyCount}개',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: kSynth,
              )),
        ],
      ),
    );
  }

  Widget _trackRow({
    required String label,
    required Color color,
    required bool active,
    required int index,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: active ? color : Colors.white30,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          index >= 0 ? '#${index + 1}' : '-',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: active ? color : Colors.white24,
          ),
        ),
      ],
    );
  }

  Widget _sentenceList() {
    final items = _engine.items;
    return LayoutBuilder(builder: (context, constraints) {
      // 화면 너비가 바뀌면 높이 계산을 다시 한다
      if (constraints.maxWidth != _cachedWidth) {
        _extentCache.clear();
        _cachedWidth = constraints.maxWidth;
      }
      return NotificationListener<UserScrollNotification>(
        onNotification: _onScrollNotification,
        child: ListView.builder(
          controller: _listController,
          itemCount: items.length,
          // 문장마다 높이가 다르므로 각각 계산해 넘긴다 (스크롤이 정확해진다)
          itemExtentBuilder: (index, _) =>
              _extentFor(index, constraints.maxWidth),
          itemBuilder: (context, i) {
          final it = items[i];
          final isCurrent = it.status == SentenceStatus.playing;

          return Padding(
            padding: const EdgeInsets.only(bottom: _itemGap),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              // 문장을 누르면 그 지점부터 읽고, 뒤 문장들을 이어서 합성한다
              onTap: () {
                _lastScrolledIndex = i;
                _engine.seekToUnit(i);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isCurrent ? kPlay.withValues(alpha: 0.10) : kCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isCurrent ? kPlay : kLine),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: StatusIcon(it.status),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        it.text, // 줄임 없이 전체를 보여준다
                        style: _bodyStyle.copyWith(
                          color: it.status == SentenceStatus.done
                              ? Colors.white30
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        ),
      );
    });
  }

  // ---- 하단 버튼 ----
  Widget _controls() {
    if (!_showList) {
      return SizedBox(
        height: 54,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kAccent),
          onPressed: _ready ? _start : null,
          child: Text(
            _ready ? '읽어주기' : '준비 중...',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _togglePause,
            child: Text(
              _engine.isPlaying ? '일시정지' : '이어듣기',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              foregroundColor: kAccent,
            ),
            onPressed: _stop,
            child: const Text('정지'),
          ),
        ),
      ],
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: kBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kLine),
        ),
      );

  Widget _slider(String label, String value, double v, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
            width: 40, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
              value: v,
              min: min,
              max: max,
              activeColor: kAccent,
              onChanged: onChanged),
        ),
        SizedBox(
          width: 42,
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: kAccent)),
        ),
      ],
    );
  }
}
