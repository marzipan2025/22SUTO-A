import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:suto_a/helper.dart';

/// 소스가 어디서 왔는지
enum SourceKind {
  clipboard, // 붙여넣기 · 다른 앱에서 공유받은 글
  file, // 문서 파일에서 뽑아낸 글
}

/// 입력 화면 목록에 쌓이는 항목 하나.
///
/// 파일은 경로가 아니라 **뽑아낸 텍스트를 그대로 들고 있는다**.
/// 원본이 지워지거나 옮겨져도, 앱을 다시 켜서 접근 권한이 풀려도
/// 목록이 깨지지 않게 하기 위해서다.
class SourceItem {
  SourceItem({
    required this.id,
    required this.kind,
    required this.text,
    this.fileName,
    required this.addedAt,
    this.lastIndex = 0,
    this.lastFilePath,
  });

  final String id;
  final SourceKind kind;
  final String text;
  final String? fileName; // kind == file 일 때만 채운다
  final DateTime addedAt;

  /// 마지막으로 재생하던 문장 번호. 앱을 꺼도 남는다.
  int lastIndex;

  /// 그 문장의 음성 파일 경로.
  /// 앱을 다시 켰을 때 이 한 개만 남기고 나머지 대기열은 지운다.
  String? lastFilePath;

  /// 셀에 보여줄 문구 — 파일은 파일명, 붙여넣기는 본문 앞부분
  String get label {
    if (kind == SourceKind.file && (fileName?.isNotEmpty ?? false)) {
      return fileName!;
    }
    // 줄바꿈이 많으면 미리보기가 들쭉날쭉해지므로 공백 한 칸으로 눌러준다
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'text': text,
        'fileName': fileName,
        'addedAt': addedAt.toIso8601String(),
        'lastIndex': lastIndex,
        'lastFilePath': lastFilePath,
      };

  static SourceItem? fromJson(Map<String, Object?> j) {
    final text = j['text']?.toString();
    if (text == null || text.isEmpty) return null;
    return SourceItem(
      id: j['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
      kind: j['kind']?.toString() == 'file' ? SourceKind.file : SourceKind.clipboard,
      text: text,
      fileName: j['fileName']?.toString(),
      addedAt:
          DateTime.tryParse(j['addedAt']?.toString() ?? '') ?? DateTime.now(),
      lastIndex: (j['lastIndex'] as num?)?.toInt() ?? 0,
      lastFilePath: j['lastFilePath']?.toString(),
    );
  }

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

Future<File> _storeFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/sources.json');
}

/// 저장해 둔 목록을 불러온다. 파일이 없거나 깨졌으면 빈 목록.
Future<List<SourceItem>> loadSources() async {
  try {
    final f = await _storeFile();
    if (!await f.exists()) return [];
    final raw = jsonDecode(await f.readAsString());
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((m) => SourceItem.fromJson(m.map((k, v) => MapEntry('$k', v))))
        .whereType<SourceItem>()
        .toList();
  } catch (e, st) {
    logger.e('소스 목록 불러오기 실패', error: e, stackTrace: st);
    return [];
  }
}

Future<void> saveSources(List<SourceItem> items) async {
  try {
    final f = await _storeFile();
    await f.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
  } catch (e, st) {
    logger.e('소스 목록 저장 실패', error: e, stackTrace: st);
  }
}
