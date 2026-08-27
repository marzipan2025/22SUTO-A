/// 풀어써진 한글을 도로 붙이는 일만 하는 곳.
///
/// 맥에서 만들어진 파일 이름은 한글이 낱자로 풀어써져 온다(NFD).
/// '위' 한 글자가 'ᄋ'(U+110B) + 'ᅱ'(U+1171) 두 글자인 식이다. 눈으로는
/// 같아 보여도 글자 수가 다르고, 글자 사이에 무언가를 끼우면 조합이
/// 끊겨 'ㅇㅟ' 처럼 풀어진 채로 그려진다. 합성기에 넘겨도 엉뚱하게 읽는다.
///
/// 다행히 한글 조합은 규칙만으로 된다 — 표를 들고 있을 필요가 없다.
/// (Unicode 3.12 Hangul Syllable Composition)
library;

const _lBase = 0x1100; // 첫소리 ᄀ
const _vBase = 0x1161; // 가운뎃소리 ᅡ
const _tBase = 0x11A7; // 끝소리 (11A8 부터가 실제 낱자, 11A7 은 '없음' 자리)
const _sBase = 0xAC00; // 조합된 '가'
const _lCount = 19;
const _vCount = 21;
const _tCount = 28;
const _nCount = _vCount * _tCount; // 588
const _sCount = _lCount * _nCount; // 11172

/// 풀어써진 한글을 붙여서 돌려준다. 한글이 아닌 글자는 그대로 둔다.
String composeHangul(String text) {
  // 낱자가 하나도 없으면 손대지 않는다 — 대개 이쪽이다
  var hasJamo = false;
  for (final u in text.codeUnits) {
    if (u >= _lBase && u <= 0x11FF) {
      hasJamo = true;
      break;
    }
  }
  if (!hasJamo) return text;

  final out = <int>[];
  for (final u in text.codeUnits) {
    if (out.isNotEmpty) {
      final last = out.last;

      // 첫소리 + 가운뎃소리 → 받침 없는 글자
      final l = last - _lBase;
      if (l >= 0 && l < _lCount) {
        final v = u - _vBase;
        if (v >= 0 && v < _vCount) {
          out[out.length - 1] = _sBase + (l * _vCount + v) * _tCount;
          continue;
        }
      }

      // 받침 없는 글자 + 끝소리 → 받침 있는 글자
      final s = last - _sBase;
      if (s >= 0 && s < _sCount && s % _tCount == 0) {
        final t = u - _tBase;
        if (t > 0 && t < _tCount) {
          out[out.length - 1] = last + t;
          continue;
        }
      }
    }
    out.add(u);
  }
  return String.fromCharCodes(out);
}
