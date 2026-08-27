import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/update_check.dart';

void main() {
  test('버전 비교 — 자리별로 숫자로 견준다', () {
    expect(isNewer('0.1.3', '0.1.2'), isTrue);
    expect(isNewer('0.2.0', '0.1.9'), isTrue);
    expect(isNewer('1.0.0', '0.9.9'), isTrue);
    // 글자로 견주면 '0.1.10' < '0.1.9' 가 되어 새 버전을 놓친다
    expect(isNewer('0.1.10', '0.1.9'), isTrue);
    expect(isNewer('0.1.2', '0.1.2'), isFalse);
    expect(isNewer('0.1.1', '0.1.2'), isFalse);
  });

  test('자리 수가 달라도 견준다 (모자란 자리는 0)', () {
    expect(isNewer('0.2', '0.1.9'), isTrue);
    expect(isNewer('0.1', '0.1.0'), isFalse);
    expect(isNewer('1', '0.9.9'), isTrue);
  });

  test('받은 양으로 게이지 비율을 낸다', () {
    expect(const DownloadProgress(50, 200).fraction, 0.25);
    // 전체 크기를 모르면 비율도 없다 — 게이지 대신 받은 양만 보여 준다
    expect(const DownloadProgress(50, 0).fraction, isNull);
  });
}
