import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 앱을 껐다 켜도 유지되는 설정.
///
/// 새 플러그인을 붙이지 않고 앱 전용 폴더에 JSON 파일로 저장한다.
class Settings {
  Settings({
    this.voice = 'M1',
    this.lang = 'auto',
    this.speed = 1.05,
    // 공식 문서의 production 기본값은 5단계("balanced"). 2단계는 "미리보기용"이라고
    // 문서에 적혀 있고, 실제로 폰에서 들어봐도 로봇처럼 뭉개져서 못 쓸 정도였다.
    // 8단계는 5단계보다 확산 계산이 더 걸리는 데 비해 체감 이득은 크지 않았다.
    this.steps = 6,
  });

  String voice;
  String lang;
  double speed;
  int steps;

  /// 마지막으로 **실제로 만들어 낸** 목소리.
  ///
  /// [voice] 는 '다음에 만들 때 쓸 목소리' 이고 이것은 '마지막으로 쓴
  /// 목소리' 다. 둘은 갈린다 — REMAKE 로 문장 하나만 다른 목소리로 다시
  /// 만들면 설정은 그대로인데 마지막으로 쓴 것은 그것이다. 켤 때의 첫
  /// 화면에 세우는 얼굴이 이걸 따른다.
  ///
  /// 한 번도 만든 적이 없으면 null 이다. 그때는 [voice] 를 쓴다.
  String? lastVoice;

  static const voices = ['M1', 'M2', 'M3', 'M4', 'M5', 'F1', 'F2', 'F3', 'F4', 'F5'];

  /// 값이 이상해도 앱이 멈추지 않도록 허용 범위로 다듬는다
  void clamp() {
    if (!voices.contains(voice)) voice = 'M1';
    if (lang.isEmpty) lang = 'auto';
    if (speed.isNaN) speed = 1.05;
    speed = speed.clamp(0.7, 2.0);
    // 하한은 2까지 열어둔다(실험해볼 수 있게) — 다만 기본값은 5. 2는 실사용 품질이 아니다.
    steps = steps.clamp(2, 12);
  }

  Map<String, dynamic> toJson() => {
        'voice': voice,
        'lang': lang,
        'speed': speed,
        'steps': steps,
        'lastVoice': lastVoice,
      };

  static Settings fromJson(Map<String, dynamic> j) {
    final s = Settings(
      voice: j['voice'] is String ? j['voice'] as String : 'M1',
      lang: j['lang'] is String ? j['lang'] as String : 'auto',
      speed: (j['speed'] is num) ? (j['speed'] as num).toDouble() : 1.05,
      steps: (j['steps'] is num) ? (j['steps'] as num).toInt() : 6,
    );
    final last = j['lastVoice'];
    if (last is String && voices.contains(last)) s.lastVoice = last;
    s.clamp();
    return s;
  }
}

Future<File> _settingsFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/settings.json');
}

/// 저장된 설정을 읽는다. 파일이 없거나 깨졌으면 기본값.
Future<Settings> loadSettings() async {
  try {
    final f = await _settingsFile();
    if (!f.existsSync()) return Settings();
    final data = jsonDecode(await f.readAsString());
    if (data is Map<String, dynamic>) return Settings.fromJson(data);
  } catch (_) {
    // 깨진 파일은 무시하고 기본값 사용
  }
  return Settings();
}

/// 쓰다가 중단돼도 기존 설정이 깨지지 않도록 임시 파일을 거쳐 교체한다.
Future<void> saveSettings(Settings s) async {
  try {
    final f = await _settingsFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(s.toJson()));
    await tmp.rename(f.path);
  } catch (_) {}
}
