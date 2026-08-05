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
    this.steps = 8,
  });

  String voice;
  String lang;
  double speed;
  int steps;

  static const voices = ['M1', 'M2', 'M3', 'M4', 'M5', 'F1', 'F2', 'F3', 'F4', 'F5'];

  /// 값이 이상해도 앱이 멈추지 않도록 허용 범위로 다듬는다
  void clamp() {
    if (!voices.contains(voice)) voice = 'M1';
    if (lang.isEmpty) lang = 'auto';
    if (speed.isNaN) speed = 1.05;
    speed = speed.clamp(0.7, 2.0);
    steps = steps.clamp(5, 12);
  }

  Map<String, dynamic> toJson() =>
      {'voice': voice, 'lang': lang, 'speed': speed, 'steps': steps};

  static Settings fromJson(Map<String, dynamic> j) {
    final s = Settings(
      voice: j['voice'] is String ? j['voice'] as String : 'M1',
      lang: j['lang'] is String ? j['lang'] as String : 'auto',
      speed: (j['speed'] is num) ? (j['speed'] as num).toDouble() : 1.05,
      steps: (j['steps'] is num) ? (j['steps'] as num).toInt() : 8,
    );
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
