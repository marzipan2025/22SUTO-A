import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/sentence_splitter.dart';
import 'package:suto_a/srt.dart';

const sample = '''
1
00:00:01,000 --> 00:00:03,400
안녕하세요, 만나서 반갑습니다.

2
00:00:03,500 --> 00:00:06,000
오늘은 날씨가 참 좋네요.
바람도 선선하고요.

3
00:00:06,100 --> 00:00:08,000
<i>그러게요.</i>
''';

void main() {
  test('자막인 줄 알아본다', () {
    expect(looksLikeSrt(sample), isTrue);
  });

  test('여느 글은 자막으로 보지 않는다', () {
    expect(looksLikeSrt('그는 문을 열었다. 밖은 이미 어두웠다.'), isFalse);
    // 글 속에 화살표가 우연히 섞여도 자막이 아니다
    expect(looksLikeSrt('가는 길 --> 오는 길 을 적어 두었다.'), isFalse);
  });

  test('대사 하나가 한 칸이다', () {
    expect(srtCues(sample), [
      '안녕하세요, 만나서 반갑습니다.',
      // 두 줄짜리 대사는 한 줄로 잇는다
      '오늘은 날씨가 참 좋네요. 바람도 선선하고요.',
      '그러게요.',
    ]);
  });

  test('꾸밈표와 자리표는 걷어낸다', () {
    const s = '''
1
00:00:01,000 --> 00:00:02,000
{\\an8}<font color="#fff">위쪽 자막</font>
''';
    expect(srtCues(s), ['위쪽 자막']);
  });

  test('빈 줄 없이 붙어 있어도 갈라낸다', () {
    const s = '''
1
00:00:01,000 --> 00:00:02,000
첫 대사
2
00:00:02,000 --> 00:00:03,000
둘째 대사
''';
    expect(srtCues(s), ['첫 대사', '둘째 대사']);
  });

  test('splitUnits 가 자막을 대사 단위로 돌려준다', () {
    // 문장으로 다시 쪼개거나 짧은 것끼리 합치지 않는다
    expect(splitUnits(sample, 'ko').length, 3);
  });

  test('자막이 아니면 여느 때처럼 문장으로 나눈다', () {
    const prose = '그는 문을 열었다. 밖은 이미 어두웠다. 바람이 찼다.';
    expect(splitUnits(prose, 'ko'), isNot(hasLength(0)));
    expect(srtCues(prose), isEmpty);
  });

  _invisible();
}

void _invisible() {
  test('보이지 않는 서식 문자는 걷어낸다', () {
    // 자막 대사 앞에 흔히 붙는 좌우 표시(U+200E). 사전에 번호가 있어
    // 그대로 두면 소리로 읽힌다.
    expect(cleanText('\u200E옛날 옛적에'), '옛날 옛적에');
    expect(cleanText('가\u200B나\uFEFF다\u00AD라'), '가나다라');
    expect(cleanText('\u202A오른쪽\u202C'), '오른쪽');
    expect(cleanText('\u2066가둠\u2069'), '가둠');
    // 이음표는 남는다 — 화면에서 낱말이 잘리지 않게 하는 자리다
    expect(cleanText('낱\u2060말'), '낱\u2060말');
  });

  test('자막을 대사로 나눌 때도 함께 걷힌다', () {
    const s = '''
1
00:00:01,000 --> 00:00:02,000
\u200E첫 대사

2
00:00:02,000 --> 00:00:03,000
\u200E둘째 대사
''';
    final units = splitUnits(cleanText(s).trim(), 'ko');
    expect(units, ['첫 대사', '둘째 대사']);
    expect(units.where((u) => u.contains('\u200E')), isEmpty);
  });
}
