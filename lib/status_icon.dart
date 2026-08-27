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
  AnimationController? _controller;

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
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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

    if (_controller == null) return boxed;
    // 만드는 중일 때만 천천히 깜박인다
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_controller!),
      child: boxed,
    );
  }
}
