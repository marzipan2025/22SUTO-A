import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/theme.dart';

const _joiner = '\u{2060}';

void main() {
  test('낱말 안쪽만 붙이고 띄어쓰기 자리는 놔둔다', () {
    final r = byWord('위대한 유산');
    expect(r.split(' ').length, 2, reason: '띄어쓰기는 그대로 남아야 한다');
    expect(r.replaceAll(_joiner, ''), '위대한 유산');
    expect(r.split(' ').first, '위$_joiner대$_joiner한');
  });

  test('풀어써진 한글의 낱자 사이는 벌리지 않는다', () {
    // 맥에서 온 파일 이름 모양 — 이걸 그대로 벌리면 'ㅇㅟㄷㅐ' 로 깨진다
    const nfd = '\u{110B}\u{1171}\u{1103}\u{1162}\u{1112}\u{1161}\u{11AB}\u{0020}\u{110B}\u{1172}\u{1109}\u{1161}\u{11AB}';
    expect(nfd.length, 13);

    final r = byWord(nfd);
    // 붙여진 글자 사이에만 이음표가 들어간다
    expect(r, '위${_joiner}대${_joiner}한 유${_joiner}산');
    // 낱자가 하나도 남아 있지 않아야 한다
    for (final u in r.codeUnits) {
      expect(u >= 0x1100 && u <= 0x11FF, isFalse,
          reason: '풀어써진 낱자가 남았다: U+\${u.toRadixString(16)}');
    }
  });

  test('띄어쓰기 없이 아주 긴 덩어리는 줄이 바뀔 자리를 남긴다', () {
    final long = '가' * 40;
    expect(byWord(long), long, reason: '손대면 화면 밖으로 삐져나간다');
  });
}
