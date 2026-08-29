/// 긴 글을 읽기 좋은 단위로 자르고, 글의 언어를 추정한다.
///
/// 문장 부호와 줄바꿈으로 나눈 뒤, 너무 짧은 조각은 최소 길이에 이를 때까지
/// 뒤 문장과 합쳐 덩어리 길이를 고르게 만든다.
///
/// 자막(SRT)은 예외다 — 이미 대사 단위로 끊겨 있어 다시 쪼개지 않는다.
library;

import 'package:suto_a/srt.dart';

const _enders = {'.', '!', '?', '。', '！', '？', '…', '‥'};
const _closers = {'"', "'", ')', ']', '}', '»', '”', '’', '』', '」'};
const _breakers = [',', '،', '、', ';', ':', '—', '-'];

// 한 덩어리의 목표 길이. 너무 짧으면 어색하게 끊기고, 너무 길면 모델이 문장을 건너뛴다.
const _targetMin = {'ko': 40, 'ja': 40};
const _targetMax = {'ko': 120, 'ja': 120};
const _defaultMin = 90;
const _defaultMax = 300;

int minLenForLang(String lang) => _targetMin[lang] ?? _defaultMin;
int maxLenForLang(String lang) => _targetMax[lang] ?? _defaultMax;

/// 글자 분포로 언어를 추정한다.
///
/// 'na'(미지정)로 넘기면 모델이 한국어를 인식하지 못해 문장을 통째로
/// 건너뛰는 일이 있어, 자동 모드에서는 이 함수로 실제 언어 코드를 정한다.
String detectLang(String text) {
  var hangul = 0, kana = 0, han = 0, cyrillic = 0, latin = 0, arabic = 0;

  for (final rune in text.runes) {
    if ((rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x3130 && rune <= 0x318F)) {
      hangul++;
    } else if ((rune >= 0x3040 && rune <= 0x309F) ||
        (rune >= 0x30A0 && rune <= 0x30FF)) {
      kana++;
    } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
      han++;
    } else if (rune >= 0x0400 && rune <= 0x04FF) {
      cyrillic++;
    } else if (rune >= 0x0600 && rune <= 0x06FF) {
      arabic++;
    } else if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    }
  }

  final total = hangul + kana + han + cyrillic + latin + arabic;
  if (total == 0) return 'en';
  if (hangul > total * 0.15) return 'ko';
  if (kana > 0) return 'ja';
  if (han > total * 0.3) return 'ja';
  if (cyrillic > total * 0.3) return 'ru';
  if (arabic > total * 0.3) return 'ar';
  return 'en';
}

/// 읽기 단위 목록을 만든다.
List<String> splitUnits(String text, String lang) {
  final minLen = minLenForLang(lang);
  final maxLen = maxLenForLang(lang);
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return const [];

  // 자막이면 사람이 이미 대사 하나씩 끊어 둔 것이다. 다시 쪼개지 않고
  // 한 대사를 한 칸으로 쓴다.
  if (looksLikeSrt(normalized)) {
    final cues = srtCues(normalized);
    if (cues.isNotEmpty) return cues;
  }

  // 1) 문장 단위로 자르고, 너무 긴 것은 다시 쪼갠다
  final pieces = <String>[];
  for (final s in _roughSplit(normalized)) {
    pieces.addAll(_splitLong(s, maxLen));
  }

  // 2) 짧은 조각을 뒤 조각과 합쳐 길이를 고르게 만든다
  final units = <String>[];
  var buf = '';
  for (final piece in pieces) {
    final candidate = buf.isEmpty ? piece : '$buf $piece';

    if (candidate.length <= maxLen) {
      buf = candidate;
    } else {
      if (buf.isNotEmpty) units.add(buf);
      buf = piece;
    }

    if (buf.length >= minLen && _endsWithMark(buf)) {
      units.add(buf);
      buf = '';
    }
  }

  if (buf.isNotEmpty) {
    // 마지막 조각이 너무 짧으면 앞 덩어리에 붙인다
    if (units.isNotEmpty &&
        buf.length < minLen ~/ 2 &&
        units.last.length + buf.length + 1 <= maxLen) {
      units[units.length - 1] = '${units.last} $buf';
    } else {
      units.add(buf);
    }
  }

  return units;
}

bool _endsWithMark(String s) {
  for (var i = s.length - 1; i >= 0; i--) {
    final ch = s[i];
    if (_closers.contains(ch)) continue;
    return _enders.contains(ch);
  }
  return false;
}

/// 문장 부호와 줄바꿈으로 1차 분리
List<String> _roughSplit(String text) {
  final out = <String>[];
  final buf = StringBuffer();

  void flush() {
    final s = buf.toString().trim();
    buf.clear();
    if (s.isNotEmpty) out.add(s);
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    buf.write(ch);

    if (ch == '\n') {
      flush();
      continue;
    }

    if (_enders.contains(ch)) {
      // 연속된 부호와 닫는 따옴표까지 함께 포함 ("...!?” 등)
      var j = i + 1;
      while (j < text.length &&
          (_enders.contains(text[j]) || _closers.contains(text[j]))) {
        buf.write(text[j]);
        j++;
      }
      i = j - 1;

      final isEnd = j >= text.length;
      final nextIsSpace = !isEnd && text[j].trim().isEmpty;
      if (isEnd || nextIsSpace) flush();
    }
  }
  flush();
  return out;
}

/// maxLen을 넘는 문장을 쉼표 → 띄어쓰기 → 강제 순으로 잘라낸다.
List<String> _splitLong(String s, int maxLen) {
  if (s.length <= maxLen) return [s];

  final out = <String>[];
  var rest = s;
  while (rest.length > maxLen) {
    final window = rest.substring(0, maxLen);
    var cut = -1;
    for (final c in _breakers) {
      final i = window.lastIndexOf(c);
      if (i > cut) cut = i;
    }
    if (cut < maxLen ~/ 3) cut = window.lastIndexOf(' ');
    if (cut < maxLen ~/ 3) cut = maxLen - 1;

    out.add(rest.substring(0, cut + 1).trim());
    rest = rest.substring(cut + 1).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out.where((e) => e.isNotEmpty).toList();
}

/// 엔진이 읽지 못하는 그림 문자(이모지 등)를 미리 제거
String cleanText(String text) {
  final buf = StringBuffer();
  for (final rune in text.runes) {
    // 이모지·기호 영역
    final isPictograph = (rune >= 0x1F000 && rune <= 0x1FAFF) ||
        (rune >= 0x2600 && rune <= 0x27BF) ||
        (rune >= 0x2190 && rune <= 0x21FF) ||
        (rune >= 0xFE00 && rune <= 0xFE0F);

    // 눈에 보이지 않는 서식 문자.
    //
    // 글자가 아닌데도 음성 모델의 글자 사전에 번호가 붙어 있어
    // (U+200E → 630, U+200B → 629) 그대로 넘기면 소리로 읽힌다.
    // 자막 파일은 대사마다 앞에 이런 표가 붙어 오는 일이 흔하다 —
    // 어떤 파일은 대사 1230개 중 1228개가 U+200E 로 시작했다.
    // 웹에서 복사해 온 글에도 곧잘 섞인다.
    //
    // U+2060(이음표)은 남긴다. 화면에 글을 그릴 때 낱말이 잘리지 않도록
    // byWord 가 일부러 끼워 넣는 것이라, 뜻이 있는 자리다.
    final isInvisible = rune == 0x00AD || // 안 보이는 연결선
        (rune >= 0x200B && rune <= 0x200F) || // 폭 없는 공백 · 좌우 표시
        (rune >= 0x202A && rune <= 0x202E) || // 쓰기 방향 묶기
        (rune >= 0x2066 && rune <= 0x2069) || // 쓰기 방향 가두기
        rune == 0xFEFF; // 파일 머리표(BOM)

    if (!isPictograph && !isInvisible) buf.writeCharCode(rune);
  }
  return buf.toString();
}
