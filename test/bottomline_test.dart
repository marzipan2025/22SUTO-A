// characters 확장은 flutter 가 다시 내보낸다 (main.dart 도 같은 경로로 쓴다)
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 화면 맨 아래 한 줄이 어떤 글자를 고르는지.
/// (_bottomLine 과 같은 규칙 — 위젯을 띄우지 않고 규칙만 확인한다)
String pick(String status, String? title) {
  if (!status.startsWith('재생 중')) return status;
  return title ?? status;
}

String cut(String s, {int limit = 20}) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return t;
  return t.characters.length > limit ? '${t.characters.take(limit)}…' : t;
}

void main() {
  test("'재생 중' 자리에는 글 이름이 온다", () {
    expect(pick('재생 중', '01__편지1.txt'), '01__편지1.txt');
    expect(pick('재생 중 (3/83)', '01__편지1.txt'), '01__편지1.txt');
  });

  test('알려 줄 게 있는 상태와 오류는 그대로 보여 준다', () {
    expect(pick('첫 문장 만드는 중...', '아무개.txt'), '첫 문장 만드는 중...');
    expect(pick('정지했어요.', '아무개.txt'), '정지했어요.');
    expect(pick('모두 읽었어요 (83문장)', '아무개.txt'), '모두 읽었어요 (83문장)');
  });

  test('이름을 못 찾으면 상태를 그대로 둔다', () {
    expect(pick('재생 중 (1/1)', null), '재생 중 (1/1)');
  });

  test('스무 자를 넘으면 줄인다', () {
    expect(cut('짧은 이름.txt'), '짧은 이름.txt');
    expect(cut('가나다라마바사아자차카타파하가나다라마바'), '가나다라마바사아자차카타파하가나다라마바');
    expect(cut('가나다라마바사아자차카타파하가나다라마바사'),
        '가나다라마바사아자차카타파하가나다라마바…');
    // 줄바꿈이 섞인 붙여넣기는 한 줄로 눌러서 센다
    expect(cut('첫 줄\n\n둘째 줄'), '첫 줄 둘째 줄');
  });
}
