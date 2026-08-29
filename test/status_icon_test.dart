import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suto_a/narration_engine.dart';
import 'package:suto_a/status_icon.dart';
import 'package:suto_a/theme.dart';

void main() {
  testWidgets('만드는 중을 두 번 만나도 셀이 죽지 않는다', (tester) async {
    // 목록이 셀을 재활용하면 같은 State 가 여러 문장을 번갈아 맡는다.
    // 그때 '만드는 중' 이 두 번 오는데, 전에는 여기서 시계를 다시 만들다
    // 단언이 터져 그 셀만 빨갛게 죽었다.
    Widget at(SentenceStatus s) => MaterialApp(
          home: Scaffold(
            body: StatusIcon(s, color: kYellow, cell: 2.5),
          ),
        );

    await tester.pumpWidget(at(SentenceStatus.synthesizing));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(at(SentenceStatus.ready));
    await tester.pump(const Duration(milliseconds: 100));

    // 두 번째 '만드는 중' — 여기서 터졌다
    await tester.pumpWidget(at(SentenceStatus.synthesizing));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);

    // 몇 번을 오가도 괜찮아야 한다
    for (final s in [
      SentenceStatus.done,
      SentenceStatus.synthesizing,
      SentenceStatus.pending,
      SentenceStatus.synthesizing,
    ]) {
      await tester.pumpWidget(at(s));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    }
  });
}
