import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/model_store.dart' show onnxDirPath, voiceStylesDirPath;
import 'package:suto_a/sentence_splitter.dart';

/// 문장 하나의 상태
enum SentenceStatus { pending, synthesizing, ready, playing, done, failed }

class SentenceItem {
  SentenceItem(this.index, this.text);

  final int index;
  final String text;

  SentenceStatus status = SentenceStatus.pending;
  String? filePath;

  /// 이 문장의 음성을 어떤 목소리로 만들었는지 (M1…F5).
  /// 설정을 바꿔도 이미 만들어 둔 것은 그대로 쓰므로, 지금 설정과 다를 수 있다.
  /// 파일 이름에서 읽어 오거나 만들 때 적어 둔다. 알 수 없으면 null.
  String? voice;

  /// 손으로 '다시 만들기' 를 이른 문장이면, 그때 고른 설정.
  /// 이 문장 하나에만 쓰고 만들고 나면 비운다 — 전역 설정은 건드리지 않는다.
  String? forceVoice;
  double? forceSpeed;
  int? forceSteps;
}

/// 선행 합성(prefetch) 파이프라인.
///
/// 합성 담당은 항상 "지금 재생 위치"를 기준으로 가장 가까운 미완성 문장을 고른다.
/// 그래서 사용자가 어느 문장으로 건너뛰어도 그 지점부터 곧바로 따라붙고,
/// 대기열 크기가 일정하므로 글이 아무리 길어도 메모리 사용량은 변하지 않는다.
class NarrationEngine extends ChangeNotifier {
  NarrationEngine({this.warmupUnits = 1});

  /// 재생을 시작하기 전에 먼저 만들어 둘 문장 수 (1 = 첫 문장이 준비되면 바로 시작)
  final int warmupUnits;

  /// 재생기에 미리 담아 둘 문장 수.
  ///
  /// 만드는 것은 끝까지 계속하되, **재생기에 담는 것은 앞쪽 몇 개까지만**
  /// 한다. 담은 만큼 재생기가 안에 자리를 들고 있어서, 긴 글을 통째로
  /// 담으면 그만큼 무거워진다. 재생이 나아가면 그때그때 더 담는다.
  static const maxQueueAhead = 30;

  /// 재생 중이라면 앞쪽에 적어도 이만큼은 준비돼 있어야 한다.
  /// 모자란데 만드는 중도 아니면 일꾼이 멎은 것으로 보고 다시 세운다.
  static const minReadyAhead = 5;

  final AudioPlayer player = AudioPlayer();

  TextToSpeech? _tts;
  final Map<String, Style> _styleCache = {};

  List<SentenceItem> _items = [];
  List<SentenceItem> get items => List.unmodifiable(_items);

  // 현재 설정 — 읽는 중에도 바뀔 수 있다
  String _voice = 'M1';
  String _lang = 'ko'; // 실제로 모델에 넘기는 코드
  String _langChoice = 'auto'; // 사용자가 고른 값
  int _steps = 8;
  double _speed = 1.05;

  /// 다른 글로 옮겨갈 때 남겨 둘 음성 파일 수 (현재 문장 + 뒤 9개).
  ///
  /// 44.1kHz 모노 16bit WAV라 한 개가 대략 1MB 안팎이므로,
  /// 글 하나당 10MB 정도를 들고 있는 셈이다.
  /// 만들어둔 음성을 모두 합쳐 이만큼까지만 들고 있는다.
  /// 넘으면 오래전에 넣은 글부터 음성을 버린다 (글 자체는 남는다).
  static const voiceLimitBytes = 5 * 1024 * 1024 * 1024; // 5GB

  /// 지금 읽고 있는 글의 id
  String? _sourceId;
  String? get sourceId => _sourceId;

  /// 글별로 보관해 둔 대기열 — sourceId → (문장 번호 → 음성 파일 경로).

  /// 이미 버려진 엔진인가.
  ///
  /// 엔진의 거의 모든 일은 await 를 건너 뛴 뒤에 화면에 알린다 — 합성,
  /// 재생, 폴더 지우기. 그 사이에 화면이 없어지면 알릴 곳이 사라지는데,
  /// ChangeNotifier 는 그때 예외를 던진다. 버려졌으면 조용히 넘어간다.
  bool _disposed = false;

  int _generation = 0;
  int _currentIndex = -1;
  int _synthesizingIndex = -1;
  int _playlistEnd = 0; // 다음에 재생목록에 넣을 문장 번호
  final List<int> _playlistMap = []; // 재생목록 위치 → 문장 번호
  Directory? _sessionDir;
  bool _running = false;
  bool _stalled = false;

  /// 사용자가 손수 세워 둔 상태인가.
  ///
  /// 세워 둔 채로 자리를 옮기면(타임라인을 만지면) 그 자리에 가서 서 있어야
  /// 한다. 손을 떼자마자 저절로 읽기 시작하면 놀란다. 재생기의 playing 만
  /// 보면 안 된다 — 다음 문장을 만드는 동안에도 잠깐씩 멎기 때문이다.
  bool _userPaused = false;
  bool _pumping = false;

  /// 만들어둔 음성이 [voiceLimitBytes] 를 넘었다.
  ///
  /// **넘어도 아무것도 막지 않고 아무것도 지우지 않는다.** 만들던 것은
  /// 계속 만들고, 쌓아둔 것도 그대로 둔다. PLAY 를 붉게 물들여 알리기만
  /// 하고, 지울지 말지는 사람이 설정에서 정한다.
  bool _voiceFull = false;
  bool get voiceFull => _voiceFull;
  int _madeSinceCheck = 0;
  bool _pumpAgain = false; // 미는 동안 또 밀어 달라는 요청이 왔다

  /// 재생목록 세대.
  ///
  /// 자리를 옮기면 재생목록을 비우고 처음부터 다시 담는다. 그런데 비우기
  /// 직전에 시작된 '한 문장 담기'는 비운 뒤에 끝날 수 있다. 그러면 재생기가
  /// 든 순서와 [_playlistMap]의 문장 번호가 한 칸씩 어긋나, 소리는 다음
  /// 문장인데 화면은 앞 문장에 노랗게 남는다.
  /// 비울 때마다 이 번호를 올려, 옛 세대의 담기는 스스로 물러나게 한다.
  int _playlistGen = 0;

  /// 재생목록을 건드리는 일은 한 번에 하나씩.
  ///
  /// 담는 도중에 비우면 재생기와 [_playlistMap]이 어긋난다. 담기·비우기를
  /// 모두 이 줄에 세워, 하나가 끝난 뒤에 다음이 시작하도록 한다.
  Future<void> _playlistLock = Future<void>.value();

  Future<void> _withPlaylist(Future<void> Function() body) {
    final next = _playlistLock.then((_) => body());
    _playlistLock = next.catchError((_) {});
    return next;
  }
  int _warmupTarget = 0; // 재생 시작 전에 준비해야 할 문장 수
  bool _warmOk = true; // 재생을 시작해도 되는지
  String _status = '';
  String? _error;

  /// 마지막으로 **만들어 낸** 목소리. 되찾아 쓴 것은 세지 않는다.
  ///
  /// 새로 만든 것이든 REMAKE 로 다시 만든 것이든, 기계를 돌려 소리를 뽑은
  /// 마지막 한 번이다. 화면은 이것을 저장해 두었다가 다음에 켤 때 첫
  /// 화면에 그 얼굴을 세운다.
  String? _lastMadeVoice;
  String? get lastMadeVoice => _lastMadeVoice;

  int get currentIndex => _currentIndex;
  int get synthesizingIndex => _synthesizingIndex;
  bool get isRunning => _running;

  /// 손수 세워 두었나 — 사람이 PAUSE 를 눌렀는지.
  ///
  /// **화면은 [isPlaying] 이 아니라 이 값을 봐야 한다.** 재생기의 playing 은
  /// 문장이 넘어가는 틈에도 잠깐씩 false 가 된다(실측 30%). 그 값으로
  /// 단추를 그리면, 듣고 있는 중인데 단추에 PLAY 라고 적혀 있고, 그때 누르면
  /// 멈추는 대신 재생을 한 번 더 걸게 된다 — 그래서 한 번 더 눌러야
  /// 비로소 멈춘다.
  bool get isPaused => _userPaused;
  bool get isStalled => _stalled;
  bool get isPlaying => player.playing;
  /// 재생 중임을 나타내는 상태 문구의 머리.
  ///
  /// 화면이 이 문구로 시작하는지를 보고 상태줄에 글 제목을 대신 띄운다.
  /// 양쪽에 같은 글자를 적어 두면 한쪽만 고쳤을 때 조용히 어긋나므로
  /// 여기 한 곳에 둔다.
  static const statusPlaying = 'Playing';

  String get status => _status;
  String? get error => _error;
  String get lang => _lang;

  int get total => _items.length;
  int get doneCount =>
      _items.where((e) => e.status == SentenceStatus.done).length;
  /// 지금 자리부터 **앞쪽으로** 준비돼 있는 문장 수 — 곧 들을 것들이다.
  ///
  /// 뒤쪽의 준비분까지 세면 안 된다. 디스크에서 되찾은 음성이 글 곳곳에
  /// 흩어져 있으면 그 수가 금세 상한을 넘고, 그러면 합성이 통째로 쉬어
  /// 정작 필요한 문장이 영영 만들어지지 않는다.
  int get readyCount {
    final from = _currentIndex < 0 ? 0 : _currentIndex;
    var n = 0;
    for (var i = from; i < _items.length; i++) {
      if (_items[i].status == SentenceStatus.ready) n++;
    }
    return n;
  }

  /// 현재 문장이 바뀔 때 호출 (알림 문구 갱신용)
  void Function(SentenceItem item)? onSentenceChanged;

  // ---------------------------------------------------------------- 초기화
  /// 앞쪽이 비었는지 이따금 들여다보는 눈.
  Timer? _watchdog;

  /// 재생 중인데 앞쪽 [minReadyAhead] 개가 채워져 있지 않고, 만드는 중도
  /// 아니라면 — 일꾼이 어디선가 멎은 것이다. 곧바로 다시 세운다.
  ///
  /// 일꾼은 한 번 빠져나오면 스스로 돌아오지 않는다. 그동안 재생은 이어져
  /// 준비된 데까지 읽다가 조용히 멈춰 버린다. 그 자리를 여기서 막는다.
  void _kickIfIdle() {
    if (_items.isEmpty || _tts == null) return;
    if (!player.playing) return;
    if (_synthesizingIndex >= 0) return; // 이미 만드는 중이면 그대로 둔다

    final from = _currentIndex < 0 ? 0 : _currentIndex;
    final end = (from + 1 + minReadyAhead).clamp(0, _items.length);
    var missing = false;
    for (var i = from; i < end; i++) {
      if (_items[i].status == SentenceStatus.pending) {
        missing = true;
        break;
      }
    }
    if (!missing) return;

    if (!_running) {
      logger.w('앞쪽이 비어 일꾼을 다시 세운다 (문장 ${from + 1})');
      _running = true;
      unawaited(_worker(_generation));
    }
    unawaited(_pump(_generation));
  }

  Future<void> loadModels() async {
    _setStatus('Starting the voice engine…');
    try {
      _tts = await loadTextToSpeech(await onnxDirPath(), useGpu: false);
      await _style('M1');
    } catch (e, st) {
      // 여기서 넘어지면 화면은 '준비 중...' 에 선 채로 영영 멈춰 있었다.
      // 기다리면 되는 줄 알고 사람이 계속 기다리게 된다. 넘어졌다는 것을
      // 화면에 내놓아야 다시 받아 보든 다시 켜 보든 할 수 있다.
      logger.e('음성 엔진을 세우지 못함', error: e, stackTrace: st);
      _error = 'Could not start the voice engine — $e';
      notifyListeners();
      rethrow;
    }
    _setStatus('Ready');

    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _kickIfIdle());

    player.sequenceStateStream.listen(_onSequenceState);
    player.processingStateStream.listen((s) {
      if (s != ProcessingState.completed) return;
      if (_playlistEnd >= _items.length) {
        _finish();
      } else {
        _stalled = true;
        _setStatus('Making the next sentence…');
      }
    });
  }

  bool get modelsLoaded => _tts != null;

  Future<Style> _style(String voice) async => _styleCache[voice] ??=
      await loadVoiceStyle(['${await voiceStylesDirPath()}/$voice.json']);

  // ------------------------------------------------------------ 설정 변경
  /// 읽는 도중에도 설정을 바꾼다.
  /// 이미 만들어 둔 문장은 그대로 두고, 아직 만들지 않은 문장부터 새 설정이 적용된다.
  int? setParams({String? voice, String? lang, double? speed, int? steps}) {
    if (voice != null) _voice = voice;
    if (speed != null) _speed = speed.clamp(0.7, 2.0);
    if (steps != null) _steps = steps.clamp(2, 12); // 공식 벤치마크가 2단계 기준
    if (lang != null) {
      _langChoice = lang;
      if (lang != 'auto') _lang = lang;
    }
    notifyListeners();

    // 새 설정이 적용될 첫 문장 번호(1부터)
    for (var i = _currentIndex < 0 ? 0 : _currentIndex; i < _items.length; i++) {
      if (_items[i].status == SentenceStatus.pending) return i + 1;
    }
    return null;
  }

  // ---------------------------------------------------------------- 시작/정지
  /// [sourceId]의 글을 읽기 시작한다.
  ///
  /// 이미 다른 글을 읽고 있었다면 그 글의 대기열을 보관해 두고 넘어간다.
  /// 예전에 읽던 글이면 [resumeIndex]부터 이어서 읽고, 폴더에 이미 만들어 둔
  /// 음성이 있으면 다시 만들지 않고 그대로 쓴다 (이름으로 알아본다).
  Future<void> start(
    String text, {
    required String sourceId,
    int resumeIndex = 0,
  }) async {
    if (_tts == null) return;

    // 지금 읽던 글이 있으면 대기열을 보관하고 멈춘다 (파일은 지우지 않는다)
    await park();

    final gen = ++_generation;
    _error = null;
    _userPaused = false;
    _sourceId = sourceId;

    final cleaned = cleanText(text).trim();
    if (cleaned.isEmpty) {
      _setStatus('Nothing to read.');
      return;
    }

    _lang = _langChoice == 'auto' || _langChoice == 'na'
        ? detectLang(cleaned)
        : _langChoice;

    // 문장 나누기는 같은 글·같은 언어면 항상 같은 결과가 나온다.
    // 그래서 앱을 다시 켜도 문장 번호가 그대로라 이어듣기가 성립한다.
    final sentences = splitUnits(cleaned, _lang);
    if (sentences.isEmpty) {
      _setStatus('No sentences to read.');
      return;
    }

    _items = [
      for (var i = 0; i < sentences.length; i++) SentenceItem(i, sentences[i])
    ];

    final startAt = resumeIndex.clamp(0, _items.length - 1);
    _currentIndex = startAt;

    // 앞쪽은 이미 들은 것으로 표시
    for (var i = 0; i < startAt; i++) {
      _items[i].status = SentenceStatus.done;
    }

    _sessionDir = await _sessionDirFor(sourceId);

    // 이미 만들어 둔 음성을 되찾는다. 이름만 보고 알아내므로 앱을 껐다 켠
    // 뒤에도 그대로 되찾는다 — 메모리에 표를 들고 있을 필요가 없다.
    _attachMade(startAt);

    _voiceFull = false;
    _madeSinceCheck = 0;
    _playlistGen++;
    _playlistEnd = startAt;
    _playlistMap.clear();
    _running = true;
    _stalled = true;
    _warmupTarget = sentences.length < warmupUnits ? sentences.length : warmupUnits;
    _warmOk = false;
    _setStatus('Making the first sentence…');

    unawaited(_worker(gen));
    unawaited(_pump(gen));
  }

  /// 폴더에 이미 있는 음성을 문장에 붙인다.
  ///
  /// **설정으로 가리지 않는다 — 있으면 쓴다.** 목소리를 바꿨다고 이미
  /// 만들어 둔 것을 못 본 척하고 처음부터 다시 만드는 것은 값이 너무 크다.
  /// 지금 설정으로 만든 것이 따로 있으면 그쪽을 먼저 고른다.
  void _attachMade(int startAt) {
    final dir = _sessionDir;
    if (dir == null || !dir.existsSync()) return;

    final byPrefix = _byPrefix(dir);
    if (byPrefix.isEmpty) return;

    final sig = _signature;
    var found = 0;
    for (var i = 0; i < _items.length; i++) {
      final name = _pickFileFor(byPrefix, i, _items[i].text, _voice, sig);
      if (name == null) continue;
      _items[i].filePath = '${dir.path}/$name';
      _items[i].voice = voiceOfFileName(name) ?? _legacyVoiceOf(name);
      if (i >= startAt) _items[i].status = SentenceStatus.ready;
      found++;
    }
    if (found > 0) logger.i('만들어 둔 음성 $found개를 되찾았다');
  }

  /// 재생을 멈춘다. **만들어둔 음성은 그대로 둔다.**
  ///
  /// 전에는 현재 위치 주변 열 개만 남기고 버렸다. 그러면 나갔다 들어올 때마다
  /// 처음부터 다시 만들어야 했다. 한 문장이 0.7MB 뿐이고, 다시 만드는 값이
  /// 훨씬 비싸다. 총량은 [voiceLimitBytes] 로 묶어 둔다.
  Future<void> park() async {
    _generation++;
    _running = false;
    _stalled = false;
    _synthesizingIndex = -1;
    await _withPlaylist(() async {
      _playlistGen++;
      _playlistEnd = 0;
      _playlistMap.clear();
      try {
        await player.stop();
        await player.clearAudioSources();
      } catch (_) {}
    });

    _setStatus('Stopped.');
  }

  /// 글을 삭제할 때 — 보관 중인 대기열과 음성 파일 폴더를 통째로 없앤다
  Future<void> dropSource(String sourceId) async {
    if (_sourceId == sourceId) {
      _sourceId = null;
      _items = [];
      _currentIndex = -1;
      _running = false;
    }
    try {
      final dir = await _sessionDirFor(sourceId, create: false);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    notifyListeners();
  }

  /// 지금 서 있는 자리가 아직 만들어지지 않아 기다리는 중인지.
  ///
  /// 기계에 실제로 올라간 문장은 [synthesizingIndex] 다 — 그건 다른 문장일
  /// 수 있다. 한 번에 하나씩만 만들 수 있어서, 눌러서 옮겨 온 자리는 앞의
  /// 것이 끝나야 차례가 온다. 그동안 이 자리를 '대기'로 보여 주면 눌러도
  /// 아무 일이 없는 것처럼 보이므로, 만드는 중과 같은 얼굴로 세운다.
  bool get isWaitingHere =>
      _running &&
      _currentIndex >= 0 &&
      _currentIndex < _items.length &&
      _items[_currentIndex].status == SentenceStatus.pending;

  /// 지금 들리는 목소리. 만들어 둔 것을 쓰고 있으면 설정과 다를 수 있다.
  /// 알 수 없으면 null — 그때는 설정의 목소리를 쓰면 된다.
  String? get playingVoice {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return null;
    return _items[_currentIndex].voice;
  }

  /// 지금 위치의 음성 파일 경로 (앱을 끌 때 저장해 둘 값)
  String? get currentFilePath {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return null;
    return _items[_currentIndex].filePath;
  }

  Future<void> stop() => park();

  /// 세운다. **뜻을 먼저 알리고** 재생기에 시킨다.
  ///
  /// 전에는 재생기가 답할 때까지 기다린 뒤에 알렸다. 그런데 [AudioPlayer.play]
  /// 는 재생목록이 비어 있거나 플랫폼을 다시 깨워야 할 때 한참 돌아오지
  /// 않는다. 그동안 화면은 옛 상태 그대로라, 눌렀는데 아무 일도 없는 것처럼
  /// 보이고 한 번 더 누르게 된다.
  Future<void> pause() async {
    _userPaused = true;
    notifyListeners();
    await player.pause();
  }

  Future<void> resume() async {
    _userPaused = false;
    notifyListeners();
    // 세워 둔 사이에 다음 문장이 다 만들어져 대기열에 들어와 있을 수 있다.
    // 그때는 재생기가 아직 그 자리에 서 있지 않으므로 밀어 준다.
    unawaited(_pump(_generation));
    unawaited(player.play().catchError((Object e, StackTrace st) {
      logger.e('재생 재개 실패', error: e, stackTrace: st);
    }));
  }

  Future<void> skipNext() => seekToUnit(_currentIndex + 1);

  Future<void> skipPrevious() => seekToUnit(_currentIndex - 1);

  /// 문장 하나를 손으로 고른 설정으로 다시 만든다.
  ///
  /// 전역 설정은 건드리지 않는다 — 이 문장 하나에만 쓴다.
  ///
  /// 그 문장의 **옛 음성은 지운다.** 파일 이름에 설정이 들어가므로 그냥
  /// 두면 후보가 둘이 되는데, 다음에 이 글에 들어올 때 엔진은 '지금
  /// 설정과 맞는 것' 을 먼저 고른다. 그러면 애써 다시 만든 것이 묻힌다.
  /// 하나만 남겨 두어야 다시 만든 것이 그대로 유지된다.
  ///
  /// **듣던 흐름은 건드리지 않는다.** 자리를 옮기지도, 지금 나는 소리를
  /// 끊지도 않는다. 다시 만든 음성은 그 문장의 차례가 올 때 들린다.
  /// 지금 듣고 있는 문장을 다시 만들라고 이르면, 이번 한 번은 옛 소리로
  /// 끝까지 가고 새 것은 다음 차례부터 쓰인다.
  Future<void> remake(
    int index, {
    required String voice,
    required double speed,
    required int steps,
  }) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final dir = _sessionDir;

    // 이 문장의 옛 음성을 지운다
    if (dir != null && dir.existsSync()) {
      final prefix = voiceFilePrefix(index, item.text);
      for (final f in dir.listSync()) {
        if (f is File && f.path.split('/').last.startsWith('${prefix}_')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    }

    item.forceVoice = voice;
    item.forceSpeed = speed;
    item.forceSteps = steps;
    item.filePath = null;
    item.voice = null;
    item.status = SentenceStatus.pending;
    notifyListeners();

    // 이미 재생기에 담아 둔 문장이면 방금 지운 파일을 가리키고 있다.
    // 지금 듣고 있는 것만 남기고 그 뒤를 비워, 소리는 이어지면서
    // 대기열만 새로 채워지게 한다.
    await _withPlaylist(() async {
      final at = player.currentIndex;
      if (at == null || at + 1 >= _playlistMap.length) return;
      try {
        await player.removeAudioSourceRange(at + 1, _playlistMap.length);
        _playlistMap.removeRange(at + 1, _playlistMap.length);
        _playlistEnd = _playlistMap.last + 1;
      } catch (e, st) {
        logger.e('대기열 비우기 실패', error: e, stackTrace: st);
      }
    });
    unawaited(_pump(_generation));
  }

  /// 지정한 문장부터 다시 읽는다. 그 뒤 문장들도 필요하면 새로 합성한다.
  Future<void> seekToUnit(int index) async {
    if (_items.isEmpty || _tts == null) return;
    final i = index.clamp(0, _items.length - 1);
    final gen = _generation;

    // 고른 지점부터 뒤쪽 정리:
    //  · 음성 파일이 남아 있으면 → 다시 재생할 수 있도록 '준비됨'으로
    //  · 파일이 없으면 → 새로 만들도록 '대기'로
    for (var k = i; k < _items.length; k++) {
      final it = _items[k];
      if (it.status == SentenceStatus.synthesizing) continue;
      if (it.filePath != null && File(it.filePath!).existsSync()) {
        if (it.status != SentenceStatus.ready) it.status = SentenceStatus.ready;
      } else {
        it.filePath = null;
        if (it.status != SentenceStatus.pending) {
          it.status = SentenceStatus.pending;
        }
      }
    }
    if (_currentIndex >= 0 && _currentIndex < _items.length) {
      final cur = _items[_currentIndex];
      if (cur.status == SentenceStatus.playing) {
        cur.status =
            i > _currentIndex ? SentenceStatus.done : SentenceStatus.ready;
      }
    }

    _currentIndex = i;
    _stalled = true;
    _error = null;
    _warmOk = true; // 건너뛴 뒤에는 준비되는 대로 바로 재생

    // 소리를 멈추기 전에 먼저 알린다. 멈추는 동안 화면이 옛 자리를 그대로
    // 들고 있으면, 누른 것이 먹히지 않은 것처럼 보인다.
    notifyListeners();

    // 담는 일이 끝난 뒤에 비운다. 담기와 비우기가 겹치면 재생기의 순서와
    // 문장 번호표가 어긋나, 읽는 문장과 노란 칸이 서로 달라진다.
    await _withPlaylist(() async {
      _playlistGen++;
      _playlistEnd = i;
      _playlistMap.clear();
      try {
        await player.stop();
        await player.clearAudioSources();
      } catch (_) {}
    });

    final wasFinished = !_running;
    if (wasFinished) {
      _running = true;
      final id = _sourceId;
      if (_sessionDir == null && id != null) {
        _sessionDir = await _sessionDirFor(id);
      }
      _setStatus('Resuming…');
      unawaited(_worker(_generation));
    }

    notifyListeners();
    await _pump(gen);
  }

  // ------------------------------------------------------------------ 워커
  /// 지금 재생 위치를 기준으로, 아직 안 만든 문장 중 가장 가까운 것.
  ///
  /// 앞쪽에 빈 자리가 있으면 아무리 멀어도 끝까지 계속 채운다. 준비분이
  /// 몇 개든 쉬지 않는다 — 되찾은 음성이 앞쪽에 많다는 이유로 손을 놓으면,
  /// 그 사이사이의 빈 자리가 영영 채워지지 않는다.
  /// 저장공간이 차도 멈추지 않는다 — 넘었다는 것은 [voiceFull] 로 알리기만 한다.
  int? _pickNext() {
    // 손으로 다시 만들라고 이른 문장이 먼저다. 지금 듣는 자리보다 뒤에
    // 있어도 만든다 — 아래 훑기는 지금 자리부터라 그냥 두면 영영 지나친다.
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (it.forceVoice != null && it.status == SentenceStatus.pending) {
        return i;
      }
    }
    final start = _currentIndex < 0 ? 0 : _currentIndex;
    for (var i = start; i < _items.length; i++) {
      if (_items[i].status == SentenceStatus.pending) return i;
    }
    return null;
  }

  Future<void> _worker(int gen) async {
    while (gen == _generation && _running) {
      final i = _pickNext();
      if (i == null) {
        await Future.delayed(const Duration(milliseconds: 120));
        continue;
      }

      // 매번 최신 설정을 읽는다 → 읽는 중에 바꿔도 곧바로 반영.
      // 이름에도 이때 읽은 값을 담는다 — 만드는 사이에 설정이 또 바뀌어도
      // 파일 이름과 실제 소리가 어긋나지 않는다.
      // 손으로 다시 만들라고 이른 문장이면 그때 고른 설정을 쓴다.
      final forced = _items[i];
      final voice = forced.forceVoice ?? _voice;
      final speed = forced.forceSpeed ?? _speed;
      final steps = forced.forceSteps ?? _steps;
      final lang = _lang;
      final signature = '$voice|$lang|${speed.toStringAsFixed(2)}|$steps';

      final item = _items[i];
      item.status = SentenceStatus.synthesizing;
      _synthesizingIndex = i;

      notifyListeners();

      try {
        final dir = _sessionDir;
        if (dir == null) return;
        final style = await _style(voice);

        // 어디서 시간이 걸리는지 확인할 수 있도록 구간별로 측정한다
        final t0 = DateTime.now();
        final result =
            await _tts!.call(item.text, lang, style, steps, speed: speed);
        if (gen != _generation) return;
        final t1 = DateTime.now();

        final wav = (result['wav'] as List).cast<double>();
        final path =
            '${dir.path}/${voiceFileName(i, item.text, voice, signature)}';
        writeWavFile(path, wav, _tts!.sampleRate);
        final t2 = DateTime.now();

        final audioMs = wav.length * 1000 ~/ _tts!.sampleRate;
        final inferMs = t1.difference(t0).inMilliseconds;
        final writeMs = t2.difference(t1).inMilliseconds;
        logger.i('#${i + 1} ${item.text.length}자 · 추론 ${inferMs}ms · '
            '저장 ${writeMs}ms · 음성 ${audioMs}ms · '
            '실시간대비 ${((inferMs + writeMs) / audioMs).toStringAsFixed(2)}배');

        // 만드는 사이에 사용자가 다른 곳으로 건너뛰었을 수 있다
        if (item.status == SentenceStatus.synthesizing) {
          item.filePath = path;
          item.voice = voice;
          // 방금 기계를 돌려 뽑은 목소리다. 디스크에서 되찾은 것과는 다르다.
          _lastMadeVoice = voice;
          item.status = SentenceStatus.ready;
          // 한 번 쓰고 비운다. 파일이 하나뿐이라 다음에도 이것이 뽑힌다.
          item.forceVoice = null;
          item.forceSpeed = null;
          item.forceSteps = null;
        }
      } catch (e, st) {
        logger.e('문장 $i 합성 실패', error: e, stackTrace: st);
        _error = '$e';
        if (item.status == SentenceStatus.synthesizing) {
          item.status = SentenceStatus.failed;
        }
      } finally {
        _synthesizingIndex = -1;
        notifyListeners();
      }

      await _pump(gen);
      await _checkWarmup(gen);
      await _checkStorage(gen);
    }
  }

  /// 스물다섯 문장마다 한 번씩 총량을 재서, 상한을 넘었는지만 봐 둔다.
  /// 매번 재면 폴더를 훑는 값이 아까워 띄엄띄엄 잰다.
  ///
  /// 넘어도 만들기를 멈추지 않는다. 화면(PLAY)이 붉어질 뿐이다.
  Future<void> _checkStorage(int gen) async {
    if (++_madeSinceCheck < 25) return;
    _madeSinceCheck = 0;
    try {
      final bytes = await voiceBytes();
      if (gen != _generation) return;
      final full = bytes >= voiceLimitBytes;
      if (full != _voiceFull) {
        _voiceFull = full;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 준비된 문장이 목표치에 이르면 재생을 시작한다.
  /// 더 만들 문장이 남지 않았다면(짧은 글) 목표치에 못 미쳐도 시작한다.
  Future<void> _checkWarmup(int gen) async {
    if (_warmOk || gen != _generation) return;

    final start = _currentIndex < 0 ? 0 : _currentIndex;
    final end = (start + _warmupTarget).clamp(0, _items.length);
    var done = 0;
    for (var i = start; i < end; i++) {
      final s = _items[i].status;
      if (s == SentenceStatus.ready ||
          s == SentenceStatus.failed ||
          s == SentenceStatus.playing ||
          s == SentenceStatus.done) {
        done++;
      }
    }

    if (done >= _warmupTarget || _pickNext() == null) {
      _warmOk = true;
      await _startPlaybackIfReady(gen);
    } else {
      _setStatus('Making the first sentence… ($done/$_warmupTarget)');
    }
  }

  Future<void> _startPlaybackIfReady(int gen) async {
    if (!_warmOk || gen != _generation) return;
    // 손수 세워 둔 것은 그대로 둔다. 자리만 옮기고 서 있는다.
    if (_userPaused) return;
    if (player.sequence.isEmpty || player.playing) return;
    try {
      _stalled = false;
      await player.play();
      if (gen != _generation) return;
      if (_playlistMap.isNotEmpty) {
        final at = player.currentIndex ?? 0;
        if (at >= 0 && at < _playlistMap.length) _markPlaying(_playlistMap[at]);
      }
      _setStatus(statusPlaying);
    } catch (e, st) {
      logger.e('재생 시작 실패', error: e, stackTrace: st);
    }
  }

  /// 준비된 문장을 순서대로 재생목록에 밀어 넣는다.
  Future<void> _pump(int gen) async {
    // 이미 밀고 있으면 겹쳐 밀지 않는다. 대신 표시만 남겨, 밀던 쪽이
    // 끝내면서 한 번 더 돌게 한다. 그러지 않으면 미는 사이에 들어온
    // 자리 옮기기가 아무도 담아 주지 않아 그대로 멎는다.
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        final pg = _playlistGen;
        while (gen == _generation &&
            pg == _playlistGen &&
            _playlistEnd < _items.length &&
            _playlistEnd - _currentIndex <= maxQueueAhead) {
          final it = _items[_playlistEnd];
          if (it.status == SentenceStatus.failed) {
            _playlistEnd++; // 실패한 문장은 건너뛴다
            continue;
          }
          if (it.status != SentenceStatus.ready || it.filePath == null) break;

          await _enqueue(gen, pg, it);
          if (gen != _generation || pg != _playlistGen) break;
          _playlistEnd++;
        }
      } while (_pumpAgain && gen == _generation);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _enqueue(int gen, int pg, SentenceItem item) async {
    return _withPlaylist(() async {
      // 줄을 서서 들어왔으니, 기다리는 사이에 목록이 비워졌을 수 있다.
      if (gen != _generation || pg != _playlistGen) return;
      final source = AudioSource.file(item.filePath!);
      try {
        if (player.sequence.isEmpty) {
          _playlistMap.add(item.index);
          // 목록에는 넣되, 준비가 끝나기 전에는 재생을 시작하지 않는다
          await player.setAudioSources([source]);
          if (gen != _generation || pg != _playlistGen) return;
          await _startPlaybackIfReady(gen);
        } else {
          _playlistMap.add(item.index);
          await player.addAudioSource(source);
          if (gen != _generation || pg != _playlistGen) return;
          if (_stalled && _warmOk) {
            // 앞 문장이 끝나 멈춰 있었다면 방금 넣은 문장부터 이어서 재생.
            // 손수 세워 둔 상태라면 자리만 잡아 두고 읽지는 않는다.
            _stalled = false;
            await player.seek(Duration.zero, index: _playlistMap.length - 1);
            if (!_userPaused) await player.play();
            if (gen != _generation || pg != _playlistGen) return;
            // 알림이 오지 않을 수 있으므로 직접 맞춰 둔다
            _markPlaying(item.index);
          }
        }
      } catch (e, st) {
        logger.e('재생 대기열 추가 실패', error: e, stackTrace: st);
        _error = '$e';
        notifyListeners();
      }
    });
  }

  // ------------------------------------------------------------- 재생 추적
  /// 재생기가 '지금 몇 번째 곡' 이라고 알려 올 때.
  ///
  /// 자리 번호만 따로 듣지 않고 **재생목록과 한 묶음으로** 받는다.
  /// 자리를 옮기면 목록을 비우고 새로 담는데, 그 사이에 옛 목록을 가리키는
  /// 알림이 뒤늦게 날아온다. 번호만 보면 그것이 새 목록의 엉뚱한 자리에
  /// 꽂혀, 방금 누른 문장 대신 한참 앞의 문장으로 뛰어 버린다.
  ///
  /// 재생기가 든 곡 수가 우리 번호표([_playlistMap])의 길이와 다르면
  /// 갈아 끼우는 중이라는 뜻이므로 흘려보낸다. 담고 비우는 쪽이 늘
  /// 번호표를 먼저 고치므로, 길이가 같다는 것은 곧 같은 목록을 보고
  /// 있다는 뜻이다.
  void _onSequenceState(SequenceState state) {
    if (state.sequence.length != _playlistMap.length) return;
    final at = state.currentIndex;
    if (at == null || at < 0 || at >= _playlistMap.length) return;
    _markPlaying(_playlistMap[at]);
  }

  /// 지금 읽고 있는 문장을 화면에 반영한다.
  ///
  /// 재생기의 인덱스 알림만 믿으면 안 된다. 멈춰 있다가 새 문장을 넣고 그
  /// 자리로 건너뛸 때, 재생기의 인덱스가 이미 그 값이면 알림이 오지 않는다.
  /// 그러면 소리는 새 문장인데 화면은 앞 문장에 노랗게 남는다.
  /// 자리를 옮기는 쪽에서 직접 불러 준다.
  void _markPlaying(int index) {
    if (index < 0 || index >= _items.length) return;

    // 재생목록에 한 문장을 담을 때마다 재생기가 인덱스를 다시 알려 준다.
    // 자리가 그대로면 157개를 훑고 화면을 다시 그릴 이유가 없다 —
    // 한 번 건너뛸 때 이 알림이 서른 번 넘게 오기도 한다.
    if (_currentIndex == index &&
        _items[index].status == SentenceStatus.playing) {
      _stalled = false;
      return;
    }

    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (i < index) {
        if (it.status == SentenceStatus.playing ||
            it.status == SentenceStatus.ready) {
          it.status = SentenceStatus.done;
        }
      } else if (i == index) {
        it.status = SentenceStatus.playing;
      }
    }
    _currentIndex = index;
    _stalled = false;
    // 한 걸음 나아갔으니 그만큼 더 담을 자리가 생겼다
    unawaited(_pump(_generation));
    onSentenceChanged?.call(_items[index]);
    _setStatus('$statusPlaying (${index + 1}/${_items.length})');
  }

  void _finish() {
    if (!_running) return;
    _running = false;
    _stalled = false;
    for (final it in _items) {
      if (it.status != SentenceStatus.failed) it.status = SentenceStatus.done;
    }
    final failed =
        _items.where((e) => e.status == SentenceStatus.failed).length;
    _setStatus(failed == 0
        ? 'All read (${_items.length} sentences)'
        : 'Done — $failed of ${_items.length} sentences failed');
  }

  /// 음성 파일 하나의 이름.
  ///
  /// 이름만 보고 "몇 번째 문장을, 어떤 글로, 어떤 설정으로 만든 것인지" 를
  /// 알 수 있어야 한다. 그래야 앱을 껐다 켠 뒤에도 디스크만 훑어서 되찾는다.
  /// 전에는 만든 시각을 붙였고 짝은 메모리 안의 표에만 있었다 — 앱을 끄면
  /// 표가 사라져 전부 다시 만들었다.
  ///
  ///   s0007_a1b2c3d4_F2_e5f6a7b8.wav
  ///        └ 문장 번호  └ 글자   └ 목소리 └ 나머지 설정
  ///
  /// 목소리만 줄이지 않고 그대로 적는다. 화면 아래 얼굴이 "지금 들리는
  /// 목소리"를 따라야 하는데, 줄인 표에서는 되읽을 수 없기 때문이다.
  ///
  /// 설정도 이름에 담지만, **가져다 쓸지는 설정으로 가리지 않는다.**
  /// 있으면 쓴다 — 목소리를 바꿨다고 이미 만들어 둔 것을 못 본 척하고
  /// 처음부터 다시 만드는 것은 치르는 값이 너무 크다. 설정을 담아 두는 것은
  /// 같은 문장의 여러 벌이 서로 덮어쓰지 않게 하고, 지금 설정으로 만든 것이
  /// 있으면 그쪽을 먼저 고르기 위해서다.
  @visibleForTesting
  static String voiceFileName(
          int index, String text, String voice, String signature) =>
      '${voiceFilePrefix(index, text)}_${voice}_${tag(signature)}.wav';

  /// 쓸 수 있는 목소리 이름들
  static const voices = ['M1', 'M2', 'M3', 'M4', 'M5',
                         'F1', 'F2', 'F3', 'F4', 'F5'];

  /// 파일 이름에서 목소리를 되읽는다. 옛 이름(목소리를 안 적던 것)이면 null.
  @visibleForTesting
  static String? voiceOfFileName(String name) {
    final parts = name.replaceAll('.wav', '').split('_');
    return parts.length >= 4 ? parts[2] : null;
  }

  /// 목소리를 안 적던 옛 이름에서 목소리를 되찾아 본다.
  ///
  /// 옛 이름의 마지막 토막은 설정을 통째로 줄인 표라 그대로는 되읽을 수
  /// 없다. 목소리 열 가지와 품질 열한 단계를 대입해 같은 표가 나오는지
  /// 맞춰 본다. 품질도 함께 대입하는 것은, 목소리를 바꾼 사람은 품질도
  /// 바꿔 봤을 가능성이 높기 때문이다.
  ///
  /// 언어나 속도가 그때와 다르면 못 찾는다 — 그때는 null 이고, 화면은
  /// 설정의 목소리를 보여 준다.
  String? _legacyVoiceOf(String name) {
    final parts = name.replaceAll('.wav', '').split('_');
    if (parts.length != 3) return null;

    // 표는 백열 줄뿐이라 한 번 만들어 두고 다시 쓴다. 파일마다 새로
    // 만들면 문장 천 개짜리 글에서 십만 번을 헛돈다.
    final key = '$_lang|${_speed.toStringAsFixed(2)}';
    if (_legacyKey != key) {
      final t = <String, String>{};
      for (final v in voices) {
        for (var st = 2; st <= 12; st++) {
          t[tag(signatureOf(
              voice: v, lang: _lang, speed: _speed, steps: st))] = v;
        }
      }
      _legacyTable = t;
      _legacyKey = key;
    }
    return _legacyTable[parts[2]];
  }

  Map<String, String> _legacyTable = const {};
  String _legacyKey = '';

  /// 설정을 뺀 앞부분. 이것만 같으면 같은 문장의 음성이다.
  @visibleForTesting
  static String voiceFilePrefix(int index, String text) =>
      's${index.toString().padLeft(4, '0')}_${tag(text)}';

  /// 폴더에 있는 파일을 앞부분별로 모은다.
  ///
  /// 앞 두 토막(문장 번호 + 글자)만 본다. 그래야 목소리를 적기 전에 만든
  /// 이름도 같은 자리에 모여, 예전에 만들어 둔 음성을 그대로 쓸 수 있다.
  static Map<String, List<String>> _byPrefix(Directory dir) {
    final out = <String, List<String>>{};
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.path.split('/').last;
      if (!name.endsWith('.wav')) continue;
      final parts = name.split('_');
      if (parts.length < 3) continue;
      out.putIfAbsent('${parts[0]}_${parts[1]}', () => []).add(name);
    }
    return out;
  }

  /// 그 문장에 쓸 파일 하나를 고른다.
  /// 지금 설정으로 만든 것이 있으면 그것을, 없으면 아무거나 — 있으면 쓴다.
  static String? _pickFileFor(Map<String, List<String>> byPrefix, int i,
      String text, String voice, String sig) {
    final names = byPrefix[voiceFilePrefix(i, text)];
    if (names == null || names.isEmpty) return null;
    final want = voiceFileName(i, text, voice, sig);
    return names.contains(want) ? want : names.first;
  }

  /// 설정을 한 줄로. 소리에 영향을 주는 것만 넣는다.
  static String signatureOf({
    required String voice,
    required String lang,
    required double speed,
    required int steps,
  }) =>
      '$voice|$lang|${speed.toStringAsFixed(2)}|$steps';

  String get _signature => signatureOf(
      voice: _voice, lang: _lang, speed: _speed, steps: _steps);

  /// 짧고 값이 늘 같은 표.
  ///
  /// String.hashCode 는 쓰지 않는다 — 한 번 실행하는 동안에는 같지만 다시
  /// 켜면 달라질 수 있어서, 이름에 박아 두면 되찾지 못한다. (FNV-1a)
  @visibleForTesting
  static String tag(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// 글마다 고정된 폴더를 쓴다. 그래야 다른 글에 갔다 와도 파일이 그대로 있다.
  ///
  /// 캐시가 아니라 문서 폴더에 둔다. 안드로이드는 저장 공간이 모자라면
  /// 캐시를 묻지도 않고 지운다 — 애써 만든 음성이 어느 날 사라져 있으면
  /// 안 버리는 뜻이 없다.
  Future<Directory> _sessionDirFor(String sourceId, {bool create = true}) async {
    final dir = Directory('${await _voiceRootPath()}/$sourceId');
    if (create && !dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<String> _voiceRootPath() async =>
      '${(await getApplicationDocumentsDirectory()).path}/voice';

  /// 앱을 켤 때 정리.
  ///
  /// **목록에서 없어진 글의 음성만 버린다.** 목록에 남아 있는 글의 음성은
  /// 총량이 [voiceLimitBytes] 를 넘더라도 손대지 않는다 — 넘었다는 것은
  /// [voiceFull] 로 알리기만 하고, 지울지 말지는 사람이 설정에서 정한다.
  ///
  /// 단문으로 읽은 일회성 글은 목록에 없으므로 여기서 함께 없어진다.
  /// 그게 일회성이라는 뜻이다.
  static Future<void> pruneVoice({required List<String> liveIds}) async {
    try {
      await _sweepLegacyCache();

      final root = Directory(await _voiceRootPath());
      if (!root.existsSync()) return;

      final live = liveIds.toSet();
      for (final entry in root.listSync()) {
        if (entry is! Directory) continue;
        if (live.contains(entry.path.split('/').last)) continue;
        entry.deleteSync(recursive: true);
      }
    } catch (e, st) {
      logger.e('음성 폴더 정리 실패', error: e, stackTrace: st);
    }
  }

  /// 그 글의 문장마다 지금 설정으로 만들어 둔 음성이 있는지.
  ///
  /// 읽고 있지 않은 글도 물어볼 수 있다 — 폴더에 있는 이름만 보고 알아낸다.
  /// 문장 나누기는 엔진이 읽을 때와 똑같은 방법이라 번호가 어긋나지 않는다.
  static Future<List<bool>> madeFlags({
    required String sourceId,
    required String text,
    required String langChoice,
  }) async =>
      _flagsFor(await _voiceRootPath(), sourceId, text, langChoice);

  /// 여러 글의 띠를 한꺼번에 잰다.
  ///
  /// 폴더를 훑고 글을 문장으로 나누는 일이라, 글이 길고 파일이 많으면
  /// 그 사이 화면이 멎는다. 딴 일꾼에게 통째로 맡기고 결과만 받는다.
  static Future<Map<String, List<bool>>> madeFlagsBatch({
    required List<List<String>> sources, // [글 번호, 글]
    required String langChoice,
  }) async {
    if (sources.isEmpty) return const {};
    final root = await _voiceRootPath();
    return Isolate.run(() => {
          for (final s in sources)
            s[0]: _flagsFor(root, s[0], s[1], langChoice),
        });
  }

  static List<bool> _flagsFor(
      String root, String sourceId, String text, String langChoice) {
    final cleaned = cleanText(text).trim();
    if (cleaned.isEmpty) return const [];
    final lang = langChoice == 'auto' || langChoice == 'na'
        ? detectLang(cleaned)
        : langChoice;
    final units = splitUnits(cleaned, lang);
    if (units.isEmpty) return const [];

    final dir = Directory('$root/$sourceId');
    if (!dir.existsSync()) return List.filled(units.length, false);

    final byPrefix = _byPrefix(dir);
    if (byPrefix.isEmpty) return List.filled(units.length, false);

    // 설정을 가리지 않는다 — 어떤 설정으로 만들었든 있으면 쓰기 때문이다
    return [
      for (var i = 0; i < units.length; i++)
        byPrefix.containsKey(voiceFilePrefix(i, units[i])),
    ];
  }

  /// 만들어둔 음성이 지금 몇 바이트인지
  static Future<int> voiceBytes() async {
    final root = Directory(await _voiceRootPath());
    if (!root.existsSync()) return 0;
    return _dirBytes(root);
  }

  /// 글 하나가 들고 있는 음성이 몇 바이트인지.
  /// 그 글의 곁차림에서 '얼마가 지워지는지' 를 적어 주는 데 쓴다.
  static Future<int> voiceBytesFor(String sourceId) async {
    final dir = Directory('${await _voiceRootPath()}/$sourceId');
    if (!dir.existsSync()) return 0;
    return _dirBytes(dir);
  }

  /// 만들어둔 음성을 전부 버린다 (글은 남는다)
  static Future<void> clearVoice() async {
    final root = Directory(await _voiceRootPath());
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  /// 저장공간을 비웠으니 붉은 표시를 거둔다.
  void resumeAfterCleanup() {
    if (!_voiceFull) return;
    _voiceFull = false;
    _madeSinceCheck = 0;
    notifyListeners();
  }

  static int _dirBytes(Directory dir) {
    var sum = 0;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File) {
        try {
          sum += f.lengthSync();
        } catch (_) {}
      }
    }
    return sum;
  }

  /// 예전에는 음성을 캐시에 뒀다. 옮긴 뒤 남은 것들을 한 번 걷어낸다.
  static Future<void> _sweepLegacyCache() async {
    try {
      final base = await getTemporaryDirectory();
      for (final entry in base.listSync()) {
        if (entry is Directory &&
            entry.path.split('/').last.startsWith('suto_')) {
          entry.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }

  void _setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _watchdog?.cancel();
    player.dispose();
    // 음성 파일은 지우지 않는다. 앱을 다시 켤 때 cleanupTemp()가
    // 각 글의 마지막 재생 위치 파일만 남기고 정리한다.
    super.dispose();
  }
}
