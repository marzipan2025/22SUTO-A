import 'package:flutter/material.dart';
import 'package:suto_a/narration_engine.dart';
import 'package:suto_a/pixel.dart';
import 'package:suto_a/theme.dart';

/// 상태 그림이 차지하는 가로 자리. 어떤 상태가 와도 글이 밀리지 않도록
/// 가장 넓은 그림(체크)에 맞춰 둔다.
double statusIconWidth(double cell) => kGlyphCheck.widthAt(cell);

/// 문장 상태에 맞는 카드 색 한 벌.
CardSkin skinFor(SentenceStatus status) {
  switch (status) {
    case SentenceStatus.pending:
      return kSkinPending;
    case SentenceStatus.synthesizing:
      return kSkinSynth;
    case SentenceStatus.ready:
      return kSkinReady;
    case SentenceStatus.playing:
      return kSkinPlaying;
    case SentenceStatus.done:
      return kSkinDone;
    case SentenceStatus.failed:
      return kSkinFailed;
  }
}

/// 문장 상태 아이콘 — 전부 격자 위에 찍는다.
///
/// 대기: 작은 점 · 합성 중: 깜박이는 덩어리 · 준비됨/재생 중: 삼각형
/// 완료: 체크 · 실패: 가위표
///
/// 카드 색이 상태를 이미 말해 주므로, 아이콘은 카드 글자색을 그대로 쓴다.
class StatusIcon extends StatefulWidget {
  const StatusIcon(this.status, {super.key, required this.color, this.cell = 2});

  final SentenceStatus status;
  final Color color;

  /// 격자 한 칸의 크기
  final double cell;

  @override
  State<StatusIcon> createState() => _StatusIconState();
}

class _StatusIconState extends State<StatusIcon>
    with SingleTickerProviderStateMixin {
  /// 깜박임을 도맡는 시계. **State 가 사는 동안 하나뿐이다.**
  ///
  /// 전에는 '만드는 중' 이 끝나면 버리고 다시 시작할 때 새로 만들었다.
  /// 그런데 SingleTickerProviderStateMixin 은 한 State 에 시계를 하나만
  /// 허락한다 — 두 번째로 만드는 순간 단언이 터진다.
  ///
  /// 목록은 셀을 재활용한다. 같은 State 가 스크롤을 따라 여러 문장을
  /// 번갈아 맡으므로, '만드는 중' 을 두 번째로 만나는 일이 예사다.
  /// 긴 글을 합성하며 훑어 내리면 곧 걸리고, 그 셀 하나만 빨갛게 죽었다.
  ///
  /// 이제는 만들지도 버리지도 않고 **켜고 끄기만** 한다.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool get _animated => widget.status == SentenceStatus.synthesizing;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusIcon old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _sync();
  }

  void _sync() {
    if (_animated) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1; // 멈춘 뒤에는 또렷하게 둔다
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  PixelGlyph get _glyph {
    switch (widget.status) {
      case SentenceStatus.pending:
        return kGlyphStandby;
      case SentenceStatus.synthesizing:
        return kGlyphDot;
      case SentenceStatus.ready:
      case SentenceStatus.playing:
        return kGlyphPlay;
      case SentenceStatus.done:
        return kGlyphCheck;
      case SentenceStatus.failed:
        return kGlyphFailed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = PixelIcon(_glyph, cell: widget.cell, color: widget.color);

    // 자리를 항상 같은 크기로 잡아 둔다 — 상태가 바뀌어도 글이 밀리지 않는다.
    // 가장 넓은 그림과 가장 높은 그림에 맞춘 자리 안에서 가운데로 세운다.
    final boxed = SizedBox(
      width: statusIconWidth(widget.cell),
      height: kGlyphPlay.heightAt(widget.cell),
      child: Align(alignment: Alignment.centerLeft, child: icon),
    );

    if (!_animated) return boxed;
    // 만드는 중일 때만 천천히 깜박인다
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_controller),
      child: boxed,
    );
  }
}
