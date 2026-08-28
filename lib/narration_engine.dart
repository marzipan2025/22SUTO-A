import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart';
import 'package:suto_a/sentence_splitter.dart';

/// 문장 하나의 상태
enum SentenceStatus { pending, synthesizing, ready, playing, done, failed }

class SentenceItem {
  SentenceItem(this.index, this.text);

  final int index;
  final String text;

  SentenceStatus status = SentenceStatus.pending;
  String? filePath;
}

/// 선행 합성(prefetch) 파이프라인.
///
/// 합성 담당은 항상 "지금 재생 위치"를 기준으로 가장 가까운 미완성 문장을 고른다.
/// 그래서 사용자가 어느 문장으로 건너뛰어도 그 지점부터 곧바로 따라붙고,
/// 대기열 크기가 일정하므로 글이 아무리 길어도 메모리 사용량은 변하지 않는다.
class NarrationEngine extends ChangeNotifier {
  NarrationEngine({this.maxReadyAhead = 60, this.warmupUnits = 1});

  /// 아직 재생하지 않은 준비분을 최대 몇 개까지 쌓아둘지.
  ///
  /// 여유가 있으면 계속 앞서 만들어 두되, 저장공간이 무한정 늘지 않도록
  /// 이 개수에 이르면 재생이 따라올 때까지 잠시 쉰다.
  final int maxReadyAhead;

  /// 재생을 시작하기 전에 먼저 만들어 둘 문장 수 (1 = 첫 문장이 준비되면 바로 시작)
  final int warmupUnits;

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

  int _generation = 0;
  int _currentIndex = -1;
  int _synthesizingIndex = -1;
  int _playlistEnd = 0; // 다음에 재생목록에 넣을 문장 번호
  final List<int> _playlistMap = []; // 재생목록 위치 → 문장 번호
  Directory? _sessionDir;
  bool _running = false;
  bool _stalled = false;
  bool _pumping = false;
  int _warmupTarget = 0; // 재생 시작 전에 준비해야 할 문장 수
  bool _warmOk = true; // 재생을 시작해도 되는지
  String _status = '';
  String? _error;

  int get currentIndex => _currentIndex;
  int get synthesizingIndex => _synthesizingIndex;
  bool get isRunning => _running;
  bool get isStalled => _stalled;
  bool get isPlaying => player.playing;
  String get status => _status;
  String? get error => _error;
  String get lang => _lang;

  int get total => _items.length;
  int get doneCount =>
      _items.where((e) => e.status == SentenceStatus.done).length;
  int get readyCount =>
      _items.where((e) => e.status == SentenceStatus.ready).length;

  /// 현재 문장이 바뀔 때 호출 (알림 문구 갱신용)
  void Function(SentenceItem item)? onSentenceChanged;

  // ---------------------------------------------------------------- 초기화
  Future<void> loadModels() async {
    _setStatus('음성 엔진 준비 중...');
    _tts = await loadTextToSpeech('assets/onnx', useGpu: false);
    await _style('M1');
    _setStatus('준비 완료');

    player.currentIndexStream.listen(_onPlayerIndex);
    player.processingStateStream.listen((s) {
      if (s != ProcessingState.completed) return;
      if (_playlistEnd >= _items.length) {
        _finish();
      } else {
        _stalled = true;
        _setStatus('다음 문장 준비 중...');
      }
    });
  }

  bool get modelsLoaded => _tts != null;

  Future<Style> _style(String voice) async => _styleCache[voice] ??=
      await loadVoiceStyle(['assets/voice_styles/$voice.json']);

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
    _sourceId = sourceId;

    final cleaned = cleanText(text).trim();
    if (cleaned.isEmpty) {
      _setStatus('읽을 글이 없어요.');
      return;
    }

    _lang = _langChoice == 'auto' || _langChoice == 'na'
        ? detectLang(cleaned)
        : _langChoice;

    // 문장 나누기는 같은 글·같은 언어면 항상 같은 결과가 나온다.
    // 그래서 앱을 다시 켜도 문장 번호가 그대로라 이어듣기가 성립한다.
    final sentences = splitUnits(cleaned, _lang);
    if (sentences.isEmpty) {
      _setStatus('읽을 문장이 없어요.');
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

    _playlistEnd = startAt;
    _playlistMap.clear();
    _running = true;
    _stalled = true;
    _warmupTarget = sentences.length < warmupUnits ? sentences.length : warmupUnits;
    _warmOk = false;
    _setStatus('첫 문장 만드는 중...');

    unawaited(_worker(gen));
    unawaited(_pump(gen));
  }

  /// 폴더에 이미 있는 음성을 문장에 붙인다.
  ///
  /// 지금 설정으로 만든 것만 붙인다. 다른 설정으로 만든 것은 소리가 다르므로
  /// 쓰지 않지만 **지우지도 않는다** — 설정을 되돌리면 그때 다시 쓰인다.
  void _attachMade(int startAt) {
    final dir = _sessionDir;
    if (dir == null || !dir.existsSync()) return;

    final have = <String>{};
    for (final f in dir.listSync()) {
      if (f is File) have.add(f.path.split('/').last);
    }
    if (have.isEmpty) return;

    final sig = _signature;
    var found = 0;
    for (var i = 0; i < _items.length; i++) {
      final name = voiceFileName(i, _items[i].text, sig);
      if (!have.contains(name)) continue;
      _items[i].filePath = '${dir.path}/$name';
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
    _playlistEnd = 0;
    _playlistMap.clear();
    try {
      await player.stop();
      await player.clearAudioSources();
    } catch (_) {}

    _setStatus('정지했어요.');
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

  /// 지금 위치의 음성 파일 경로 (앱을 끌 때 저장해 둘 값)
  String? get currentFilePath {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return null;
    return _items[_currentIndex].filePath;
  }

  Future<void> stop() => park();

  Future<void> pause() async {
    await player.pause();
    notifyListeners();
  }

  Future<void> resume() async {
    await player.play();
    notifyListeners();
  }

  Future<void> skipNext() => seekToUnit(_currentIndex + 1);

  Future<void> skipPrevious() => seekToUnit(_currentIndex - 1);

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
    _playlistEnd = i;
    _playlistMap.clear();
    _stalled = true;
    _error = null;
    _warmOk = true; // 건너뛴 뒤에는 준비되는 대로 바로 재생

    try {
      await player.stop();
      await player.clearAudioSources();
    } catch (_) {}

    final wasFinished = !_running;
    if (wasFinished) {
      _running = true;
      final id = _sourceId;
      if (_sessionDir == null && id != null) {
        _sessionDir = await _sessionDirFor(id);
      }
      _setStatus('이어서 준비 중...');
      unawaited(_worker(_generation));
    }

    notifyListeners();
    await _pump(gen);
  }

  // ------------------------------------------------------------------ 워커
  /// 지금 재생 위치를 기준으로, 아직 안 만든 문장 중 가장 가까운 것.
  ///
  /// 여유가 있는 한 끝까지 계속 앞서 만든다. 다만 아직 듣지 않은 준비분이
  /// [maxReadyAhead]를 넘으면 저장공간 보호를 위해 잠시 쉰다.
  int? _pickNext() {
    if (readyCount >= maxReadyAhead) return null;
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
      final voice = _voice, lang = _lang, steps = _steps, speed = _speed;
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
            '${dir.path}/${voiceFileName(i, item.text, signature)}';
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
          item.status = SentenceStatus.ready;
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
    }
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
      _setStatus('첫 문장 만드는 중... ($done/$_warmupTarget)');
    }
  }

  Future<void> _startPlaybackIfReady(int gen) async {
    if (!_warmOk || gen != _generation) return;
    if (player.sequence.isEmpty || player.playing) return;
    try {
      _stalled = false;
      await player.play();
      _setStatus('재생 중');
    } catch (e, st) {
      logger.e('재생 시작 실패', error: e, stackTrace: st);
    }
  }

  /// 준비된 문장을 순서대로 재생목록에 밀어 넣는다.
  Future<void> _pump(int gen) async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (gen == _generation && _playlistEnd < _items.length) {
        final it = _items[_playlistEnd];
        if (it.status == SentenceStatus.failed) {
          _playlistEnd++; // 실패한 문장은 건너뛴다
          continue;
        }
        if (it.status != SentenceStatus.ready || it.filePath == null) break;

        await _enqueue(gen, it);
        if (gen != _generation) return;
        _playlistEnd++;
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _enqueue(int gen, SentenceItem item) async {
    final source = AudioSource.file(item.filePath!);
    try {
      if (player.sequence.isEmpty) {
        _playlistMap.add(item.index);
        // 목록에는 넣되, 준비가 끝나기 전에는 재생을 시작하지 않는다
        await player.setAudioSources([source]);
        if (gen != _generation) return;
        await _startPlaybackIfReady(gen);
      } else {
        _playlistMap.add(item.index);
        await player.addAudioSource(source);
        if (gen != _generation) return;
        if (_stalled && _warmOk) {
          // 앞 문장이 끝나 멈춰 있었다면 방금 넣은 문장부터 이어서 재생
          _stalled = false;
          await player.seek(Duration.zero, index: _playlistMap.length - 1);
          await player.play();
        }
      }
    } catch (e, st) {
      logger.e('재생 대기열 추가 실패', error: e, stackTrace: st);
      _error = '$e';
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- 재생 추적
  void _onPlayerIndex(int? playlistIndex) {
    if (playlistIndex == null ||
        playlistIndex < 0 ||
        playlistIndex >= _playlistMap.length) {
      return;
    }
    final index = _playlistMap[playlistIndex];
    if (index >= _items.length) return;

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
    onSentenceChanged?.call(_items[index]);
    _setStatus('재생 중 (${index + 1}/${_items.length})');
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
        ? '모두 읽었어요 (${_items.length}문장)'
        : '끝났어요 (${_items.length}문장 중 $failed개 실패)');
  }

  /// 음성 파일 하나의 이름.
  ///
  /// 이름만 보고 "몇 번째 문장을, 어떤 글로, 어떤 설정으로 만든 것인지" 를
  /// 알 수 있어야 한다. 그래야 앱을 껐다 켠 뒤에도 디스크만 훑어서 되찾는다.
  /// 전에는 만든 시각을 붙였고 짝은 메모리 안의 표에만 있었다 — 앱을 끄면
  /// 표가 사라져 전부 다시 만들었다.
  ///
  ///   s0007_a1b2c3d4_e5f6a7b8.wav
  ///        └ 문장 번호  └ 글자   └ 설정
  ///
  /// 설정이 이름에 들어가므로, 목소리나 속도를 바꾸면 다른 이름이 된다.
  /// 전에 만든 것은 지우지 않고 그대로 두므로 되돌리면 다시 곧바로 들린다.
  @visibleForTesting
  static String voiceFileName(int index, String text, String signature) =>
      's${index.toString().padLeft(4, '0')}_${tag(text)}_${tag(signature)}.wav';

  /// 지금 설정을 한 줄로. 소리에 영향을 주는 것만 넣는다.
  String get _signature =>
      '$_voice|$_lang|${_speed.toStringAsFixed(2)}|$_steps';

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
  /// 목록에서 없어진 글의 음성은 통째로 버린다. **남아 있는 글의 음성은
  /// 손대지 않는다** — 다시 들어갔을 때 곧바로 들리게 하려고 남겨두는 것이다.
  ///
  /// 다만 끝없이 늘 수는 없으므로 총량이 [voiceLimitBytes] 를 넘으면
  /// [oldestFirst] 순서대로, 즉 오래전에 넣은 글부터 음성을 버린다.
  /// [inUseSourceId] 는 지금 고른 글이라 마지막까지 남긴다.
  static Future<void> pruneVoice({
    required List<String> oldestFirst,
    String? inUseSourceId,
    int limitBytes = voiceLimitBytes,
  }) async {
    try {
      await _sweepLegacyCache();

      final root = Directory(await _voiceRootPath());
      if (!root.existsSync()) return;

      final live = oldestFirst.toSet();
      final sizes = <String, int>{};
      for (final entry in root.listSync()) {
        if (entry is! Directory) continue;
        final id = entry.path.split('/').last;
        if (!live.contains(id)) {
          entry.deleteSync(recursive: true);
          continue;
        }
        sizes[id] = _dirBytes(entry);
      }

      var total = sizes.values.fold<int>(0, (a, b) => a + b);
      if (total <= limitBytes) return;

      for (final id in oldestFirst) {
        if (total <= limitBytes) break;
        if (id == inUseSourceId) continue;
        final bytes = sizes[id];
        if (bytes == null || bytes == 0) continue;
        try {
          Directory('${root.path}/$id').deleteSync(recursive: true);
          total -= bytes;
          logger.i('음성 상한을 넘어 오래된 글의 음성을 버렸다: $id');
        } catch (_) {}
      }
    } catch (e, st) {
      logger.e('음성 폴더 정리 실패', error: e, stackTrace: st);
    }
  }

  /// 만들어둔 음성이 지금 몇 바이트인지
  static Future<int> voiceBytes() async {
    final root = Directory(await _voiceRootPath());
    if (!root.existsSync()) return 0;
    return _dirBytes(root);
  }

  /// 만들어둔 음성을 전부 버린다 (글은 남는다)
  static Future<void> clearVoice() async {
    final root = Directory(await _voiceRootPath());
    if (root.existsSync()) root.deleteSync(recursive: true);
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
  void dispose() {
    _generation++;
    player.dispose();
    // 음성 파일은 지우지 않는다. 앱을 다시 켤 때 cleanupTemp()가
    // 각 글의 마지막 재생 위치 파일만 남기고 정리한다.
    super.dispose();
  }
}
