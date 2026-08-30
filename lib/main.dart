import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:suto_a/hangul.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/model_store.dart';
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

  /// 문장 카드 오른쪽 곁차림(케밥)이 차지하는 폭.
  /// 점 셋(눈금 2 → 2dp)에 좌우 손짓 자리를 더한 값이다.
  /// 본문 폭을 잴 때도 이만큼 빼야 줄 수가 맞는다.
  static const _kebabWidth = _iconGap + 2 + _itemSidePadding;

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
    // 표시어(Panchang)는 네 벌이 다 들어 있어 굵기를 골라 쓸 수 있다
    fontWeight: FontWeight.w600,
    color: kOnLight,
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

  /// 입력칸 한 줄의 키. 글자 높이에 따라 흔들리지 않게 못 박아 둔다.
  static const _inputRowHeight = 50.0;

  /// 우리가 스스로 목록을 옮기는 중인지.
  ///
  /// 이 자리가 없으면 자동 스크롤이 낸 알림까지 '손으로 굴렸다' 로 세어,
  /// 문장이 넘어갈 때마다 350ms 동안 탭이 통째로 삼켜진다. 읽는 내내
  /// 목록이 저 혼자 움직이므로, 사실상 문장을 눌러도 반응이 없다.
  bool _autoScrolling = false;

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
  /// 확인을 눌러 앱과 모델 양쪽에 묻고 있는 중
  bool _checking = false;
  /// 지금 깔려 있는 판 번호. 아직 확인을 누르지 않았을 때 이것만 적는다.
  String? _version;
  bool _showList = false; // 입력 화면 ↔ 진행 화면
  bool _pickingFile = false;
  Timer? _pickWatchdog;

  // ---- 음성 모델 (Supertonic 3) ----
  /// 모델이 폰에 온전히 받아져 있는가. 없으면 읽기를 시작할 수 없다.
  bool _modelReady = false;
  /// 설정에서 확인을 눌렀을 때의 결과. 아직 안 물어봤으면 null.
  ModelStatus? _model;
  DownloadProgress? _modelDownloading;
  CancelToken? _modelCancel;
  String? _modelError;
  /// 모델 안내 시트를 다시 그리는 손잡이. 시트는 앱 화면과 따로 떠 있어서
  /// setState 만으로는 다시 그려지지 않는다. 시트가 떠 있는 동안만 찬다.
  void Function()? _modelRedraw;

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

  /// 얼굴을 누르고 있는 동안. 손을 뗄 때까지 옅어진다.
  bool _facePressed = false;

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

  /// 화면 아래에 서는 캐릭터의 크기.
  ///
  /// **잘라내지 않은 판**(assets/char/full)을 쓴다. 밑그림은 모두 같은
  /// 캔버스(3072 정사각형)에 그려져 있고 안쪽 여백만 다르므로, 그
  /// 캔버스째로 놓으면 캐릭터끼리 크기가 저절로 맞는다. 손잡이도 하나면
  /// 된다 — 캔버스가 정사각형이라 이 값이 곧 폭이자 키다.
  ///
  /// 잘라낸 판은 설정·REMAKE 의 얼굴 고르개가 쓴다. 거기서는 얼굴 사이
  /// 빈틈을 고르게 맞춰야 해서 보이는 폭이 곧 그림의 폭이어야 한다.
  /// 두 자리의 사정이 서로 다르다.
  static const _faceCanvas = 144.0;

  /// 캐릭터 오른쪽에 손짓만 받는 자리를 더 낸다.
  ///
  /// 그림이 캔버스 안에서 왼쪽에 치우쳐 있어, 보이는 것만큼만 받으면
  /// 누를 자리가 좁다. PLAY 는 맨 오른쪽에 서 있어 겹치지 않는다.
  ///
  /// 다만 **화면의 왼쪽 절반을 넘지 않는다.** 얼굴은 화면 왼쪽 6dp 에서
  /// 시작하므로(바깥 여백 16 + 왼쪽으로 내보낸 -10), 30 을 더하면
  /// 오른쪽 끝이 6 + 144 + 30 = 180dp — 360dp 화면의 딱 절반이다.
  static const _faceTapExtra = 30.0;

  /// 화면 바깥 여백 (Column 의 좌우 안쪽 여백)
  static const _pagePad = 16.0;

  /// 화면 아래에 설 얼굴.
  ///
  /// 지금 들리는 음성을 만든 목소리를 따른다 — 설정을 바꿔도 이미 만들어
  /// 둔 것은 그대로 쓰므로, 설정만 보면 들리는 것과 어긋난다.
  /// 아직 아무것도 재생하지 않았으면 설정의 목소리를 보여 준다.
  /// [pressed] 면 누른 자세 그림을 가리킨다.
  ///
  /// 누름 그림은 폭이 원본과 같고 키만 낮다(225x330 → 225x210). 발을
  /// 바닥에 붙여 두므로, 옅게 만드는 대신 이 그림으로 갈아 끼우면
  /// 웅크리는 모습이 된다.
  String? _faceAsset({bool pressed = false}) {
    final name = _voiceFaces[_engine.playingVoice ?? _settings.voice];
    if (name == null) return null;
    return 'assets/char/full/$name${pressed ? '_press' : ''}.png';
  }

  /// 목소리마다 이름 하나. 얼굴 아래에 표시어(Panchang)로 적히므로
  /// 넉 자 안팎의 짧은 이름으로 골랐다 — 길면 줄이 흔들린다.
  static const _voiceNames = {
    'M1': 'LEO', 'M2': 'MAX', 'M3': 'NOAH', 'M4': 'ELI', 'M5': 'OWEN',
    'F1': 'MIA', 'F2': 'ZOE', 'F3': 'LILY', 'F4': 'EVA', 'F5': 'RUBY',
  };

  /// 목소리 고르개가 쓰는 값들.
  ///
  /// 얼굴은 그림마다 세로/가로 비가 달라(0.95~1.47) 폭으로 맞추면 키가
  /// 들쭉날쭉해진다. 고르개에서는 **키를 맞추고** 폭은 그림이 정한다.
  static const _pickFace = 66.0; // 얼굴 키
  static const _pickParen = 74.0; // 괄호 키

  /// 이웃한 두 얼굴 사이에 두고 싶은 빈틈.
  static const _pickGapEven = 17.5;

  /// REMAKE 시트가 만지는 임시 설정. 떠 있는 동안만 있고, 전역 설정을
  /// 건드리지 않는다. 시트가 닫히면 비운다.
  Settings? _draft;

  /// 지금 시트가 다루는 설정 — 평소엔 전역, REMAKE 때는 임시본이다.
  Settings get _sheet => _draft ?? _settings;

  /// 얼굴마다 세로/가로 비. 그림이 바뀌어도 따라가도록 파일에서 직접 잰다
  /// — 값을 코드에 박아 두면 그림을 갈 때마다 소리 없이 어긋난다.
  final Map<String, double> _faceRatio = {};

  Future<void> _measureFaces() async {
    for (final v in Settings.voices) {
      final name = _voiceFaces[v];
      if (name == null) continue;
      try {
        final done = Completer<ui.Image>();
        final stream =
            AssetImage('assets/char/$name.png').resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener((info, _) {
          stream.removeListener(listener);
          if (!done.isCompleted) done.complete(info.image);
        }, onError: (e, _) {
          stream.removeListener(listener);
          if (!done.isCompleted) done.completeError(e);
        });
        stream.addListener(listener);
        final img = await done.future;
        _faceRatio[v] = img.height / img.width;
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  /// 얼굴 사이 빈틈을 눈에 고르게 만드는 자리표.
  ///
  /// 캐러셀의 칸 폭은 하나로 고정인데 얼굴 폭은 45~70dp 로 제각각이다
  /// (아프로·긴머리는 넓고 짧은머리는 좁다). 칸 가운데에 그대로 세우면
  /// 이웃 사이 빈틈이 4dp 에서 22dp 까지 벌어진다.
  ///
  /// 그래서 얼굴을 칸 가운데가 아니라 조금씩 어긋난 자리에 세운다 —
  /// 좁은 얼굴은 안쪽으로, 넓은 얼굴은 바깥으로. 이웃한 두 얼굴의
  /// 가운데 사이를 늘 `빈틈 + (두 폭의 평균)` 으로 두면 빈틈이 같아진다.
  ///
  /// 칸 폭을 `빈틈 + 평균 폭` 으로 잡으면 열 개를 한 바퀴 돌았을 때
  /// 어긋남의 합이 정확히 0 이 된다 — 끝없이 도는 캐러셀이라 이음매가
  /// 생기지 않아야 한다.
  ({double step, List<double> shift}) _pickLayout() {
    final voices = Settings.voices;
    final w = <double>[];
    for (final v in voices) {
      final r = _faceRatio[v];
      if (r == null || r <= 0) {
        // 아직 재지 못했다 — 고르게 벌려 두고 기다린다
        return (
          step: _pickGapEven + _pickFace,
          shift: List.filled(voices.length, 0),
        );
      }
      w.add(_pickFace / r);
    }
    final mean = w.reduce((a, b) => a + b) / w.length;
    final shift = <double>[0];
    for (var i = 0; i < w.length - 1; i++) {
      shift.add(shift[i] + (w[i] + w[i + 1]) / 2 - mean);
    }
    // 한쪽으로 쏠리지 않게 가운데를 0 으로 맞춘다
    final centre = shift.reduce((a, b) => a + b) / shift.length;
    return (
      step: _pickGapEven + mean,
      shift: [for (final v in shift) v - centre],
    );
  }

  /// 괄호 사이. 걸음보다 넓어 이웃 얼굴에 걸쳐 얹히지만, 가장 넓은 얼굴
  /// (MIA, 70dp)도 넉넉히 감싸려면 이만큼은 벌어져야 한다.
  static const _pickParenGap = 78.0;

  /// 캐러셀이 시작하는 자리. 열의 배수라 나머지가 곧 목소리 번호가 된다.
  static const _pickLoop = 5000;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _shortFocus.addListener(_onShortFocusChanged);
    unawaited(_measureFaces());
    _engine.onSentenceChanged = _onSentenceChanged;
    _playback.setMethodCallHandler(_onPlaybackCall);
    WidgetsBinding.instance.addObserver(this);
    _boot();
    _initShareIntent();
    _checkUpdateOnLaunch();
  }

  /// 키패드가 올라와 있는지. 오르내림이 바뀌는 순간만 보려고 들고 있다.
  bool _keyboardUp = false;

  /// 키패드를 내리면(뒤로가기든 내리기든) 인풋칸의 포커스도 함께 뗀다.
  ///
  /// 안 그러면 키패드는 사라졌는데 커서만 남아 깜박이고, 얼굴도 옅어진
  /// 채로 있는다. 키패드가 올라오는 중에도 이 알림이 오므로 **오르내림이
  /// 바뀌는 순간**만 골라 본다.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final up = View.of(context).viewInsets.bottom > 0;
      if (up == _keyboardUp) return;
      _keyboardUp = up;
      if (!up && _shortFocus.hasFocus) _shortFocus.unfocus();
    });
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
    // 언어는 고르지 않는다 — 늘 글을 보고 자동으로 가린다.
    _settings.lang = 'auto';
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
        liveIds: _sources.map((s) => s.id).toList(),
      );
      if (mounted) await _refreshMade();
    }());
    // 모델을 읽는 동안에는 화면이 그려지지 않는다. 첫 그림이 나온 뒤에
    // 시작해, 아이콘만 보이는 시간을 줄인다.
    await WidgetsBinding.instance.endOfFrame;

    // 모델은 앱과 따로 산다. 받아 둔 것이 없으면 엔진을 세울 수 없으니,
    // 먼저 받자고 청한다.
    if (!await modelInstalled()) {
      if (!mounted) return;
      setState(() => _modelReady = false);
      _openModelSheet();
      return;
    }
    if (mounted) setState(() => _modelReady = true);

    await _startEngine();
  }

  /// 모델을 다 갖춘 뒤 엔진을 세운다.
  Future<void> _startEngine() async {
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
    // 설정을 열었을 때 아직 확인을 누르지 않았어도 지금 판 번호는 보여야 한다
    final v = await currentVersion();
    if (mounted) setState(() => _version = v);

    final status = await fetchStatus();
    if (!mounted) return;
    setState(() => _update = status);
    if (status is UpdateAvailable && !_updateToastShown) {
      _updateToastShown = true;
      _showToast('새 버전 v${status.latest} 이 있어요 — 설정에서 받으세요');
    }
  }

  // --------------------------------------------------------- 음성 모델 받기

  /// 모델을 받는다. 시트 안에서도, 켤 때 뜨는 안내에서도 이 하나를 쓴다.
  ///
  /// [redraw] 는 시트와 앱 화면을 함께 다시 그리는 손잡이다.
  Future<void> _runModelDownload(
      ModelManifest remote, void Function() redraw) async {
    final cancel = CancelToken();
    _modelCancel = cancel;
    _modelError = null;
    _modelDownloading = DownloadProgress(0, remote.totalBytes);
    redraw();

    try {
      await downloadModel(
        remote,
        cancel: cancel,
        onProgress: (p) {
          // 초당 수백 번 온다. 눈에 보일 만큼 나아갔을 때만 다시 그린다.
          final before = _modelDownloading;
          if (before == null) return;
          final step = p.total > 0 ? p.total ~/ 200 : 1 << 20;
          if (p.received - before.received < step && p.received < p.total) {
            return;
          }
          _modelDownloading = p;
          redraw();
        },
      );
      _modelDownloading = null;
      _model = const ModelUpToDate();
      if (mounted) setState(() => _modelReady = true);
      redraw();

      // 새 모델을 받았으면 지금 물고 있는 엔진은 옛 모델이다. 이미 세워져
      // 있다면 그대로 두고 — 읽는 중일 수 있다 — 다음에 켤 때 새것으로
      // 뜬다. 아직 안 세워졌다면(첫 실행) 지금 세운다.
      if (!_ready) await _startEngine();
      redraw();
    } catch (e) {
      _modelDownloading = null;
      _modelError =
          e is ModelDownloadCancelled ? null : '받지 못했어요 — 다시 눌러 보세요';
      if (e is! ModelDownloadCancelled) logger.w('모델 받기 실패: $e');
      redraw();
    } finally {
      _modelCancel = null;
    }
  }

  /// 모델이 없을 때 켜자마자 뜨는 안내.
  ///
  /// 받기 전에는 아무것도 읽을 수 없으므로 밖을 눌러 닫지 못하게 한다.
  /// 대신 '나중에' 로 물러날 수는 있다 — 지금 받을 형편이 아닐 수 있다.
  /// [update] 가 참이면 이미 받아 둔 것이 있고 새 판이 나온 경우다.
  /// 그때는 밖을 눌러 닫을 수 있다 — 지금 것으로도 읽을 수 있으니까.
  void _openModelSheet({bool update = false}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSteel,
      isScrollControlled: true,
      isDismissible: update,
      enableDrag: update,
      shape: const PixelBorder(unit: 6),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void redraw() {
            setSheet(() {});
            if (mounted) setState(() {});
          }

          _modelRedraw = redraw;

          final downloading = _modelDownloading;
          final remote = switch (_model) {
            ModelMissing(:final remote) => remote,
            ModelOutdated(:final remote) => remote,
            _ => null,
          };

          Future<void> ask() async {
            // 이미 무엇을 받아야 하는지 알고 있으면 곧바로 받는다
            if (remote != null) {
              await _runModelDownload(remote, redraw);
              return;
            }
            _modelError = null;
            _model = null;
            redraw();
            final status = await fetchModelStatus();
            _model = status;
            redraw();
            switch (status) {
              case ModelMissing(:final remote):
              case ModelOutdated(:final remote):
                await _runModelDownload(remote, redraw);
              case ModelUpToDate():
                // 다른 데서 이미 채워졌다
                if (mounted) setState(() => _modelReady = true);
                if (!_ready) await _startEngine();
                redraw();
              case ModelCheckFailed():
                break;
            }
          }

          final body = <Widget>[];
          if (downloading != null) {
            final f = downloading.fraction;
            body.addAll([
              PixelGauge(value: f, cells: 16, height: _sheetGauge),
              const SizedBox(height: 10),
              Text(
                f == null
                    ? _mb(downloading.received)
                    : '${(f * 100).round()}%  '
                        '${_mb(downloading.received)}/${_mb(downloading.total)}',
                style: _sheetValue,
              ),
            ]);
          } else if (_modelReady && !update) {
            body.add(Text('READY', style: _sheetValue.copyWith(color: kYellow)));
          } else if (update && _model is ModelUpToDate) {
            // 새 판을 다 받았다. 지금 물고 있는 엔진은 아직 옛 모델이다.
            body.addAll([
              Text('UPDATED', style: _sheetValue.copyWith(color: kYellow)),
              const SizedBox(height: 6),
              Text('Restart the app to use it.', style: _sheetValue),
            ]);
          } else if (_model == null && _modelError == null) {
            body.add(Text('CHECKING', style: _sheetValue.copyWith(color: kMuted)));
          } else if (remote != null) {
            body.add(Text(
                update
                    ? _mb(remote.totalBytes)
                    : '${_mb(remote.totalBytes)}  ·  ONE TIME',
                style: _sheetValue.copyWith(color: kYellow)));
          } else {
            body.add(
                Text('NO NETWORK', style: _sheetValue.copyWith(color: kMuted)));
          }

          if (_modelError != null) {
            body.addAll([
              const SizedBox(height: 8),
              Text(_modelError!,
                  style: const TextStyle(fontSize: 13, color: kRed)),
            ]);
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 51),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: Container(width: 44, height: 4, color: kMuted)),
                const SizedBox(height: 20),
                Center(
                  child: Text('VOICE MODEL',
                      style: displayStyle(
                          size: 15, color: kYellow, letterSpacing: 2.4)),
                ),
                const SizedBox(height: 18),
                Text(
                  update
                      ? 'A new Supertonic 3 is out.\n'
                          'Voices you already made are kept.'
                      : 'Supertonic 3 runs on your phone.\n'
                          'Download once, then read offline.',
                  style: displayStyle(size: 13, color: kOnSteel, letterSpacing: 1.0)
                      .copyWith(height: 1.7),
                ),
                const SizedBox(height: 18),
                // 내용이 높이를 정하지 않도록 자리부터 잡는다
                SizedBox(
                  height: _sheetBodyLine * 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: body,
                  ),
                ),
                const SizedBox(height: 8),
                if (_modelReady && (!update || _model is ModelUpToDate))
                  _sheetButton(update ? 'CLOSE' : 'START',
                      color: kYellow, onTap: () => Navigator.pop(ctx))
                else if (downloading != null)
                  _sheetButton('STOP',
                      color: kSlate, onTap: () => _modelCancel?.cancel())
                else
                  Row(children: [
                    Expanded(
                      flex: 4,
                      child: _sheetButton('LATER',
                          color: kSlate, onTap: () => Navigator.pop(ctx)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 6,
                      child: _sheetButton('DOWNLOAD',
                          color: kYellow, onTap: () => unawaited(ask())),
                    ),
                  ]),
              ],
            ),
          );
        },
      ),
    ).whenComplete(() {
      _modelRedraw = null;
      if (mounted) setState(() {});
    });

    // 열자마자 얼마나 받아야 하는지부터 알아본다 — 누르기 전에 크기가 보여야
    // 받을지 말지 정할 수 있다.
    unawaited(() async {
      final status = await fetchModelStatus();
      if (!mounted) return;
      _model = status;
      _modelRedraw?.call();
      setState(() {});
    }());
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

      // 음성을 버렸으면 '어디까지 읽었는지' 도 함께 버린다.
      //
      // 그 자리를 가리키던 음성 파일이 이제 없으므로, 남겨 두면 다시 들어갈
      // 때 없는 파일을 물으러 간다. 무엇보다 사람이 지우겠다고 한 것은
      // '만들어둔 것' 전부다 — 절반만 지우면 다음에 열었을 때 중간부터
      // 시작하면서 앞을 다시 만드는, 가장 헷갈리는 꼴이 된다.
      for (final s in _sources) {
        s.lastIndex = 0;
        s.lastFilePath = null;
      }
      await saveSources(_sources);
      // 셀 아래 띠도 다시 잰다 — 이제 만들어둔 것이 하나도 없다
      await _refreshMade();

      final b = await NarrationEngine.voiceBytes();
      _voiceBytes = b;
      refresh(() {});
      if (mounted) setState(() {});
      _showToast('만들어둔 음성과 읽던 자리를 지웠어요');
    }

    return _sheetOption(
      title: 'STORAGE',
      action: (bytes != null && bytes > 0)
          ? _pixelTap(
              onTap: clear,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Text('ERASE', style: _sheetAction),
            )
          : null,
      body: _sheetLine(Text(
        bytes == null
            ? 'MEASURING'
            : '${_mb(bytes)} / ${_mb(NarrationEngine.voiceLimitBytes)}',
        // 넘어도 지우거나 멈추지 않는다. PLAY 와 같은 붉은색으로 여기서도
        // 알리고, 지울지 말지는 사람이 정한다.
        style: bytes == null
            ? _sheetValue.copyWith(color: kMuted)
            : (_engine.voiceFull
                ? _sheetValue.copyWith(color: kRed)
                : _sheetValue),
      )),
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

    /// 한 번 눌러 양쪽을 함께 묻는다 — 앱과 음성 모델.
    ///
    /// 둘은 따로 배포되지만 사람에게는 '새것이 있나' 하나의 물음이다.
    /// 나란히 물어 두 줄로 답한다.
    /// 한 번 눌러 양쪽을 함께 묻는다 — 앱과 음성 모델.
    ///
    /// 앱 쪽 결과만 여기 적는다. 모델은 새것이 있어도 이 좁은 칸에서
    /// 다룰 일이 아니다 — 383MB 를 받을지 정하는 물음이므로, 처음 받을
    /// 때와 똑같은 안내를 띄워 거기서 정하게 한다.
    Future<void> check() async {
      refresh(() {
        _checking = true;
        _update = null;
        _updateError = null;
        _model = null;
        _modelError = null;
      });
      final app = fetchStatus();
      final model = fetchModelStatus();
      _update = await app;
      final m = await model;
      _model = m;
      _checking = false;
      redraw();

      if (m is ModelOutdated) {
        if (mounted) _openModelSheet(update: true);
      } else if (m is ModelMissing) {
        if (mounted) _openModelSheet();
      }
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

    final downloading = _downloading;
    final downloaded = _downloaded;
    final modelDownloading = _modelDownloading;
    final busy = downloading != null || modelDownloading != null;

    // 받는 중에는 '중지' 가 '확인' 자리를 대신한다
    final Widget? action = busy
        ? _pixelTap(
            onTap: () => downloading != null
                ? _downloadCancel?.cancel()
                : _modelCancel?.cancel(),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Text('STOP', style: _sheetAction),
          )
        : (downloaded == null
            ? _pixelTap(
                onTap: check,
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Text('CHECK', style: _sheetAction),
              )
            : null);

    final rows = <Widget>[];

    if (busy) {
      final p = downloading ?? modelDownloading!;
      final f = p.fraction;
      rows.addAll([
        // 게이지의 한가운데를 왼쪽 칸 숫자의 한가운데에 맞춘다.
        const SizedBox(height: (_sheetBodyLine - _sheetGauge) / 2),
        PixelGauge(value: f, cells: 12, height: _sheetGauge),
        const SizedBox(height: 2),
        Text(
          f == null
              ? _mb(p.received)
              : '${(f * 100).round()}%  ${_mb(p.received)}/${_mb(p.total)}',
          style: _sheetValue,
        ),
      ]);
    } else {
      // 모델은 여기 적지 않는다 — 새것이 있으면 안내가 따로 뜬다.
      rows.add(_sheetLine(_appStateText()));

      final buttons = <Widget>[];
      final status = _update;

      if (downloaded != null) {
        buttons.add(_sheetTextButton(
          'INSTALL',
          onTap: () => installApk(downloaded).catchError((e) {
            _updateError = '설치 화면을 열지 못했어요';
            logger.w('설치 실패: $e');
            redraw();
          }),
        ));
      } else if (status is UpdateAvailable) {
        buttons.add(_sheetTextButton(
          status.apkUrl == null ? 'RELEASES' : 'GET APP',
          onTap: () => unawaited(download(status)),
        ));
      } else if (status is UpdateCheckFailed) {
        buttons.add(_sheetTextButton('RELEASES', onTap: openReleasesPage));
      }

      if (buttons.isNotEmpty) {
        rows.addAll([
          const SizedBox(height: 8),
          Row(children: [
            for (final b in buttons) ...[
              b,
              const SizedBox(width: 16),
            ],
          ]),
        ]);
      }
    }

    final err = _updateError ?? _modelError;
    if (err != null) {
      rows.addAll([
        const SizedBox(height: 6),
        Text(err, style: const TextStyle(fontSize: 13, color: kRed)),
      ]);
    }

    return _sheetOption(
      title: 'UPDATE',
      action: action,
      lines: 4,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  /// 앱 쪽 한 줄
  Widget _appStateText() {
    if (_checking) {
      return Text('CHECKING', style: _sheetValue.copyWith(color: kMuted));
    }
    return switch (_update) {
      UpToDate(:final current) =>
        Text('UP TO DATE · v $current', style: _sheetValue),
      UpdateAvailable(:final latest, :final bytes) => Text(
          'v $latest${bytes > 0 ? '  ·  ${_mb(bytes)}' : ''}',
          style: _sheetValue.copyWith(color: kYellow)),
      UpdateCheckFailed() =>
        Text('NO NETWORK', style: _sheetValue.copyWith(color: kMuted)),
      // 아직 안 물어봤다 — 지금 깔린 버전만 조용히 적는다
      null => Text('v ${_version ?? ''}', style: _sheetValue),
    };
  }

  /// 칸 안에 서는 글자 단추 — 노란 표시어 한 마디
  Widget _sheetTextButton(String label, {required VoidCallback onTap}) =>
      _pixelTap(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Text(label,
            style: displayStyle(size: 13, color: kYellow, letterSpacing: 1.4)),
      );

  /// 설정 시트 아래 두 칸이 같은 결로 보이게 묶어 둔 글자 모양
  /// 아래 두 칸의 제목·곁단추·값. 셋 다 표시어(Panchang)로 적는다.
  /// 위쪽 SPEED·QUALITY 보다 한 급 작아, 눈이 먼저 위로 간다.
  static final _sheetTitle =
      displayStyle(size: 12, color: kYellow, letterSpacing: 1.4);
  static final _sheetAction =
      displayStyle(size: 11, color: kSlate, letterSpacing: 1.2);
  static final _sheetValue =
      displayStyle(size: 13, color: kOnSteel, letterSpacing: 1.2);


  /// 설정 시트 두 칸의 '첫 줄' 높이.
  ///
  /// 왼쪽 칸에는 저장한 용량 숫자가, 오른쪽 칸에는 게이지나 안내 문구가
  /// 온다. 생김새가 달라도 한 줄로 나란히 보이도록 높이를 못 박고
  /// 가운데에 세운다.
  static const _sheetBodyLine = 20.0;

  /// 그 줄에 쓰는 게이지의 높이
  static const _sheetGauge = 10.0;

  /// 설정 시트 아래쪽의 옵션 한 칸 — 제목·곁단추가 한 줄, 그 아래가 내용.
  ///
  /// 내용 자리를 [lines] 줄로 **먼저 못 박고** 거기에 내용을 넣는다.
  /// 내용이 높이를 정하게 두면 상태가 바뀔 때마다 시트가 출렁이고,
  /// 눌러야 할 것이 자꾸 움직인다.
  ///
  /// 그러므로 자리는 **가장 키가 큰 상태에 맞춰** 잡아야 한다. 업데이트
  /// 칸이 가장 크게 자라는 때는 받을 것이 있고 오류까지 겹칠 때다:
  /// 버전 줄 20 + 사이 10 + 단추 24 + 사이 8 + 오류 17 = 79dp.
  /// 네 줄(80dp)이면 그것까지 받는다. 평소에는 그만큼 비어 있다.
  ///
  /// 옵션이 더 늘어도 이 틀에 한 줄 얹으면 된다.
  Widget _sheetOption({
    required String title,
    required Widget body,
    Widget? action,
    double lines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title, style: _sheetTitle),
            const Spacer(),
            if (action != null) action,
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: _sheetBodyLine * lines,
          width: double.infinity,
          child: Align(alignment: Alignment.topLeft, child: body),
        ),
      ],
    );
  }

  /// 첫 줄에 놓는다 — 높이를 고정하고 세로 가운데에 세운다
  static Widget _sheetLine(Widget child) => SizedBox(
        height: _sheetBodyLine,
        child: Align(alignment: Alignment.centerLeft, child: child),
      );

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
    // 스크롤은 다음 프레임에 맡긴다. 이 알림은 재생기·합성기 어디서든
    // 날아와 화면을 다시 짜는 중간에 떨어질 수 있는데, 그때 목록을
    // 건드리면 이미 트리에서 빠진 스크롤뷰를 더듬는다.
    _scheduleAutoScroll();
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
    // 오른쪽 케밥이 차지하는 폭도 빼야 실제로 그려지는 줄 수와 맞는다
    final textWidth = (listWidth -
            _itemSidePadding -
            _iconWidth -
            _iconGap -
            _kebabWidth)
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
  /// 다음 프레임이 끝난 뒤에 자리를 옮긴다.
  ///
  /// 엔진의 알림은 프레임 중간에도 떨어진다. 그 자리에서 목록을 옮기면
  /// 스크롤뷰가 트리에서 빠지는 중일 때 이미 없는 것을 더듬는다:
  ///
  ///   findRenderObject() … _ElementLifecycle.inactive
  ///   ScrollableState.setIgnorePointer ← ScrollPosition.beginActivity
  ///   ← animateTo ← _autoScroll ← _onEngineChanged
  ///
  /// 겹쳐 부르는 것은 표시만 남기고 한 번만 돌린다.
  bool _scrollPending = false;

  void _scheduleAutoScroll() {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (mounted) _autoScroll();
    });
  }

  void _autoScroll({bool animate = true}) {
    if (!mounted || !_showList || _userScrolling) return;
    if (!_listController.hasClients) return;
    final i = _engine.currentIndex;
    if (i < 0 || i == _lastScrolledIndex) return;
    if (_cachedWidth <= 0) return;

    // 현재 문장이 화면 위쪽에 오도록 (앞 한 항목만큼 여유를 둔다)
    final target = (_offsetOf(i, _cachedWidth) - _extentFor(i, _cachedWidth))
        .clamp(0.0, _listController.position.maxScrollExtent);
    try {
      if (animate) {
        _autoScrolling = true;
        _listController
            .animateTo(
              target,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
            )
            .whenComplete(() => _autoScrolling = false);
      } else {
        // 들어오자마자는 곧장 앉힌다. 맨 위에서부터 훑어 내려가는 것을
        // 보여 줄 이유가 없다.
        _autoScrolling = true;
        _listController.jumpTo(target);
        _autoScrolling = false;
      }
      _lastScrolledIndex = i;
    } catch (e) {
      // 옮기지 못했으면 표시도 남기지 않는다 — 다음 알림에 다시 해 본다.
      logger.w('목록을 옮기지 못했다: $e');
    }
  }

  /// 굴러가던 자동 스크롤을 그 자리에 세운다.
  ///
  /// [ScrollController.animateTo] 는 350ms 동안 돈다. 그 사이에 목록이
  /// 화면에서 빠지면(뒤로 가기·정지·다른 글 고르기) 애니메이션이 끝나는
  /// 순간 이미 트리에 없는 스크롤뷰를 더듬는다:
  ///
  ///   findRenderObject() called for … _ElementLifecycle.inactive
  ///   ScrollableState.setIgnorePointer ← ScrollPosition.beginActivity
  ///   ← goIdle ← goBallistic ← DrivenScrollActivity._end
  ///
  /// 목록을 치우기 전에 불러 굴러가던 것을 먼저 세운다. 같은 자리로
  /// jumpTo 하면 돌던 애니메이션이 idle 로 갈린다 — 자리는 그대로다.
  void _stopScroll() {
    if (!_listController.hasClients) return;
    _listController.jumpTo(_listController.offset);
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
    // 손으로 굴리는 동안만 찍어 둔다. 자동 스크롤은 세지 않는다 —
    // 세우려고 짚은 손짓만 걸러내자는 장치이기 때문이다.
    if (n is ScrollUpdateNotification && !_autoScrolling) {
      _listMovedAt = DateTime.now();
    }
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
    if (!mounted) return;

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
    _stopScroll();
    if (mounted) setState(() => _showList = false);
    unawaited(_refreshMade());
  }

  /// 뒤로가기는 입력 화면으로 돌아가기만 할 뿐, 재생 중인 소리는 멈추지 않는다.
  void _back() {
    _persistProgress();
    _stopScroll();
    if (mounted) setState(() {
      _showList = false;
    });
    unawaited(_refreshMade());
  }

  Future<void> _togglePause() async {
    // 재생기의 playing 이 아니라 사람의 뜻을 본다. 문장이 넘어가는 틈에는
    // playing 이 false 라, 그걸 보고 고르면 멈추려는 손짓이 도리어
    // 재생을 거는 쪽으로 간다.
    if (_engine.isPaused) {
      await _engine.resume();
    } else {
      await _engine.pause();
    }
  }

  /// 목소리 고르개 — 얼굴을 옆으로 쓸어 고른다.
  ///
  /// [PageView] 라 손을 떼면 한 칸에 딱 맞춰 선다(snap). 가운데 칸이
  /// 고른 목소리이고, 좌우 이웃은 조금 작고 옅게 그려 누가 가운데인지
  /// 눈으로 알 수 있게 했다. 괄호는 자리에 붙박이로 두고 얼굴만 지나간다.
  Widget _voicePicker(PageController page, void Function(VoidCallback) update) {
    final voices = Settings.voices;
    final shift = _pickLayout().shift;
    final n = voices.length;
    // 아직 붙지 않았을 때 기준이 되는 자리 — 지금 고른 목소리다
    final home = _pickLoop + voices.indexOf(_sheet.voice).clamp(0, n - 1);

    /// 지금 몇 번째 칸에 서 있는지 (쓸고 있는 중에는 소수)
    double pageNow() => page.hasClients && page.position.haveDimensions
        ? (page.page ?? home.toDouble())
        : home.toDouble();

    /// 그 자리의 어긋남. 칸과 칸 사이는 이어서 잇는다.
    double shiftAt(double p) {
      final lo = p.floor();
      final t = p - lo;
      return shift[((lo % n) + n) % n] * (1 - t) +
          shift[(((lo + 1) % n) + n) % n] * t;
    }

    // 부모(시트)의 좌우 여백 밖으로 나가 화면 폭을 그대로 쓴다.
    return SizedBox(
      height: _pickParen,
      child: OverflowBox(
        maxWidth: MediaQuery.sizeOf(context).width,
        child: Stack(
        alignment: Alignment.center,
        children: [
          PageView.builder(
            controller: page,
            // 끝을 두지 않는다 — 어느 쪽으로 밀어도 계속 돈다
            itemCount: null,
            padEnds: true,
            onPageChanged: (i) =>
                update(() => _sheet.voice = voices[i % voices.length]),
            itemBuilder: (_, i) => AnimatedBuilder(
              animation: page,
              builder: (_, __) {
                final p = pageNow();
                final away = (p - i).abs().clamp(0.0, 1.0);
                final name = _voiceFaces[voices[i % n]];
                if (name == null) return const SizedBox.shrink();
                return Center(
                  // 칸 가운데가 아니라 빈틈이 고르게 보이는 자리에 세운다.
                  // 거기서 지금 자리의 어긋남만큼 띠 전체를 도로 밀어,
                  // 고른 얼굴이 늘 한가운데(=붙박이 괄호 사이)에 온다.
                  child: Transform.translate(
                    offset: Offset(shift[i % n] - shiftAt(p), 0),
                    // 이웃을 줄여 그리지 않는다. 줄이면 그만큼 빈틈이
                    // 넓어지는데 그 양이 얼굴 폭마다 달라, 애써 고르게
                    // 맞춘 자리가 도로 흐트러진다. 가운데가 누구인지는
                    // 흐리기와 괄호가 이미 말해 준다.
                    child: Opacity(
                      opacity: 1 - 0.55 * away,
                      child: Image.asset(
                        'assets/char/$name.png',
                        height: _pickFace,
                        // 픽셀 그림이라 매끄럽게 줄이면 뭉갠다
                        filterQuality: FilterQuality.none,
                        isAntiAlias: false,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 괄호는 한가운데에 붙박이다. 움직이는 것은 얼굴 띠 쪽이다.
          IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _paren(flip: false),
                const SizedBox(width: _pickParenGap),
                _paren(flip: true),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// 괄호 한 짝. 오른쪽은 같은 밑그림을 좌우로 뒤집어 쓴다.
  Widget _paren({required bool flip}) {
    final icon = PixelIcon(
      kGlyphParen,
      cell: _pickParen / kGlyphParen.height * 2,
      color: kYellow,
    );
    return flip
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scale(-1.0, 1.0),
            child: icon,
          )
        : icon;
  }

  // ---- 설정 시트 ----
  void _openSettings() => _openSheet(title: 'SETTINGS');

  /// 설정 맨 아래 — 이 앱이 기대고 있는 것들. 누르면 바깥 브라우저로 나간다.
  Widget _licenseRow() => _sheetOption(
        title: 'LICENSE',
        action: _pixelTap(
          onTap: () => unawaited(openLicensesPage()),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Text('OPEN', style: _sheetAction),
        ),
        body: _sheetLine(Text('MIT · OPENRAIL-M · OFL', style: _sheetValue)),
      );

  /// REMAKE — 문장 하나를 새 설정으로 다시 만든다.
  void _openRemake(int index) {
    // 지금 설정에서 출발하되, 전역은 건드리지 않는 임시본을 만진다
    _draft = Settings(
      voice: _settings.voice,
      lang: _settings.lang,
      speed: _settings.speed,
      steps: _settings.steps,
    );
    _openSheet(
      title: 'REMAKE',
      onClosed: () => _draft = null,
      footer: (ctx) => Row(
        children: [
          // 두 단추의 너비는 4 : 6
          Expanded(
            flex: 4,
            child: _sheetButton(
              'CANCEL',
              color: kSlate,
              onTap: () => Navigator.pop(ctx),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 6,
            child: _sheetButton(
              'CONFIRM',
              color: kYellow,
              onTap: () {
                final d = _draft;
                Navigator.pop(ctx);
                if (d == null) return;
                unawaited(_engine.remake(index,
                    voice: d.voice, speed: d.speed, steps: d.steps));
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 시트 아래에 서는 단추 하나
  Widget _sheetButton(String label,
      {required Color color, required VoidCallback onTap}) {
    return PixelCard(
      fill: color,
      padding: const EdgeInsets.symmetric(vertical: 14),
      onTap: onTap,
      child: Center(
        child: Text(label,
            style: displayStyle(
                size: 13, color: kOnLight, letterSpacing: 1.6)),
      ),
    );
  }

  void _openSheet({
    required String title,
    Widget Function(BuildContext)? footer,
    VoidCallback? onClosed,
  }) {
    // 시트가 떠 있는 동안 보여줄 값이라 열 때마다 다시 잰다
    NarrationEngine.voiceBytes().then((b) {
      if (mounted) setState(() => _voiceBytes = b);
    });
    // 고르개는 지금 목소리 자리에서 시작한다. 시트가 닫힐 때 버린다.
    // 고르개는 시트 좌우 여백을 넘어 화면 끝까지 펼친다 — 잘리는 자리가
    // 여백 언저리가 아니라 화면 가장자리여야 얼굴이 자연스럽게 걸친다.
    final sheetWidth = MediaQuery.sizeOf(context).width;
    final page = PageController(
      // 캐러셀은 끝없이 돈다. 한참 앞에서 시작해 어느 쪽으로 밀어도
      // 목록이 끊기지 않는다 — 자리 번호를 열로 나눈 나머지가 목소리다.
      initialPage:
          _pickLoop + Settings.voices.indexOf(_sheet.voice).clamp(0, 9),
      viewportFraction: _pickLayout().step / sheetWidth,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSteel,
      isScrollControlled: true,
      shape: const PixelBorder(unit: 6),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void update(VoidCallback change) {
            change();
            _sheet.clamp();
            // 임시본을 만지는 중이면 엔진에도 저장소에도 옮기지 않는다.
            // CONFIRM 을 눌러야 비로소 그 문장 하나에 쓰인다.
            if (_draft == null) {
              _applySettingsToEngine();
              _scheduleSave();
            }
            setSheet(() {});
            if (mounted) setState(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
                20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 51),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(width: 44, height: 4, color: kMuted),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(title,
                      style: displayStyle(
                          size: 15, color: kYellow, letterSpacing: 2.4)),
                ),
                const SizedBox(height: 18),
                _voicePicker(page, update),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    _voiceNames[_sheet.voice] ?? '',
                    style: displayStyle(
                        size: 14, color: Colors.white, letterSpacing: 2.4),
                  ),
                ),
                const SizedBox(height: 18),
                _slider('SPEED', _sheet.speed.toStringAsFixed(2),
                    _sheet.speed, 0.7, 2.0,
                    (v) => update(() => _sheet.speed = v)),
                const SizedBox(height: 14),
                _slider('QUALITY', '${_sheet.steps}',
                    _sheet.steps.toDouble(), 2, 12,
                    (v) => update(() => _sheet.steps = v.round())),
                const SizedBox(height: 18),
                Container(height: 2, color: kLine),
                const SizedBox(height: 16),
                // 둘 다 짧아서 나란히 놓아도 넉넉하다
                if (footer != null)
                  footer(ctx)
                else ...[
                  // 나란히 놓으면 둘 다 폭이 좁아 값이 구겨진다.
                  // 위아래로 두고 각자 한 줄을 온전히 쓴다.
                  _voiceRow(setSheet),
                  const SizedBox(height: 14),
                  _licenseRow(),
                  const SizedBox(height: 14),
                  _updateRow(setSheet),
                ],
              ],
            ),
          );
        },
      ),
    ).whenComplete(() {
      page.dispose();
      onClosed?.call();
      if (mounted) setState(() {});
    });
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
              // 진행 화면에서는 이 여백에서 3dp 를 덜어 문장 목록에 준다.
              // Column 이라 덜어낸 만큼 위의 Expanded 가 늘어날 뿐,
              // 타임라인과 아래 단추는 있던 자리에 그대로 있는다.
              SizedBox(height: _showList ? 7 : 10),
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
                const Text('Supertonic 3 · on-device text to speech',
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
    // PLAYING/PAUSED 도 재생기의 순간 상태가 아니라 사람의 뜻을 따른다.
    // 문장 사이의 틈마다 PLAYING 이 PAUSED 로 깜박이면 안 된다.
    if (_engine.error != null) {
      word = 'ERROR';
    } else if (!_engine.isRunning) {
      word = 'STOPPED';
    } else if (_engine.isPaused) {
      word = 'PAUSED';
    } else {
      word = 'PLAYING';
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
  ///
  /// 안내 문구는 두지 않는다. 빈 칸으로 두면 캐릭터가 그 위에 서 있어도
  /// 글자와 겹쳐 어수선해 보이지 않는다.
  Widget _shortInputRow() {
    return SizedBox(
      height: _inputRowHeight,
      child: Row(
      children: [
        Expanded(
          child: PixelCard(
            fill: kSteel,
            padding: EdgeInsets.zero,
            child: Stack(
              children: [
                TextField(
                  controller: _shortController,
                  focusNode: _shortFocus,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  // 버튼 문구를 바로 바꾸기 위해
                  onChanged: (_) => setState(() {}),
                  cursorColor: kYellow,
                  style: const TextStyle(fontSize: 15, color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    border: InputBorder.none,
                  ),
                ),
                // 평소에는 연필이 칸 뒤에 깔린 밑그림이다 — 누르는 그림이
                // 아니라서 손짓을 그냥 흘려보내고, 칸 아무 데나 누르면
                // 곧바로 입력이 시작된다.
                //
                // 커서가 들어오면 가위표로 바뀌고 그때만 손짓을 받는다.
                // 키패드를 닫을 길이 하나 더 생기는 셈이다.
                Positioned(
                  right: 14,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring: !_shortFocused,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _shortFocus.unfocus,
                      child: Center(
                        // 두 밑그림의 눈금이 달라(가위표는 절반) 보이는
                        // 크기를 맞추려면 눈금도 함께 바꿔야 한다.
                        child: PixelIcon(
                          _shortFocused ? kGlyphCross : kGlyphEdit,
                          // 가위표 밑그림은 눈금이 절반이라 같은 크기로
                          // 보이려면 4 가 되어야 하고, 거기서 2/3 로 줄여
                          // 연필보다 조금 작게 놓는다.
                          cell: _shortFocused ? 8 / 3 : 2,
                          color: kSlate,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 커서가 들어오면 두 단추가 오른쪽으로 밀려나며 접히고, 그 자리를
        // 입력칸이 넘겨받는다. 폭을 0 으로 좁히는 것이라 Expanded 인
        // 입력칸이 저절로 그만큼 늘어난다.
        if (_sources.isNotEmpty)
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.centerRight,
              widthFactor: _shortFocused ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Row(
                children: [
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
              ),
            ),
          ),
      ],
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
            dim: _engine.isPaused || !_engine.isRunning,
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
              // 오른쪽 여백은 케밥이 손짓 받는 자리로 쓴다
              padding: const EdgeInsets.fromLTRB(_itemSidePadding,
                  _itemVerticalPadding / 2, 0, _itemVerticalPadding / 2),
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
                        Text('${i + 1}', style: _numberStyle),
                      ],
                    ),
                  ),
                  // 곁차림(케밥) — 이 문장만 다시 만든다.
                  //
                  // 보이는 것은 왼쪽 상태 그림과 키가 같은 점 셋뿐이지만,
                  // 누르는 자리는 카드 모서리까지 넉넉히 잡는다. 안쪽
                  // 여백을 손짓이 받는 자리로 쓰고, 그만큼 바깥으로
                  // 밀어내 글의 너비는 그대로 둔다.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openRemake(i),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          _iconGap, 3, _itemSidePadding, 10),
                      child: PixelIcon(kGlyphKebab,
                          cell: 2, color: skin.ink.withValues(alpha: 0.55)),
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

  void _setFacePressed(bool down) {
    if (_facePressed == down) return;
    setState(() => _facePressed = down);
  }

  // ---- 하단 버튼 ----
  Widget _controls() {
    if (!_showList) {
      final hasShort = _shortController.text.trim().isNotEmpty;
      // 인풋박스에 글자가 있으면 그것만, 없으면 선택된 셀을 읽는다
      final canStart = _ready && (hasShort || _selectedSource != null);

      // 모델이 없으면 읽을 수가 없다. 멈춰 세우는 대신 받는 자리로 데려간다.
      final needModel = !_modelReady;

      // 단추는 오른쪽. 왼쪽 바닥은 캐릭터가 선다.
      return _controlBox(
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _wordAction(
              label: needModel
                  ? 'GET VOICE'
                  : (!_ready ? 'LOADING' : (hasShort ? 'SAY' : 'PLAY')),
              weight: FontWeight.w700,
              onTap: needModel
                  ? _openModelSheet
                  : (canStart ? _start : null),
            ),
          ],
        ),
      );
    }

    // STOP 은 뺐다. 뒤로가기로 나가면 소리는 그대로 이어지고, 다른 글을
    // 고르면 그때 멎는다 — 굳이 세우는 단추를 둘 이유가 없었다.
    return _controlBox(
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _wordAction(
            label: _engine.isPaused ? 'PLAY' : 'PAUSE',
            weight: FontWeight.w700,
            onTap: _togglePause,
            // 만들어둔 음성이 5GB 를 넘었다는 신호. 저절로 지우지도, 만들기를
            // 멈추지도 않으므로 여기서 알린다 — 설정의 '저장한 용량' 에서
            // 지울 수 있다.
            color: _engine.voiceFull ? kRed : null,
          ),
        ],
      ),
    );
  }

  /// 아래 단추가 서는 판. 두 화면이 같은 얼굴을 쓴다.
  /// 진행 화면 맨 윗줄(대시보드)과 같은 색·같은 픽셀 카드다.
  ///
  /// 얼굴은 이 판의 **왼쪽 바닥에 발을 맞추고** 위로 솟는다. 판보다 크므로
  /// 위쪽 목록을 가리는데, 그러라고 맨 나중에 그린다.
  /// 단추는 오른쪽에 서므로 얼굴과 겹치지 않는다.
  Widget _controlBox(Widget child) {
    // 누를 때·타임라인을 만질 때·인풋칸에 커서가 들어왔을 때 모두
    // 숙인 그림으로 갈아 끼운다. 숙이면 키가 낮아져 인풋칸 아래로
    // 내려가므로, 층을 뒤집거나 잘라낼 일이 없다.
    final pressed = _facePressed || _scrubTouching || _shortFocused;
    final face = _faceAsset(pressed: pressed);
    return Stack(
      // 얼굴이 판 밖으로 솟는 것을 자르지 않는다
      clipBehavior: Clip.none,
      alignment: Alignment.bottomLeft,
      children: [
        PixelCard(
          fill: kBoard,
          // 위아래 0.5dp 씩 — 3배 화면에서 흰 판이 3px 낮아진다
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11.5),
          child: child,
        ),
        if (face != null)
          Positioned(
            bottom: 0,
            // 캔버스째 놓으므로 그림 안쪽에도 여백이 있다. 그만큼 왼쪽으로
            // 더 내보내 화면 가장자리에 붙였다 (14 에서 24dp 왼쪽).
            left: -10,
            // 눌러도 하는 일은 없다. 손끝을 따라 옅어졌다 돌아오는 것이
            // 전부다 — 눌리는 것이라는 표시.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _setFacePressed(true),
              onTapUp: (_) => _setFacePressed(false),
              onTapCancel: () => _setFacePressed(false),
              // 누르는 동안(타임라인을 만질 때도) 옅게 만드는 대신
              // 누른 자세 그림으로 갈아 끼운다.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Image.asset(
                    face,
                    width: _faceCanvas,
                    // 픽셀 그림이라 매끄럽게 늘이면 뭉갠다
                    filterQuality: FilterQuality.none,
                    isAntiAlias: false,
                  ),
                  // 그림은 없고 손짓만 받는 자리
                  const SizedBox(width: _faceTapExtra),
                ],
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
    Color? color,
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
                : (color ?? kOnLight),
            weight: weight,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }


  /// 설정 시트의 손잡이 한 줄.
  ///
  /// 이름과 값을 윗줄에 좌우로 벌려 놓고, 트랙은 그 아래를 가로로 꽉
  /// 채운다. 트랙은 양쪽 모두 노랑이고 손잡이만 그보다 두툼한 네모라,
  /// 어디까지 왔는지가 아니라 **지금 어디에 서 있는지**를 보여 준다.
  Widget _slider(String label, String value, double v, double min, double max,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(label,
                style: displayStyle(
                    size: 12, color: Colors.white, letterSpacing: 1.6)),
            const Spacer(),
            Text(value,
                style: displayStyle(
                    size: 12, color: kYellow, letterSpacing: 1.2)),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: kYellow,
            inactiveTrackColor: kYellow,
            thumbColor: kYellow,
            overlayColor: kYellow.withValues(alpha: 0.14),
            thumbShape: const PixelThumbShape(size: 16),
            trackShape: const RectangularSliderTrackShape(),
            // 트랙이 칸 끝까지 닿도록 기본 여백을 걷어낸다
            padding: EdgeInsets.zero,
          ),
          child: Slider(value: v, min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }

}
