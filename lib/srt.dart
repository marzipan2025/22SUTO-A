/// SRT 자막을 대사 단위로 읽는다.
///
/// 자막은 이미 사람이 대사 하나씩 끊어 둔 글이다. 그것을 다시 문장으로
/// 쪼개면 애써 맞춰 둔 끊김이 흐트러지므로, **한 대사를 한 칸으로** 쓴다.
///
/// 파일을 고르는 길은 여느 문서와 같다 — 네이티브는 확장자를 모르는
/// 파일을 그냥 글로 읽어 오고, 줄바꿈도 그대로 남긴다. 자막인지 아닌지는
/// 글 자체를 보고 여기서 가린다. 그래야 재생하는 쪽과 목록 띠를 그리는
/// 쪽이 따로 알 필요 없이 같은 결과를 본다 (둘 다 splitUnits 를 거친다).
library;

/// `00:00:01,000 --> 00:00:03,400` 꼴의 시각 줄.
/// 쉼표 대신 마침표를 쓰는 것(WebVTT 투)과 시가 한 자리인 것도 받는다.
final _stamp = RegExp(
    r'^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}');

/// 번호만 있는 줄
final _indexOnly = RegExp(r'^\d+$');

/// `<i>` `</font>` 같은 꾸밈표
final _tag = RegExp(r'</?[a-zA-Z][^>]*>');

/// `{\an8}` 처럼 자리를 지정하는 표. 역슬래시로 시작하는 것만 걷어낸다 —
/// 그냥 중괄호는 대사에 그대로 나올 수 있다.
final _override = RegExp(r'\{\\[^}]*\}');

/// 자막 파일인가.
///
/// 앞머리에 시각 줄이 있고 그런 줄이 둘 이상이어야 한다. 여느 글에
/// `-->` 가 우연히 섞였다고 글 전체가 자막으로 읽히면 안 되기 때문이다.
bool looksLikeSrt(String text) {
  final lines = _lines(text);
  var stamps = 0;
  var firstAt = -1;
  for (var i = 0; i < lines.length; i++) {
    if (!_stamp.hasMatch(lines[i])) continue;
    if (firstAt < 0) firstAt = _contentIndexOf(lines, i);
    stamps++;
    if (stamps >= 2 && firstAt >= 0 && firstAt <= 3) return true;
  }
  return false;
}

/// 대사만 차례대로 뽑는다. 자막이 아니면 빈 목록.
List<String> srtCues(String text) {
  final lines = _lines(text);
  final cues = <String>[];

  var i = 0;
  while (i < lines.length) {
    if (!_stamp.hasMatch(lines[i])) {
      i++;
      continue;
    }
    i++; // 시각 줄을 지난다

    final buf = <String>[];
    while (i < lines.length) {
      final line = lines[i];
      if (line.isEmpty) break; // 대사 끝
      if (_stamp.hasMatch(line)) break; // 빈 줄 없이 다음 대사가 붙었다
      // 번호 줄 다음이 시각 줄이면 그건 다음 대사의 머리다
      if (_indexOnly.hasMatch(line) &&
          i + 1 < lines.length &&
          _stamp.hasMatch(lines[i + 1])) {
        break;
      }
      buf.add(line);
      i++;
    }

    final cue = _tidy(buf.join(' '));
    if (cue.isNotEmpty) cues.add(cue);
  }
  return cues;
}

List<String> _lines(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split('\n')
    .map((l) => l.trim())
    .toList();

/// [at] 이 몇 번째 '내용 있는 줄' 인지 (빈 줄은 세지 않는다)
int _contentIndexOf(List<String> lines, int at) {
  var n = 0;
  for (var i = 0; i < at; i++) {
    if (lines[i].isNotEmpty) n++;
  }
  return n;
}

String _tidy(String s) => s
    .replaceAll(_override, ' ')
    .replaceAll(_tag, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
