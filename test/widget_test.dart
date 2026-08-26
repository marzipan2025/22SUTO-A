// 픽셀 카드 모서리가 실제로 깎여 나가는지만 확인한다.
// (앱 전체를 띄우는 테스트는 온디바이스 모델이 있어야 해서 여기서는 하지 않는다)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/pixel.dart';

void main() {
  test('모서리가 계단만큼 물려 나간다', () {
    const border = PixelBorder(unit: 4, steps: 2);
    final path = border.getOuterPath(const Rect.fromLTWH(0, 0, 100, 60));

    // 꼭짓점은 바깥으로 나가 있고, 계단만큼 안쪽으로 들어온 자리는 채워져 있다
    expect(path.contains(const Offset(1, 1)), isFalse);
    expect(path.contains(const Offset(99, 1)), isFalse);
    expect(path.contains(const Offset(1, 59)), isFalse);
    expect(path.contains(const Offset(99, 59)), isFalse);
    expect(path.contains(const Offset(10, 10)), isTrue);
    expect(path.contains(const Offset(50, 30)), isTrue);
  });
}
