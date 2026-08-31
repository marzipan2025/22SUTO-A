import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/sentence_splitter.dart';

void main() {
  // 한국어 상한은 120자다. 그것을 한두 자 넘긴 문장이 통째로 한 칸에
  // 담기는지 본다 — 예전에는 잘려서 "모른다." 만 다음 칸 머리로 넘어갔다.
  test('상한을 조금 넘긴 문장은 한 칸에 온전히 담긴다', () {
    const s = '정말 내 얘기를 꼭 듣고 싶다면, 내가 어디서 출생하고, 내 칠칠치 못한 '
        '어린 시절이 어땠고 부모님의 직업은 무엇이며 그들이 나를 낳기 전에 뭘 '
        '했다는 등의 데이비드 커퍼필드 식의 너저분한 이야기를 알고 싶을지 모른다. '
        '하지만 난 그런 얘기를 늘어놓고 싶은 생각은 조금도 없다.';

    final units = splitUnits(s, 'ko');

    // 첫 문장이 쪼개지지 않았다
    expect(units.first, contains('알고 싶을지 모른다.'));
    // 어느 칸도 '모른다.' 로 시작하지 않는다
    expect(units.any((u) => u.startsWith('모른다')), isFalse);
  });

  test('칸은 모두 종결 부호로 끝난다 — 얼버무리지 않도록', () {
    const s = '정말 내 얘기를 꼭 듣고 싶다면, 내가 어디서 출생하고, 내 칠칠치 못한 '
        '어린 시절이 어땠고 부모님의 직업은 무엇이며 그들이 나를 낳기 전에 뭘 '
        '했다는 등의 데이비드 커퍼필드 식의 너저분한 이야기를 알고 싶을지 모른다.';

    for (final u in splitUnits(s, 'ko')) {
      expect(u.endsWith('.'), isTrue, reason: '종결 부호 없이 끝난 칸: $u');
    }
  });

  test('정말 긴 문장은 여전히 잘린다 — 꼬리를 짧게 남기지 않은 채로', () {
    final s = '${'가나다라마바사아자차 ' * 40}끝.'; // 400자가 넘는다
    final units = splitUnits(s, 'ko');

    expect(units.length, greaterThan(1));
    // 조각 하나만 덜렁 남는 일이 없다
    for (final u in units) {
      expect(u.length, greaterThan(120 ~/ 4), reason: '너무 짧은 칸: $u');
    }
  });
}
