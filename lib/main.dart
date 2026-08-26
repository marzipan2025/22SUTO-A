import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/narration_engine.dart';
import 'package:suto_a/pixel.dart';
import 'package:suto_a/settings_store.dart';
import 'package:suto_a/source_store.dart';
import 'package:suto_a/status_icon.dart';
import 'package:suto_a/theme.dart';
import 'package:suto_a/toast.dart';

/// 네이티브(MainActivity.kt)와 주고받는 통로
const _shareMethod = MethodChannel('suto_a/share');
const _shareEvents = EventChannel('suto_a/share_events');
const _playback = MethodChannel('suto_a/playback');
const _fileMethod = MethodChannel('suto_a/file');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 고정 — 가로 회전은 쓰지 않는다
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const SutoApp());
}

class SutoApp extends StatelessWidget {
  const SutoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '22SUTO-A',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: kBodyFamily,
        scaffoldBackgroundColor: kBg,
        canvasColor: kBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kYellow,
          brightness: Brightness.dark,
        ).copyWith(surface: kBg),
        // 각진 화면에 동그란 물결은 어울리지 않는다
        splashFactory: NoSplash.splashFactory,
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
  /// 하단 인풋박스 — 셀이 되지 않는 일회성 단문 재생 칸.
  /// 여기에 한 글자라도 있으면 선택된 셀보다 우선한다.
  final _shortController = TextEditingController();
  final _shortFocus = FocusNode();

  final _engine = NarrationEngine();
  final _listController = ScrollController();

  /// 입력 화면에 쌓이는 소스 목록. 항상 하나가 선택된 상태를 유지한다.
  List<SourceItem> _sources = [];
  String? _selectedId;

  StreamSubscription? _intentSub;
  Timer? _saveTimer;
  Timer? _userScrollTimer;
  Timer? _progressTimer;

  // 문장 전체를 줄임 없이 보여주므로 항목 높이가 제각각이다.
  // 정확한 자동 스크롤을 위해 각 항목의 높이를 직접 계산해 캐시한다.
  static const _bodyStyle = TextStyle(fontSize: 13, height: 1.4);
  static const _itemVerticalPadding = 20.0; // 위아래 안쪽 여백 (10 + 10)
  static const _itemSidePadding = 12.0; // 좌우 안쪽 여백
  static const _itemGap = 4.0; // 항목 사이 간격

  // 문장 카드 왼쪽의 상태 그림 — 격자 한 칸 크기와 본문까지의 거리
  static const _iconCell = 2.5;
  static const _iconGap = 10.0;
  /// 그림 윗선을 본문 첫 줄 윗선에 맞추려고 내리는 양
  static const _iconTop = 3.0;
  /// 지우기 가위표는 다른 그림보다 한 눈금 작게 (20dp → 16dp).
  /// 같은 크기로 두면 글보다 가위표가 먼저 눈에 들어온다.
  static const _crossCell = 2.0;
  /// 상태 그림이 차지하는 폭 (StatusIcon 이 늘 같은 크기로 잡아 둔다)
  static const _iconWidth = 7 * _iconCell;

  // 문장 셀 번호 (본문 아래에 한 줄 차지)
  static const _numberFontSize = 10.0;
  static const _numberLineFactor = 1.4;
  static const _numberStyle = TextStyle(
    fontFamily: kDisplayFamily,
    fontSize: _numberFontSize,
    height: _numberLineFactor,
    color: kMuted,
  );
  static const _itemMinHeight = 44.0;

  /// 계산값과 실제 렌더링 사이의 안전 여유분
  static const _itemSlack = 6.0;
  /// 문장 번호 → (그때 잰 문장, 계산한 높이).
  ///
  /// 번호만으로 캐시하면 다른 글로 바뀌었을 때 이전 글의 높이를 그대로
  /// 돌려주게 된다. 잰 대상 문장을 같이 들고 있다가 다르면 다시 잰다.
  final Map<int, (String, double)> _extentCache = {};
  double _cachedWidth = 0;
  // 시스템 글꼴 배율. 이게 1.0이 아니면 실제 그려지는 글자가 커지므로
  // 높이 계산에도 똑같이 반영해야 한다.
  TextScaler _scaler = TextScaler.noScaling;
  double _cachedScale = 1.0;

  /// 실제로 그려질 때 쓰이는 본문 스타일 (테마의 기본 스타일과 합친 것).
  ///
  /// _bodyStyle에는 fontFamily가 없어서 그대로 재면 플랫폼 기본 폰트로
  /// 계산된다. 한글은 폰트마다 글자 폭이 달라 줄바꿈 위치가 바뀌고,
  /// 줄 수가 통째로 달라져 높이가 크게 어긋난다.
  TextStyle? _measureStyle;

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
    _progressTimer?.cancel();
    _persistProgress();
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    _shortController.dispose();
    _shortFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// 지난번 설정과 소스 목록을 불러온 뒤 모델을 준비한다
  Future<void> _boot() async {
    _settings = await loadSettings();
    _applySettingsToEngine();

    _sources = await loadSources();
    // 앱을 켰을 때의 기본 선택은 '맨 나중에 추가한 것'
    _selectedId = _sources.isNotEmpty ? _sources.last.id : null;

    // 지난번에 남은 음성 파일 정리 — 각 글의 마지막 재생 위치 파일만 남긴다
    await NarrationEngine.cleanupTemp(
      keepSourceIds: _sources.map((s) => s.id).toSet(),
      keepPaths: _sources
          .map((s) => s.lastFilePath)
          .whereType<String>()
          .toSet(),
    );

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

    // 앱이 갑자기 종료돼도 위치가 남도록 재생 중에도 저장해 둔다.
    // 문장마다 파일을 쓰면 잦으므로 잠시 모아서 한 번만 쓴다.
    _progressTimer?.cancel();
    _progressTimer =
        Timer(const Duration(seconds: 2), () => _persistProgress());
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
    final items = _engine.items;
    if (index < 0 || index >= items.length) return _itemMinHeight + _itemGap;

    final text = items[index].text;
    final cached = _extentCache[index];
    if (cached != null && cached.$1 == text) return cached.$2;

    // 항목 안쪽 구성: 좌우 여백, 상태 그림, 그림과 본문 사이 간격
    // (셀 번호는 본문 아래 별도 줄이라 본문 폭에는 영향이 없다)
    final textWidth = (listWidth - _itemSidePadding * 2 - _iconWidth - _iconGap)
        .clamp(40.0, listWidth);

    // 본문 아래 셀 번호가 한 줄을 차지하므로 더미 한 줄을 붙여서 같이 잰다.
    // 번호는 10pt지만 본문 한 줄로 넉넉히 치는 편이 안전하다.
    final painter = TextPainter(
      text: TextSpan(
        style: _measureStyle ?? _bodyStyle,
        children: [
          TextSpan(text: text),
          const TextSpan(text: '\n0'),
        ],
      ),
      textDirection: TextDirection.ltr,
      // Text 위젯은 MediaQuery의 글꼴 배율을 적용하는데 TextPainter는 기본이 배율 없음이다.
      // 이걸 빼먹으면 폰 글꼴을 키운 사용자에게서 높이가 모자라 오버플로가 난다.
      textScaler: _scaler,
    )..layout(maxWidth: textWidth);

    final h = (painter.height + _itemVerticalPadding + _itemSlack)
            .clamp(_itemMinHeight, double.infinity) +
        _itemGap;
    _extentCache[index] = (text, h);
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

  /// 다른 앱에서 '공유 → 22SUTO-A'로 들어온 글도 셀 하나로 추가하고 선택한다
  void _onShared(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return;
    _addSource(kind: SourceKind.clipboard, text: t);
  }

  // ---- 소스 목록 ----
  SourceItem? get _selectedSource {
    if (_selectedId == null) return null;
    for (final s in _sources) {
      if (s.id == _selectedId) return s;
    }
    return null;
  }

  /// 새 항목은 목록 맨 뒤에 넣고 곧바로 선택 상태로 만든다
  void _addSource({
    required SourceKind kind,
    required String text,
    String? fileName,
  }) {
    final item = SourceItem(
      id: SourceItem.newId(),
      kind: kind,
      text: text,
      fileName: fileName,
      addedAt: DateTime.now(),
    );
    setState(() {
      _sources.add(item);
      _selectedId = item.id;
    });
    saveSources(_sources);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = (data?.text ?? '').trim();
    if (t.isEmpty) {
      _showToast('클립보드가 비었어요');
      return;
    }
    _addSource(kind: SourceKind.clipboard, text: t);
  }

  /// x 버튼 → 확인 팝업 → 완전 삭제
  Future<void> _confirmDelete(SourceItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSteel,
        shape: const PixelBorder(unit: 5),
        title: const Text('삭제할까요?',
            style: TextStyle(fontSize: 16, color: Colors.white)),
        content: Text(
          item.label.length > 60
              ? '${item.label.substring(0, 60)}…'
              : item.label,
          style: const TextStyle(fontSize: 13, color: kOnSteel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: kOnSteel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: kYellow)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 대기열·합성해 둔 음성 파일·재생 위치까지 전부 없앤다
    await _engine.dropSource(item.id);

    setState(() {
      _sources.removeWhere((s) => s.id == item.id);
      // 지운 게 선택돼 있었다면 다시 가장 최근 항목으로
      if (_selectedId == item.id) {
        _selectedId = _sources.isNotEmpty ? _sources.last.id : null;
      }
    });
    saveSources(_sources);
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
        _showToast(map['error']?.toString() ?? '열 수 없는 파일');
        return;
      }
      final text = map['text']?.toString() ?? '';
      if (text.trim().isEmpty) {
        _showToast('읽을 글이 없어요');
        return;
      }
      final name = map['name']?.toString() ?? '문서';
      final chars = map['chars'] ?? text.length;
      final note = map['note']?.toString() ?? '';
      // 경로가 아니라 뽑아낸 글을 그대로 저장한다 (원본이 사라져도 남도록)
      _addSource(kind: SourceKind.file, text: text, fileName: name);
      // 파일 이름은 바로 아래 목록에 뜨므로 토스트에서는 뺀다
      _showToast(note.isNotEmpty ? note : '$chars자 가져왔어요');
    } catch (e) {
      // 예외 원문은 로그로만 남긴다 — 토스트에 띄우면 화면을 뒤덮는다
      logger.e('file pick error', error: e);
      _showToast('열 수 없는 파일');
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  // ---- 재생 제어 ----
  /// 지금 엔진이 물고 있는 글의 진행 위치를 목록에 적어두고 파일로 저장한다
  void _persistProgress() {
    final id = _engine.sourceId;
    if (id == null) return;
    for (final s in _sources) {
      if (s.id != id) continue;

      final i = _engine.currentIndex;
      final total = _engine.total;
      // 끝까지 다 읽은 글은 위치를 처음으로 되돌린다.
      // 안 그러면 다시 눌렀을 때 마지막 문장 하나만 읽고 끝난다.
      final finished = !_engine.isRunning && total > 0 && i >= total - 1;

      if (finished) {
        s.lastIndex = 0;
        s.lastFilePath = null;
      } else {
        if (i >= 0) s.lastIndex = i;
        s.lastFilePath = _engine.currentFilePath;
      }
      saveSources(_sources);
      return;
    }
  }

  Future<void> _start() async {
    final short = _shortController.text.trim();
    final source = _selectedSource;

    // 이미 그 글을 읽고 있는 중이면 화면만 보여준다 (뒤로 갔다 다시 들어온 경우)
    if (short.isEmpty &&
        _engine.isRunning &&
        source != null &&
        _engine.sourceId == source.id) {
      if (mounted) setState(() => _showList = true);
      return;
    }

    // 인풋박스에 글자가 있으면 그것만 읽는다. 비어 있으면 선택된 셀을 읽는다.
    final text = short.isNotEmpty ? short : (source?.text.trim() ?? '');
    if (!_ready || text.isEmpty) return;

    // 다른 글로 넘어가기 전에 지금까지의 진행 위치를 남긴다
    _persistProgress();

    _shortFocus.unfocus();
    setState(() {
      _showList = true;
      _lastScrolledIndex = -1;
      _menuHint = null;
      _extentCache.clear(); // 글이 바뀌면 문장 높이 캐시도 무효
      // 단문은 일회성이므로 재생을 시작하면 칸을 비운다.
      // 안 비우면 다음에 셀을 재생하려 할 때 계속 가로챈다.
      if (short.isNotEmpty) _shortController.clear();
    });
    await _playback.invokeMethod('start', {
      'text': '읽을 준비 중...',
      'progress': '',
    }).catchError((_) => null);

    if (short.isNotEmpty) {
      // 단문은 목록에 없는 일회성이므로 이어듣기 기록을 남기지 않는다
      await _engine.start(text, sourceId: _shortSourceId);
    } else {
      await _engine.start(
        text,
        sourceId: source!.id,
        resumeIndex: source.lastIndex,
        resumeFilePath: source.lastFilePath,
      );
    }
  }

  /// 단문 재생 전용 임시 id — 목록의 어떤 글과도 겹치지 않는다
  static const _shortSourceId = 'short';

  Future<void> _stop() async {
    // 진행 위치를 먼저 남기고 멈춘다 (음성 파일은 현재 위치 주변만 보관)
    _persistProgress();
    await _engine.stop();
    _persistProgress(); // 보관 후 남은 파일 경로로 갱신
    await _playback.invokeMethod('stop').catchError((_) => null);
    if (mounted) setState(() => _showList = false);
  }

  /// 뒤로가기는 입력 화면으로 돌아가기만 할 뿐, 재생 중인 소리는 멈추지 않는다.
  void _back() {
    _persistProgress();
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
      backgroundColor: kSteel,
      isScrollControlled: true,
      shape: const PixelBorder(unit: 6),
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
                  child: Container(width: 44, height: 4, color: kMuted),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text('SETTINGS',
                      style: displayStyle(
                          size: 15, color: kYellow, letterSpacing: 2.4)),
                ),
                const SizedBox(height: 20),
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
                    color: _menuHint == null ? kMuted : kYellow,
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
    // 진행 화면에서 시스템 뒤로가기를 누르면 앱이 꺼지지 않고 입력 화면으로만 간다.
    // 합성·재생은 그대로 이어진다. 입력 화면에서는 평소대로 앱을 빠져나간다.
    return PopScope(
      canPop: !_showList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showList) _back();
      },
      child: Scaffold(
      // 배경 아무 데나 누르면 인풋박스 포커스가 풀린다
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 14),
              Expanded(child: _showList ? _progressView() : _inputView()),
              const SizedBox(height: 10),
              if (!_showList) ...[
                _shortInputRow(),
                const SizedBox(height: 12),
              ],
              _controls(),
              const SizedBox(height: 6),
              Text(
                _engine.error ?? _engine.status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: _engine.error != null ? kRed : kMuted,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
      ),
    );
  }

  /// 픽셀 아이콘을 누를 수 있게 감싼다. 그림은 작아도 손가락이 닿을 만큼 넓힌다.
  Widget _pixelTap({
    required VoidCallback? onTap,
    required Widget child,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    );
  }

  /// 1345 → 1,345
  static String _fmt(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _header() {
    if (_showList) {
      // 진행 화면 — 뒤로 · 지금 상태 · 설정
      return Row(
        children: [
          _pixelTap(
            onTap: _back,
            child: const PixelIcon(kGlyphBack, cell: 4, color: kYellow),
          ),
          Expanded(child: _headerStatus()),
          _pixelTap(
            onTap: _openSettings,
            child: const PixelIcon(kGlyphSettings, cell: 4, color: kYellow),
          ),
        ],
      );
    }

    // 입력 화면 — 이름표 · 설정
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '22',
                    style: displayStyle(
                        size: 24, color: Colors.white, weight: FontWeight.w700)),
                TextSpan(
                    text: 'SUTO-A',
                    style: displayStyle(
                        size: 24, color: kYellow, weight: FontWeight.w700)),
              ]),
            ),
            const SizedBox(height: 2),
            const Text('Supertonic 3 · 내 폰에서 바로 만드는 음성',
                style: TextStyle(fontSize: 11, color: kMuted)),
          ],
        ),
        const Spacer(),
        if (_pickingFile)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('여는 중',
                style: displayStyle(size: 12, color: kSlate)),
          ),
        _pixelTap(
          onTap: _openSettings,
          padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
          child: const PixelIcon(kGlyphSettings, cell: 4, color: kYellow),
        ),
      ],
    );
  }

  /// 진행 화면 한가운데 — 지금 무엇을 하는 중인지, 어디까지 왔는지
  Widget _headerStatus() {
    final String word;
    if (_engine.error != null) {
      word = 'ERROR';
    } else if (_engine.isPlaying) {
      word = 'PLAYING';
    } else if (_engine.isRunning) {
      word = 'PAUSED';
    } else {
      word = 'STOPPED';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            word,
            style: displayStyle(
              size: 12,
              color: _engine.error != null ? kRed : kYellow,
              weight: FontWeight.w600,
              letterSpacing: 2.4,
            ),
          ),
        ),
        const SizedBox(height: 1.25),
        Text(
          '${_fmt(_engine.doneCount)} / ${_fmt(_engine.total)}',
          style: displayStyle(size: 18, color: kSlate, weight: FontWeight.w600),
        ),
      ],
    );
  }

  // ---- 입력 화면 ----
  Widget _inputView() {
    // 목록이 비어 있으면 가운데에 큰 버튼 두 개, 아니면 위에서부터 목록
    return _sources.isEmpty ? _emptyPicker() : _sourceList();
  }

  /// 아무것도 없을 때 — 가운데 큰 버튼 두 개
  Widget _emptyPicker() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _glyphButton(
                glyph: kGlyphPaste,
                fill: kSlate,
                cell: 4,
                size: const Size(88, 74),
                onPressed: _pasteFromClipboard,
              ),
              const SizedBox(width: 12),
              _glyphButton(
                glyph: kGlyphFile,
                fill: kOlive,
                cell: 4,
                size: const Size(88, 74),
                onPressed: _pickingFile ? null : _pickFile,
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('읽어줄 글을 추가하세요',
              style: TextStyle(fontSize: 12, color: kMuted)),
        ],
      ),
    );
  }

  /// 픽셀 그림 하나만 담은 네모 버튼
  Widget _glyphButton({
    required PixelGlyph glyph,
    required Color fill,
    required double cell,
    required Size size,
    required VoidCallback? onPressed,
  }) {
    final off = onPressed == null;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: PixelCard(
        fill: off ? kSteel : fill,
        padding: EdgeInsets.zero,
        onTap: onPressed,
        child: Center(
          child: PixelIcon(glyph,
              cell: cell, color: off ? kMuted : kOnLight),
        ),
      ),
    );
  }

  /// 추가된 소스 목록 — 위에서부터 쌓인다. 항상 하나가 선택 상태.
  Widget _sourceList() {
    return PixelScrollMask(
      child: ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _sources.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = _sources[i];
        final selected = s.id == _selectedId;
        final isFile = s.kind == SourceKind.file;

        // 고른 글만 노란 카드. 나머지는 가라앉혀 둔다.
        final skin = selected ? kSkinPlaying : kSkinPending;

        // 진행 화면의 문장 카드와 같은 짜임 — 그림이 왼쪽, 글이 그 오른쪽에서
        // 그림 윗선에 맞춰 시작한다. 지우기 가위표도 같은 눈금·같은 높이.
        return PixelCard(
          fill: skin.fill,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          onTap: () => setState(() => _selectedId = s.id),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: _iconTop),
                child: PixelIcon(isFile ? kGlyphFile : kGlyphPaste,
                    cell: _iconCell, color: skin.ink),
              ),
              const SizedBox(width: _iconGap),
              Expanded(
                child: Text(
                  s.label,
                  maxLines: 2, // 붙여넣기는 앞 두 줄, 파일은 파일명
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: skin.ink,
                  ),
                ),
              ),
              // 삭제 (확인 팝업 후 완전 삭제).
              // 그림 자리는 파일 그림과 똑같이 두고, 손가락 닿을 넓이는
              // 아래쪽으로만 넓힌다 — 그래야 그림의 y가 흔들리지 않는다.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmDelete(s),
                child: Padding(
                  padding: const EdgeInsets.only(
                      left: _iconGap, top: _iconTop, bottom: 14),
                  child: PixelIcon(kGlyphCross,
                      cell: _crossCell,
                      color: skin.ink.withValues(alpha: 0.55)),
                ),
              ),
            ],
          ),
        );
      },
      ),
    );
  }

  /// 하단 인풋박스 한 줄 — 셀이 되지 않는 단문 재생용.
  /// 목록이 하나라도 있으면 오른쪽에 붙여넣기·파일추가 아이콘이 따라붙는다.
  Widget _shortInputRow() {
    return Row(
      children: [
        Expanded(
          child: PixelCard(
            fill: kSteel,
            padding: EdgeInsets.zero,
            child: TextField(
              controller: _shortController,
              focusNode: _shortFocus,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}), // 버튼 문구를 바로 바꾸기 위해
              cursorColor: kYellow,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: InputBorder.none,
                hintText: '짧은 문장 바로 재생',
                hintStyle: TextStyle(fontSize: 13, color: kOnSteel),
              ),
            ),
          ),
        ),
        if (_sources.isNotEmpty) ...[
          const SizedBox(width: 8),
          _glyphButton(
            glyph: kGlyphPaste,
            fill: kSlate,
            cell: 2.4,
            size: const Size(46, 46),
            onPressed: _pasteFromClipboard,
          ),
          const SizedBox(width: 8),
          _glyphButton(
            glyph: kGlyphFile,
            fill: kOlive,
            cell: 2.4,
            size: const Size(46, 46),
            onPressed: _pickingFile ? null : _pickFile,
          ),
        ],
      ],
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

  /// 재생중 번호 · 합성중 번호 · 대기열 숫자만 보여준다
  Widget _trackBoard() {
    final synthIdx = _engine.synthesizingIndex;
    final playIdx = _engine.currentIndex;

    return PixelCard(
      fill: kSlate,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          _boardStat(
            glyph: kGlyphPlay,
            value: playIdx >= 0 ? '${playIdx + 1}' : '-',
            dim: !(_engine.isPlaying && !_engine.isStalled),
          ),
          const SizedBox(width: 22),
          _boardStat(
            glyph: kGlyphDot,
            value: synthIdx >= 0 ? '${synthIdx + 1}' : '-',
            dim: synthIdx < 0,
          ),
          const Spacer(),
          _boardStat(
            glyph: kGlyphCheck,
            value: '${_engine.readyCount}',
            dim: _engine.readyCount == 0,
            iconLast: true,
          ),
        ],
      ),
    );
  }

  /// 대시보드의 숫자 한 칸 — 그림과 숫자 한 쌍
  Widget _boardStat({
    required PixelGlyph glyph,
    required String value,
    required bool dim,
    bool iconLast = false,
  }) {
    final ink = dim ? kOnLight.withValues(alpha: 0.35) : kOnLight;
    final icon = PixelIcon(glyph, cell: 2.6, color: ink);
    final text = Text(
      value,
      style: displayStyle(size: 18, color: ink, weight: FontWeight.w700),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: iconLast
          ? [text, const SizedBox(width: 10), icon]
          : [icon, const SizedBox(width: 10), text],
    );
  }

  Widget _sentenceList() {
    final items = _engine.items;

    // 시스템 글꼴 배율이 바뀌면 캐시해 둔 높이가 전부 틀어지므로 다시 계산한다
    final scaler = MediaQuery.textScalerOf(context);
    final scale = scaler.scale(100) / 100;
    if (scale != _cachedScale) {
      _cachedScale = scale;
      _scaler = scaler;
      _extentCache.clear();
    }

    return LayoutBuilder(builder: (context, constraints) {
      // 화면 너비가 바뀌면 높이 계산을 다시 한다
      if (constraints.maxWidth != _cachedWidth) {
        _extentCache.clear();
        _cachedWidth = constraints.maxWidth;
      }

      // 이 자리의 DefaultTextStyle(테마 폰트)과 합쳐야 실제와 같은 폭으로 재진다
      final resolved = DefaultTextStyle.of(context).style.merge(_bodyStyle);
      if (resolved != _measureStyle) {
        _measureStyle = resolved;
        _extentCache.clear();
      }
      return NotificationListener<UserScrollNotification>(
        onNotification: _onScrollNotification,
        child: PixelScrollMask(
          child: ListView.builder(
          controller: _listController,
          itemCount: items.length,
          // 문장마다 높이가 다르므로 각각 계산해 넘긴다 (스크롤이 정확해진다)
          itemExtentBuilder: (index, _) =>
              _extentFor(index, constraints.maxWidth),
          itemBuilder: (context, i) {
          final it = items[i];
          // 카드 색이 곧 상태다 — 어두운 데서 시작해 밝아졌다가 다시 가라앉는다
          final skin = skinFor(it.status);

          return Padding(
            padding: const EdgeInsets.only(bottom: _itemGap),
            // 문장을 누르면 그 지점부터 읽고, 뒤 문장들을 이어서 합성한다
            child: PixelCard(
              fill: skin.fill,
              padding: const EdgeInsets.symmetric(
                  horizontal: _itemSidePadding, vertical: _itemVerticalPadding / 2),
              onTap: () {
                _lastScrolledIndex = i;
                _engine.seekToUnit(i);
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: StatusIcon(it.status,
                        color: skin.ink, cell: _iconCell),
                  ),
                  const SizedBox(width: _iconGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.text, // 줄임 없이 전체를 보여준다
                          style: _bodyStyle.copyWith(color: skin.ink),
                        ),
                        // 셀 번호 — 본문 아래 한 줄, 좌측
                        Text('${i + 1}',
                            style: _numberStyle.copyWith(
                                color: skin.ink.withValues(alpha: 0.45))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
          ),
        ),
      );
    });
  }

  // ---- 하단 버튼 ----
  Widget _controls() {
    if (!_showList) {
      final hasShort = _shortController.text.trim().isNotEmpty;
      // 인풋박스에 글자가 있으면 그것만, 없으면 선택된 셀을 읽는다
      final canStart = _ready && (hasShort || _selectedSource != null);

      return Row(
        children: [
          _wordAction(
            label: !_ready ? 'LOADING' : (hasShort ? 'SAY' : 'PLAY'),
            size: 34,
            weight: FontWeight.w700,
            onTap: canStart ? _start : null,
          ),
          const Spacer(),
        ],
      );
    }

    // 크기가 다른 두 표시어의 '윗선'을 맞춘다.
    // 밑선을 먼저 맞춘 뒤, 캡 높이 차이만큼 작은 쪽을 끌어올리면
    // 대문자 윗선이 한 줄로 선다.
    const big = 34.0;
    const small = 23.0;
    const lift = (big - small) * kPanchangCapRatio;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _wordAction(
          label: _engine.isPlaying ? 'PAUSE' : 'PLAY',
          size: big,
          weight: FontWeight.w700,
          onTap: _togglePause,
        ),
        const Spacer(),
        Transform.translate(
          offset: const Offset(0, -lift),
          child: _wordAction(label: 'STOP', size: small, onTap: _stop),
        ),
      ],
    );
  }

  /// 테두리도 배경도 없이 글자만 놓는 버튼. 크기로 주·부를 가른다.
  Widget _wordAction({
    required String label,
    required VoidCallback? onTap,
    double size = 23,
    FontWeight weight = FontWeight.w500,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Text(
          label,
          style: displayStyle(
            size: size,
            color: onTap == null ? kSteel : kYellow,
            weight: weight,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: kOnSteel, fontSize: 13),
        filled: true,
        fillColor: kBg,
        // 픽셀 화면에서는 둥근 모서리를 쓰지 않는다
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kLine),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kLine),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: kYellow),
        ),
      );

  Widget _slider(String label, String value, double v, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
            width: 40,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.white))),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: kYellow,
              inactiveTrackColor: kSteel,
              thumbColor: kYellow,
              overlayColor: kYellow.withValues(alpha: 0.14),
              thumbShape: const PixelThumbShape(),
              trackShape: const RectangularSliderTrackShape(),
            ),
            child: Slider(value: v, min: min, max: max, onChanged: onChanged),
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(value,
              textAlign: TextAlign.right,
              style: displayStyle(size: 13, color: kYellow)),
        ),
      ],
    );
  }
}
