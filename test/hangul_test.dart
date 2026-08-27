import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/hangul.dart';

void main() {
  test('풀어써진 한글을 도로 붙인다', () {
    // '위대한' 를 낱자로 풀어쓴 것 (7자 → 3자)
    expect(composeHangul('\u{110B}\u{1171}\u{1103}\u{1162}\u{1112}\u{1161}\u{11AB}'), '위대한');
    // '우리말' 를 낱자로 풀어쓴 것 (7자 → 3자)
    expect(composeHangul('\u{110B}\u{116E}\u{1105}\u{1175}\u{1106}\u{1161}\u{11AF}'), '우리말');
    // '옮김' 를 낱자로 풀어쓴 것 (6자 → 2자)
    expect(composeHangul('\u{110B}\u{1169}\u{11B1}\u{1100}\u{1175}\u{11B7}'), '옮김');
    // '(2차 편집최종)' 를 낱자로 풀어쓴 것 (17자 → 9자)
    expect(composeHangul('\u{0028}\u{0032}\u{110E}\u{1161}\u{0020}\u{1111}\u{1167}\u{11AB}\u{110C}\u{1175}\u{11B8}\u{110E}\u{116C}\u{110C}\u{1169}\u{11BC}\u{0029}'), '(2차 편집최종)');
  });

  test('풀어쓰기 전과 글자 수가 다르다는 것부터 확인한다', () {
    const nfd = '\u{110B}\u{1171}\u{1103}\u{1162}\u{1112}\u{1161}\u{11AB}';
    expect(nfd.length, 7);
    expect(composeHangul(nfd).length, 3);
  });

  test('이미 붙어 있는 글과 한글 아닌 글은 그대로 둔다', () {
    expect(composeHangul('위대한 유산'), '위대한 유산');
    expect(composeHangul('R5.md.docx'), 'R5.md.docx');
    expect(composeHangul(''), '');
  });
}
