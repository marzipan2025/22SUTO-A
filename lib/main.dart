import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:suto_a/hangul.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/narration_engine.dart';
import 'package:suto_a/pixel.dart';
import 'package:suto_a/settings_store.dart';
import 'package:suto_a/source_store.dart';
import 'package:suto_a/status_icon.dart';
import 'package:suto_a/theme.dart';
import 'package:suto_a/update_check.dart';
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

class _TTSPageState extends State<TTSPage> with WidgetsBindingObserver {
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
  static const _bodyStyle = TextStyle(fontSize: 15, height: 1.4);
  static const _itemVerticalPadding = 20.0; // 위아래 안쪽 여백 (10 + 10)
  static const _itemSidePadding = 12.0; // 좌우 안쪽 여백
  static const _itemGap = 4.0; // 항목 사이 간격

  // 문장 카드 왼쪽의 상태 그림 — 격자 한 칸 크기와 본문까지의 거리
  static const _iconCell = 2.5;
  static const _iconGap = 10.0;
  /// 그림 윗선을 본문 첫 줄 윗선에 맞추려고 내리는 양
  static const _iconTop = 3.0;
  /// 카드 안의 그림은 전부 _iconCell 한 눈금으로 그린다 — 픽셀 알갱이가
  /// 자리마다 달라 보이지 않게.
  /// 상태 그림이 차지하는 폭 (StatusIcon 이 늘 같은 크기로 잡아 둔다)
  static final _iconWidth = statusIconWidth(_iconCell);

  /// 입력 화면 목록의 그림 자리 — 붙여넣기·파일 중 넓은 쪽에 맞춘다
  static final _sourceIconWidth = [
    kGlyphPaste.widthAt(_iconCell),
    kGlyphFile.widthAt(_iconCell),
  ].reduce((a, b) => a > b ? a : b);

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

  /// 목록이 마지막으로 움직인 때.
  ///
  /// 굴러가는 목록을 멈추려고 화면을 짚으면 그 손짓이 문장 탭으로도 잡힌다.
  /// 세우려던 것뿐인데 그 자리가 읽히기 시작하면 당황스럽다. 방금까지
  /// 움직이고 있었으면 탭을 흘려보낸다.
  DateTime? _listMovedAt;

  /// 멈춘 뒤 이만큼은 탭을 받지 않는다
  static const _tapDeadZone = Duration(milliseconds: 350);

  // ---- 머리글 ----
  /// 두 화면이 같은 높이를 쓴다. 설정 단추(36dp)에 위아래 여백을 더한 값이라,
  /// 이름표든 상태든 그 안에서 가운데로 선다.
  static const _headerHeight = 52.0;
  /// 왼쪽 끝에 붙는 단추 — 바깥쪽 여백은 두지 않는다
  static const _headerLeftPad =
      EdgeInsets.only(right: 12, top: 8, bottom: 8);
  /// 오른쪽 끝에 붙는 단추
  static const _headerRightPad =
      EdgeInsets.only(left: 12, top: 8, bottom: 8);

  Settings _settings = Settings();
  bool _ready = false;

  // ---- 새 버전 ----
  /// 켤 때 한 번 확인한 결과. 아직 확인 전이면 null.
  UpdateStatus? _update;
  /// 받는 중이면 얼마나 왔는지, 아니면 null
  DownloadProgress? _downloading;
  /// 다 받아 설치를 기다리는 파일
  File? _downloaded;
  String? _updateError;
  CancelToken? _downloadCancel;
  /// 켤 때 뜬 알림을 두 번 띄우지 않기 위한 표
  bool _updateToastShown = false;
  bool _showList = false; // 입력 화면 ↔ 진행 화면
  bool _pickingFile = false;
  Timer? _pickWatchdog;

  /// 만들어둔 음성이 차지하는 크기 (설정에서 보여준다)
  int? _voiceBytes;

  /// 타임라인을 쓸 때 마지막으로 가리킨 자리. 쓰는 동안 매 손가락마다
  /// 옮기면 그때마다 소리를 멈추고 다시 물리게 되어 버벅인다. 잠깐 모았다가
  /// 손이 멎으면 한 번만 옮긴다.
  int? _scrubTo;
  Timer? _scrubTimer;

  /// 타임라인에 손가락이 닿아 있는 동안 참.
  /// 그동안 얼굴을 옅게 해 가려진 것을 볼 수 있게 한다.
  bool _scrubTouching = false;

  /// 인풋박스에 커서가 들어가 있는 동안 참.
  /// 키패드가 올라오면 얼굴이 가려질 자리에 겹치므로 같이 옅게 한다.
  bool _shortFocused = false;

  /// 글마다 문장별로 음성을 만들어 뒀는지. 목록 카드 아래 띠에 쓴다.
  /// 폴더를 훑어야 알 수 있으므로 그때그때 재지 않고 모아 두고 쓴다.
  Map<String, List<bool>> _made = {};

  /// 목소리마다 얼굴 하나. 화면 아래에 서서 지금 누가 읽는지 알려 준다.
  static const _voiceFaces = {
    'M1': 'new_m_01', 'M2': 'new_m_02', 'M3': 'new_m_03',
    'M4': 'new_m_04', 'M5': 'new_m_05',
    'F1': 'new_f_01', 'F2': 'new_f_02', 'F3': 'new_f_03',
    'F4': 'new_f_04', 'F5': 'new_f_05',
  };

  /// 얼굴의 폭. 그림에서 투명한 가장자리를 모두 잘라내 두었으므로
  /// 이 값이 곧 보이는 얼굴의 폭이다. 높이는 그림마다 다르다.
  static const _faceWidth = 120.0;

  /// 화면 바깥 여백 (Column 의 좌우 안쪽 여백)
  static const _pagePad = 16.0;

  /// 화면 아래에 설 얼굴.
  ///
  /// 지금 들리는 음성을 만든 목소리를 따른다 — 설정을 바꿔도 이미 만들어
  /// 둔 것은 그대로 쓰므로, 설정만 보면 들리는 것과 어긋난다.
  /// 아직 아무것도 재생하지 않았으면 설정의 목소리를 보여 준다.
  String? get _faceAsset {
    final name = _voiceFaces[_engine.playingVoice ?? _settings.voice];
    return name == null ? null : 'assets/char/$name.png';
  }

  static const _voiceNames = {
    'M1': '남성 1', 'M2': '남성 2', 'M3': '남성 3', 'M4': '남성 4', 'M5': '남성 5',
    'F1': '여성 1', 'F2': '여성 2', 'F3': '여성 3', 'F4': '여성 4', 'F5': '여성 5',
  };

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _shortFocus.addListener(_onShortFocusChanged);
    _engine.onSentenceChanged = _onSentenceChanged;
    _playback.setMethodCallHandler(_onPlaybackCall);
    WidgetsBinding.instance.addObserver(this);
    _boot();
    _initShareIntent();
    _checkUpdateOnLaunch();
  }

  void _onShortFocusChanged() {
    if (_shortFocused == _shortFocus.hasFocus) return;
    setState(() => _shortFocused = _shortFocus.hasFocus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pickWatchdog?.cancel();
    _scrubTimer?.cancel();
    _intentSub?.cancel();
    _saveTimer?.cancel();
    _userScrollTimer?.cancel();
    _progressTimer?.cancel();
    _persistProgress();
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    _shortController.dispose();
    _shortFocus.removeListener(_onShortFocusChanged);
    _shortFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// 문서 선택창에서 돌아왔는데도 답이 오지 않으면 버튼을 되살린다.
  ///
  /// 선택창이 떠 있는 사이 화면이 통째로 다시 만들어지면(메모리가 모자라
  /// 뒤에서 정리되는 경우) 네이티브가 들고 있던 응답 통로가 끊긴다.
  /// 그러면 답이 영영 오지 않아 '문서' 버튼이 꺼진 채로 남는다.
  ///
  /// 정상적인 경우 결과는 화면이 돌아오기 직전에 도착하므로, 돌아온 뒤
  /// 잠깐 기다렸다가도 여전히 기다리는 중이면 끊긴 것으로 본다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_pickingFile) return;
    _pickWatchdog?.cancel();
    _pickWatchdog = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || !_pickingFile) return;
      logger.w('문서 선택 결과가 오지 않아 버튼을 되살린다');
      setState(() => _pickingFile = false);
    });
  }

  /// 지난번 설정과 소스 목록을 불러온 뒤 모델을 준비한다
  Future<void> _boot() async {
    _settings = await loadSettings();
    _applySettingsToEngine();

    _sources = await loadSources();
    // 앱을 켰을 때의 기본 선택은 '맨 나중에 추가한 것'
    _selectedId = _sources.isNotEmpty ? _sources.last.id : null;

    if (mounted) setState(() {});

    // 목록에 남은 글의 음성은 그대로 두고, 없어진 글의 것만 버린다.
    // 총량이 넘치면 오래전에 넣은 글부터 (목록 앞쪽이 오래된 것이다).
    //
    // **화면을 세워 두고 기다리지 않는다.** 음성을 지우지 않고 쌓아 두므로
    // 파일이 수천 개까지 늘고, 크기를 재는 데만 몇 초가 걸린다. 그동안 첫
    // 화면이 멈춰 있었다. 급한 일이 아니니 뒤에서 하고, 끝나면 띠를 그린다.
    unawaited(() async {
      await NarrationEngine.pruneVoice(
        oldestFirst: _sources.map((s) => s.id).toList(),
        inUseSourceId: _selectedId,
      );
      if (mounted) await _refreshMade();
    }());
    // 모델을 읽는 동안에는 화면이 그려지지 않는다. 첫 그림이 나온 뒤에
    // 시작해, 아이콘만 보이는 시간을 줄인다.
    await WidgetsBinding.instance.endOfFrame;

    try {
      await _engine.loadModels();
      if (mounted) setState(() => _ready = true);
    } catch (e, st) {
      logger.e('모델 로드 실패', error: e, stackTrace: st);
      if (mounted) setState(() {});
    }
  }

  /// 타임라인에서 자리를 가리켰을 때.
  ///
  /// 흰 점은 손가락을 곧바로 따라온다. 소리를 옮기는 것은 손이 멎은 뒤
  /// 한 번만 한다 — 쓰는 동안 매번 옮기면 그때마다 소리를 멈추고 다시
  /// 물리게 되어 버벅인다.
  void _scrub(int index) {
    if (_scrubTo == index) return;
    setState(() => _scrubTo = index);
    _scrubTimer?.cancel();
    _scrubTimer = Timer(const Duration(milliseconds: 120), () {
      final at = _scrubTo;
      if (at == null) return;
      if (mounted) setState(() => _scrubTo = null);
      _engine.seekToUnit(at);
    });
  }

  /// 목록 카드 아래 띠를 다시 잰다.
  ///
  /// 폴더를 훑는 일이라 화면을 그릴 때마다 할 수 없다. 글이 늘거나 줄 때,
  /// 설정이 바뀔 때, 읽기를 마치고 목록으로 돌아올 때만 다시 잰다.
  Future<void> _refreshMade() async {
    final made = await NarrationEngine.madeFlagsBatch(
      sources: [for (final s in _sources) [s.id, s.text]],
      langChoice: _settings.lang,
    );
    if (mounted) setState(() => _made = made);
  }

  /// 켤 때 조용히 한 번 확인한다.
  ///
  /// 최신이거나 GitHub 에 못 닿았으면 아무 말도 하지 않는다 — 켤 때마다
  /// "최신입니다" 를 띄우는 건 성가시기만 하다. 새 버전이 있을 때만 알린다.
  Future<void> _checkUpdateOnLaunch() async {
    final status = await fetchStatus();
    if (!mounted) return;
    setState(() => _update = status);
    if (status is UpdateAvailable && !_updateToastShown) {
      _updateToastShown = true;
      _showToast('새 버전 v${status.latest} 이 있어요 — 설정에서 받으세요');
    }
  }

  /// 설정 시트의 '저장한 용량' 칸.
  ///
  /// 한 번 만든 음성은 버리지 않고 들고 있다가, 그 글에 다시 들어오면
  /// 곧바로 들려준다. 44.1kHz 무압축이라 한 문장이 0.7MB쯤 되므로
  /// 지금 얼마나 쓰고 있는지 보이게 하고, 손으로 지울 수도 있게 한다.
  Widget _voiceRow(void Function(VoidCallback) refresh) {
    final bytes = _voiceBytes;
    Future<void> clear() async {
      await NarrationEngine.clearVoice();
      _engine.resumeAfterCleanup();
      final b = await NarrationEngine.voiceBytes();
      _voiceBytes = b;
      refresh(() {});
      if (mounted) setState(() {});
      _showToast('만들어둔 음성을 지웠어요');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('저장한 용량', style: _sheetTitle),
            const Spacer(),
            if (bytes != null && bytes > 0)
              _pixelTap(
                onTap: clear,
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: const Text('지우기', style: _sheetAction),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          bytes == null
              ? '재는 중…'
              : '${_mb(bytes)} / ${_mb(NarrationEngine.voiceLimitBytes)}',
          style: TextStyle(
              fontSize: 14, color: bytes == null ? kMuted : kOnSteel),
        ),
      ],
    );
  }

  /// 설정 시트의 업데이트 칸.
  ///
  /// [refresh] 는 시트 안의 상태를 다시 그리게 하는 손잡이다. 시트는 앱 화면과
  /// 따로 떠 있어서 setState 만으로는 다시 그려지지 않는다.
  Widget _updateRow(void Function(VoidCallback) refresh) {
    void redraw() {
      refresh(() {});
      if (mounted) setState(() {});
    }

    Future<void> check() async {
      refresh(() {
        _update = null;
        _updateError = null;
      });
      final status = await fetchStatus();
      _update = status;
      redraw();
    }

    Future<void> download(UpdateAvailable info) async {
      final url = info.apkUrl;
      if (url == null) {
        await openReleasesPage();
        return;
      }
      final cancel = CancelToken();
      _downloadCancel = cancel;
      _updateError = null;
      _downloading = DownloadProgress(0, info.bytes);
      redraw();
      try {
        final file = await downloadApk(
          url,
          cancel: cancel,
          onProgress: (p) {
            // 초당 수십 번 오므로 눈에 보일 만큼 바뀔 때만 다시 그린다
            final before = _downloading;
            if (before == null) return;
            final step = info.bytes > 0 ? info.bytes ~/ 200 : 1 << 20;
            if (p.received - before.received < step && p.received < p.total) {
              return;
            }
            _downloading = p;
            redraw();
          },
        );
        _downloaded = file;
        _downloading = null;
      } catch (e) {
        _downloading = null;
        _updateError = cancel.isCancelled ? null : '받지 못했어요';
        logger.w('업데이트 받기 실패: $e');
      }
      _downloadCancel = null;
      redraw();
    }

    final rows = <Widget>[
      Row(
        children: [
          const Text('업데이트', style: _sheetTitle),
          const Spacer(),
          if (_downloading == null && _downloaded == null)
            _pixelTap(
              onTap: check,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: const Text('확인', style: _sheetAction),
            ),
        ],
      ),
      const SizedBox(height: 5),
    ];

    final status = _update;
    final downloading = _downloading;
    final downloaded = _downloaded;

    if (downloading != null) {
      final f = downloading.fraction;
      rows.addAll([
        PixelGauge(value: f, cells: 12),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                f == null
                    ? '${_mb(downloading.received)} 받는 중'
                    : '${(f * 100).round()}%  ${_mb(downloading.received)}/${_mb(downloading.total)}',
                style: const TextStyle(fontSize: 14, color: kOnSteel),
              ),
            ),
            _pixelTap(
              onTap: () => _downloadCancel?.cancel(),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: const Text('그만', style: _sheetAction),
            ),
          ],
        ),
      ]);
    } else if (downloaded != null) {
      rows.addAll([
        const Text('다 받았어요',
            style: TextStyle(fontSize: 14, color: kOnSteel)),
        const SizedBox(height: 10),
        Row(children: [
          _pixelTap(
            onTap: () => installApk(downloaded).catchError((e) {
              _updateError = '설치 화면을 열지 못했어요';
              logger.w('설치 실패: $e');
              redraw();
            }),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: const Text('설치',
                style: TextStyle(fontSize: 16, color: kYellow)),
          ),
        ]),
      ]);
    } else if (status == null) {
      rows.add(const Text('확인 중…',
          style: TextStyle(fontSize: 14, color: kMuted)));
    } else if (status is UpToDate) {
      rows.add(Text('최신입니다. v ${status.current}',
          style: const TextStyle(fontSize: 14, color: kOnSteel)));
    } else if (status is UpdateAvailable) {
      rows.addAll([
        Text(
          'v ${status.current} → v ${status.latest}'
          '${status.bytes > 0 ? '  ·  ${_mb(status.bytes)}' : ''}',
          style: const TextStyle(fontSize: 14, color: kOnSteel),
        ),
        const SizedBox(height: 10),
        Row(children: [
          _pixelTap(
            onTap: () => download(status),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Text(status.apkUrl == null ? '릴리스 열기' : '받기',
                style: const TextStyle(fontSize: 16, color: kYellow)),
          ),
        ]),
      ]);
    } else {
      rows.addAll([
        const Text('GitHub 에 닿지 못했어요.',
            style: TextStyle(fontSize: 14, color: kMuted)),
        const SizedBox(height: 10),
        Row(children: [
          _pixelTap(
            onTap: openReleasesPage,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: const Text('릴리스 열기', style: _sheetAction),
          ),
        ]),
      ]);
    }

    if (_updateError != null) {
      rows.addAll([
        const SizedBox(height: 8),
        Text(_updateError!, style: const TextStyle(fontSize: 13, color: kRed)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// 설정 시트 아래 두 칸이 같은 결로 보이게 묶어 둔 글자 모양
  static const _sheetTitle =
      TextStyle(fontSize: 15, color: kYellow, fontWeight: FontWeight.w700);
  static const _sheetAction = TextStyle(fontSize: 14, color: kSlate);

  /// 바이트를 사람이 읽을 만한 짧은 숫자로
  static String _mb(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) {
      return '${(bytes / (1024 * mb)).toStringAsFixed(1)}GB';
    }
    return '${(bytes / mb).toStringAsFixed(0)}MB';
  }

  void _applySettingsToEngine() {
    // 돌려주는 값(바뀐 설정이 몇 번째 문장부터 먹는지)은 이제 쓰지 않는다.
    // 그 안내를 화면에서 뺐다.
    _engine.setParams(
      voice: _settings.voice,
      lang: _settings.lang,
      speed: _settings.speed,
      steps: _settings.steps,
    );
  }

  /// 슬라이더를 움직이는 동안 파일을 계속 쓰지 않도록 잠시 모아서 저장
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      saveSettings(_settings);
      // 설정이 바뀌면 쓸 수 있는 음성도 달라진다 — 띠를 다시 잰다
      unawaited(_refreshMade());
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
          // 그릴 때와 똑같은 글로 재야 줄 수가 어긋나지 않는다
          TextSpan(text: byWord(text)),
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
  void _autoScroll({bool animate = true}) {
    if (!_showList || _userScrolling || !_listController.hasClients) return;
    final i = _engine.currentIndex;
    if (i < 0 || i == _lastScrolledIndex) return;
    if (_cachedWidth <= 0) return;
    _lastScrolledIndex = i;

    // 현재 문장이 화면 위쪽에 오도록 (앞 한 항목만큼 여유를 둔다)
    final target = (_offsetOf(i, _cachedWidth) - _extentFor(i, _cachedWidth))
        .clamp(0.0, _listController.position.maxScrollExtent);
    if (animate) {
      _listController.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    } else {
      // 들어오자마자는 곧장 앉힌다. 맨 위에서부터 훑어 내려가는 것을
      // 보여 줄 이유가 없다.
      _listController.jumpTo(target);
    }
  }

  /// 문장 목록으로 들어온 직후, 읽고 있는 자리로 곧장 앉힌다.
  ///
  /// 이 자리에서 바로 옮길 수는 없다 — 목록이 아직 만들어지지 않아 높이도
  /// 폭도 모른다. 화면이 한 번 그려진 뒤에 옮긴다.
  void _jumpToCurrent() {
    _userScrolling = false;
    _userScrollTimer?.cancel();
    _lastScrolledIndex = -1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showList) return;
      _autoScroll(animate: false);
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    // 굴러가는 동안(손으로 끌든 튕겨서 흐르든) 계속 찍어 둔다
    if (n is ScrollUpdateNotification) _listMovedAt = DateTime.now();
    if (n is! UserScrollNotification) return false;
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
      // 맥에서 온 글·파일 이름은 한글이 풀어써져 있다. 여기서 붙여 두면
      // 화면도 합성기도 제대로 받는다.
      text: composeHangul(text),
      fileName: fileName == null ? null : composeHangul(fileName),
      addedAt: DateTime.now(),
    );
    setState(() {
      _sources.add(item);
      _selectedId = item.id;
    });
    saveSources(_sources);
    unawaited(_refreshMade());
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
            style: TextStyle(fontSize: 18, color: Colors.white)),
        content: Text(
          byWord(item.label.length > 60
              ? '${item.label.substring(0, 60)}…'
              : item.label),
          style: const TextStyle(fontSize: 15, color: kOnSteel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소',
                style: TextStyle(fontSize: 16, color: kOnSteel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제',
                style: TextStyle(fontSize: 16, color: kYellow)),
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
    unawaited(_refreshMade());
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
      _pickWatchdog?.cancel();
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

  /// [ignoreShort] 가 참이면 인풋박스에 글자가 있어도 고른 글을 읽는다.
  /// 목록의 카드를 눌러 들어올 때가 그렇다 — 누른 그 글이 열려야 한다.
  Future<void> _start({bool ignoreShort = false}) async {
    final short = ignoreShort ? '' : _shortController.text.trim();
    final source = _selectedSource;

    // 이미 그 글을 읽고 있는 중이면 화면만 보여준다 (뒤로 갔다 다시 들어온 경우)
    if (short.isEmpty &&
        _engine.isRunning &&
        source != null &&
        _engine.sourceId == source.id) {
      if (mounted) setState(() => _showList = true);
      _jumpToCurrent();
      return;
    }

    // 인풋박스에 글자가 있으면 그것만 읽는다. 비어 있으면 선택된 셀을 읽는다.
    // 이미 저장돼 있던 글은 풀어써진 채일 수 있다 — 읽히기 전에 붙인다
    final text =
        composeHangul(short.isNotEmpty ? short : (source?.text.trim() ?? ''));
    if (!_ready || text.isEmpty) return;

    // 다른 글로 넘어가기 전에 지금까지의 진행 위치를 남긴다
    _persistProgress();

    _shortFocus.unfocus();
    setState(() {
      _showList = true;
      _lastScrolledIndex = -1;
      _extentCache.clear(); // 글이 바뀌면 문장 높이 캐시도 무효
      // 단문은 일회성이므로 재생을 시작하면 칸을 비운다.
      // 안 비우면 다음에 셀을 재생하려 할 때 계속 가로챈다.
      if (short.isNotEmpty) _shortController.clear();
    });
    _jumpToCurrent();
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
    unawaited(_refreshMade());
  }

  /// 뒤로가기는 입력 화면으로 돌아가기만 할 뿐, 재생 중인 소리는 멈추지 않는다.
  void _back() {
    _persistProgress();
    if (mounted) setState(() {
      _showList = false;
    });
    unawaited(_refreshMade());
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
    // 시트가 떠 있는 동안 보여줄 값이라 열 때마다 다시 잰다
    NarrationEngine.voiceBytes().then((b) {
      if (mounted) setState(() => _voiceBytes = b);
    });
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
                20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 48),
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
                  style: const TextStyle(fontSize: 15, color: Colors.white),
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
                  style: const TextStyle(fontSize: 15, color: Colors.white),
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
                const SizedBox(height: 10),
                Container(height: 2, color: kLine),
                const SizedBox(height: 16),
                // 둘 다 짧아서 나란히 놓아도 넉넉하다
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _voiceRow(setSheet)),
                    const SizedBox(width: 18),
                    Expanded(child: _updateRow(setSheet)),
                  ],
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
          padding: const EdgeInsets.fromLTRB(_pagePad, 8, _pagePad, 6),
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
              if (_showList && _engine.items.isNotEmpty) ...[
                // 타임라인. 목록 카드의 띠와 같은 얼굴이되, 여기서는 눌러서
                // 그 자리로 갈 수 있다.
                MadeStrip(
                  flags: [
                    for (final it in _engine.items) it.filePath != null,
                  ],
                  touchHeight: 28,
                  // 쓰는 동안에는 손가락이 가리키는 자리를 보여 준다
                  current: _scrubTo ?? _engine.currentIndex,
                  onSeek: _scrub,
                  onTouch: (down) {
                    if (_scrubTouching == down) return;
                    setState(() => _scrubTouching = down);
                  },
                ),
                const SizedBox(height: 4),
              ],
              _controls(),
              const SizedBox(height: 6),
              Text(
                _bottomLine,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
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

  /// 화면 맨 아래 한 줄.
  ///
  /// 그냥 '재생 중' 이라고 적어 봐야 화면을 보면 아는 것이라 알려 주는 게
  /// 없다. 대신 지금 읽고 있는 글이 무엇인지를 보여 준다. 그 밖의 상태
  /// (준비 중·정지·다 읽음)와 오류는 알려 줄 게 있으므로 그대로 보여 준다.
  String get _bottomLine {
    final err = _engine.error;
    if (err != null) return err;
    final status = _engine.status;
    if (!status.startsWith('재생 중')) return status;
    return _playingTitle() ?? status;
  }

  /// 지금 읽고 있는 글의 이름. 파일이면 파일 이름, 아니면 글의 앞부분.
  /// 스무 자를 넘으면 줄인다.
  String? _playingTitle() {
    const limit = 20;
    String cut(String s) {
      final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty) return t;
      return t.characters.length > limit
          ? '${t.characters.take(limit)}…'
          : t;
    }

    final id = _engine.sourceId;
    for (final s in _sources) {
      if (s.id == id) return cut(s.label);
    }
    // 목록에 없는 글 — 인풋박스로 바로 읽는 단문
    final items = _engine.items;
    if (items.isNotEmpty) return cut(items.first.text);
    return null;
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

  /// 두 화면의 머리글.
  ///
  /// 왼쪽 자리(이름표 또는 뒤로), 가운데(진행 화면에서만), 오른쪽 설정.
  /// 한 함수로 묶어 둬야 두 화면의 설정 단추가 같은 자리에 선다 — 따로
  /// 짜 두었더니 가로로 8dp, 세로로도 어긋나 있었다.
  Widget _header() {
    return SizedBox(
      height: _headerHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_showList)
            // 뒤로 — 화면 왼쪽 끝에 붙는다 (아래 카드의 왼쪽 선과 나란히)
            _pixelTap(
              onTap: _back,
              padding: _headerLeftPad,
              child: const PixelIcon(kGlyphBack, cell: 4, color: kYellow),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '22',
                        style: displayStyle(
                            size: 24,
                            color: Colors.white,
                            weight: FontWeight.w700)),
                    TextSpan(
                        text: 'SUTO-A',
                        style: displayStyle(
                            size: 24, color: kYellow, weight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(height: 2),
                const Text('Supertonic 3 · 내 폰에서 바로 만드는 음성',
                    style: TextStyle(fontSize: 13, color: kMuted)),
              ],
            ),
          if (_showList)
            Expanded(child: _headerStatus())
          else
            const Spacer(),
          if (!_showList && _pickingFile)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child:
                  Text('여는 중', style: displayStyle(size: 12, color: kSlate)),
            ),
          // 설정 — 화면 오른쪽 끝에 붙는다
          _pixelTap(
            onTap: _openSettings,
            padding: _headerRightPad,
            child: const PixelIcon(kGlyphSettings, cell: 4, color: kYellow),
          ),
        ],
      ),
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
                fill: kSlate,
                cell: 4,
                size: const Size(88, 74),
                onPressed: _pickingFile ? null : _pickFile,
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('읽어줄 글을 추가하세요',
              style: TextStyle(fontSize: 14, color: kMuted)),
        ],
      ),
    );
  }

  /// 픽셀 그림 하나만 담은 네모 버튼.
  ///
  /// 붙여넣기와 문서는 나란히 놓이는 짝이라 같은 색을 쓴다. 전에는 문서만
  /// 어두운 올리브였는데, 옆의 밝은 색과 견줘 꺼진 버튼처럼 보였다.
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
          // 위아래는 픽셀 눈금(4dp)의 네 배. 글꼴이 두꺼워지면서 10dp 로는
          // 글이 카드에 눌린 듯 보였다.
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
          // 아직 고르지 않은 글은 한 번 눌러 고르고, 이미 고른 글(노란 카드)을
          // 다시 누르면 바로 그 글로 들어간다 — 아래 버튼까지 갈 필요가 없다.
          onTap: () {
            if (s.id == _selectedId) {
              _start(ignoreShort: true);
            } else {
              setState(() => _selectedId = s.id);
            }
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 붙여넣기 그림이 파일 그림보다 넓다. 넓은 쪽에 맞춰 자리를
              // 잡고 가운데에 세워야 두 카드의 글이 같은 자리에서 시작한다.
              Padding(
                padding: const EdgeInsets.only(top: _iconTop),
                child: SizedBox(
                  width: _sourceIconWidth,
                  child: Center(
                    child: PixelIcon(isFile ? kGlyphFile : kGlyphPaste,
                        cell: _iconCell, color: skin.ink),
                  ),
                ),
              ),
              const SizedBox(width: _iconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      byWord(s.label),
                      maxLines: 2, // 붙여넣기는 앞 두 줄, 파일은 파일명
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        color: skin.ink,
                      ),
                    ),
                    if (_made[s.id]?.isNotEmpty ?? false) ...[
                      const SizedBox(height: 8),
                      MadeStrip(
                        flags: _made[s.id]!,
                        // 고른 카드는 바탕이 노랑이라 같은 노랑이 묻힌다
                        on: selected ? kMadeOnYellow : kYellow,
                      ),
                    ],
                  ],
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
                      left: _iconGap, right: 4, top: _iconTop, bottom: 14),
                  child: PixelIcon(kGlyphCross,
                      cell: _iconCell,
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
              style: const TextStyle(fontSize: 15, color: Colors.white),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: InputBorder.none,
                hintText: '짧은 문장 바로 재생',
                hintStyle: TextStyle(fontSize: 15, color: kOnSteel),
              ),
            ),
          ),
        ),
        if (_sources.isNotEmpty) ...[
          const SizedBox(width: 8),
          _glyphButton(
            glyph: kGlyphPaste,
            fill: kSlate,
            cell: _iconCell,
            size: const Size(46, 46),
            onPressed: _pasteFromClipboard,
          ),
          const SizedBox(width: 8),
          _glyphButton(
            glyph: kGlyphFile,
            fill: kSlate,
            cell: _iconCell,
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
      fill: kBoard,
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
    final icon = PixelIcon(glyph, cell: _iconCell, color: ink);
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
      return NotificationListener<ScrollNotification>(
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
          // 눌러서 옮겨 온 자리가 아직 안 만들어졌으면, 앞의 것이 끝나기를
          // 기다리는 동안에도 만드는 중과 같은 얼굴로 세운다. 그러지 않으면
          // 눌러도 아무 일이 없는 것처럼 보인다.
          final waiting = i == _engine.currentIndex && _engine.isWaitingHere;
          final shown = waiting ? SentenceStatus.synthesizing : it.status;
          // 카드 색이 곧 상태다 — 어두운 데서 시작해 밝아졌다가 다시 가라앉는다
          final skin = skinFor(shown);

          return Padding(
            padding: const EdgeInsets.only(bottom: _itemGap),
            // 문장을 누르면 그 지점부터 읽고, 뒤 문장들을 이어서 합성한다
            child: PixelCard(
              fill: skin.fill,
              padding: const EdgeInsets.symmetric(
                  horizontal: _itemSidePadding, vertical: _itemVerticalPadding / 2),
              onTap: () {
                // 목록을 세우려고 짚은 손짓이면 읽는 자리를 옮기지 않는다
                final moved = _listMovedAt;
                if (moved != null &&
                    DateTime.now().difference(moved) < _tapDeadZone) {
                  return;
                }
                _lastScrolledIndex = i;
                _engine.seekToUnit(i);
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: StatusIcon(shown,
                        color: skin.ink, cell: _iconCell),
                  ),
                  const SizedBox(width: _iconGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          byWord(it.text), // 줄임 없이 전체를 보여준다
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

      return _controlBox(
        Row(
          children: [
            _wordAction(
              label: !_ready ? 'LOADING' : (hasShort ? 'SAY' : 'PLAY'),
              weight: FontWeight.w700,
              onTap: canStart ? _start : null,
            ),
            const Spacer(),
          ],
        ),
      );
    }

    // PAUSE 와 STOP 이 같은 크기라 밑선만 맞추면 윗선도 함께 선다.
    return _controlBox(
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          _wordAction(
            label: _engine.isPlaying ? 'PAUSE' : 'PLAY',
            weight: FontWeight.w700,
            onTap: _togglePause,
          ),
          const Spacer(),
          _wordAction(label: 'STOP', onTap: _stop),
        ],
      ),
    );
  }

  /// 아래 단추가 서는 판. 두 화면이 같은 얼굴을 쓴다.
  /// 진행 화면 맨 윗줄(대시보드)과 같은 색·같은 픽셀 카드다.
  ///
  /// 얼굴은 이 판의 **바닥에 발을 맞추고** 위로 솟는다. 판보다 크므로
  /// 위쪽 목록을 가리는데, 그러라고 맨 나중에 그린다.
  Widget _controlBox(Widget child) {
    final face = _faceAsset;
    return Stack(
      // 판 밖으로 솟는 부분이 잘리지 않아야 한다
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        PixelCard(
          fill: kBoard,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: child,
        ),
        if (face != null)
          Positioned(
            bottom: 0,
            child: IgnorePointer(
              // 타임라인을 만지는 동안에는 옅어져 뒤가 비친다
              child: AnimatedOpacity(
                opacity: _scrubTouching || _shortFocused ? 0.3 : 1,
                duration: const Duration(milliseconds: 120),
                child: Image.asset(
                  face,
                  width: _faceWidth,
                  // 픽셀 그림이라 매끄럽게 늘이면 뭉갠다
                  filterQuality: FilterQuality.none,
                  isAntiAlias: false,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 테두리도 배경도 없이 글자만 놓는 버튼.
  ///
  /// 흰 판 위에 서므로 글자는 검정이다. 누를 수 없을 때는 판에
  /// 묻히도록 흐려 둔다.
  Widget _wordAction({
    required String label,
    required VoidCallback? onTap,
    double size = 15,
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
            color: onTap == null
                ? kOnLight.withValues(alpha: 0.3)
                : kOnLight,
            weight: weight,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: kOnSteel, fontSize: 15),
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
    // 두 줄 사이 빈틈은 슬라이더가 손가락 닿는 최소 높이(48dp)를 차지하면서
    // 생기는 위아래 여백이다. 줄 높이를 여기서 정해 그 빈틈을 조절한다.
    // 30 까지 줄여 봤으나 답답해서 원래 높이인 48 로 되돌렸다.
    return SizedBox(
      height: 48,
      child: Row(
      children: [
        SizedBox(
            width: 40,
            child: Text(label,
                style: const TextStyle(fontSize: 15, color: Colors.white))),
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
      ),
    );
  }
}
