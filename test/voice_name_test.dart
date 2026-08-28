import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/narration_engine.dart';

/// 음성 파일 이름이 곧 그 파일의 신원이다. 앱을 껐다 켠 뒤 디스크만 훑어서
/// 되찾으려면, 같은 입력에서 늘 같은 이름이 나와야 한다.
void main() {
  const sig = 'F2|ko|1.00|6';

  test('같은 문장·같은 설정이면 늘 같은 이름', () {
    final a = NarrationEngine.voiceFileName(7, '첫 번째 문장입니다.', sig);
    final b = NarrationEngine.voiceFileName(7, '첫 번째 문장입니다.', sig);
    expect(a, b);
    expect(a, endsWith('.wav'));
    expect(a, startsWith('s0007_'));
  });

  test('문장 번호가 다르면 이름이 다르다', () {
    expect(NarrationEngine.voiceFileName(1, '같은 글', sig),
        isNot(NarrationEngine.voiceFileName(2, '같은 글', sig)));
  });

  test('글이 바뀌면 이름이 다르다 — 옛 음성을 잘못 쓰지 않는다', () {
    expect(NarrationEngine.voiceFileName(1, '가나다', sig),
        isNot(NarrationEngine.voiceFileName(1, '가나닥', sig)));
  });

  test('설정이 바뀌면 이름이 다르다', () {
    final f2 = NarrationEngine.voiceFileName(1, '문장', 'F2|ko|1.00|6');
    expect(f2, isNot(NarrationEngine.voiceFileName(1, '문장', 'M1|ko|1.00|6')));
    expect(f2, isNot(NarrationEngine.voiceFileName(1, '문장', 'F2|ko|1.21|6')));
    expect(f2, isNot(NarrationEngine.voiceFileName(1, '문장', 'F2|ko|1.00|5')));
  });

  test('번호는 자릿수를 맞춰 붙는다 — 이름 길이가 들쭉날쭉하지 않게', () {
    expect(NarrationEngine.voiceFileName(0, 'x', sig), startsWith('s0000_'));
    expect(NarrationEngine.voiceFileName(123, 'x', sig), startsWith('s0123_'));
  });

  test('표는 여덟 자리 열여섯진수', () {
    final t = NarrationEngine.tag('아무 글');
    expect(t.length, 8);
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(t), isTrue);
  });

  test('한글이 풀어써진 것과 붙은 것은 다른 표다', () {
    // 화면에 그릴 때 붙이므로, 저장하는 글도 붙은 것이어야 짝이 맞는다
    expect(NarrationEngine.tag('위'), isNot(NarrationEngine.tag('위')));
  });
}
