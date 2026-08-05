import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:suto_a/narration_engine.dart';

const kIconDim = Color(0x2EFFFFFF);
const kIconNeutral = Color(0xFFB9C4CF);
const kIconPlaying = Color(0xFF4DA3FF); // 파란색은 "지금 재생 중"에만
const kIconFail = Color(0xFFFF7676);

/// 문장 상태 아이콘.
///
/// 대기: 흐린 빈 원 · 합성중: 차오르는 파이
/// 준비됨: 꽉 찬 원 + 재생 삼각형 · 재생중: 그 파란색 버전
/// 완료: 체크 · 실패: X
class StatusIcon extends StatefulWidget {
  const StatusIcon(this.status, {super.key, this.size = 20});

  final SentenceStatus status;
  final double size;

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
        duration: const Duration(milliseconds: 1800),
      )..repeat();
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

  @override
  Widget build(BuildContext context) {
    final painter = _StatusPainter(widget.status, 0);
    if (_controller == null) {
      return CustomPaint(
        size: Size.square(widget.size),
        painter: painter,
      );
    }
    return AnimatedBuilder(
      animation: _controller!,
      builder: (_, __) => CustomPaint(
        size: Size.square(widget.size),
        painter: _StatusPainter(widget.status, _controller!.value),
      ),
    );
  }
}

class _StatusPainter extends CustomPainter {
  _StatusPainter(this.status, this.progress);

  final SentenceStatus status;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 1;

    switch (status) {
      case SentenceStatus.pending:
        _ring(canvas, c, r, kIconDim);
        break;

      case SentenceStatus.synthesizing:
        _ring(canvas, c, r, const Color(0x20FFFFFF));
        // 가운데에서 바깥으로 차오르는 파이 (0.85까지 채우고 잠시 머문 뒤 반복)
        final t = (progress / 0.85).clamp(0.0, 1.0);
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          -math.pi / 2,
          2 * math.pi * t,
          true,
          Paint()..color = kIconNeutral,
        );
        break;

      case SentenceStatus.ready:
        _disc(canvas, c, r, kIconNeutral);
        _triangle(canvas, c, r);
        break;

      case SentenceStatus.playing:
        _disc(canvas, c, r, kIconPlaying);
        _triangle(canvas, c, r);
        break;

      case SentenceStatus.done:
        _ring(canvas, c, r, kIconDim);
        final p = Paint()
          ..color = const Color(0x40FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        final path = Path()
          ..moveTo(c.dx - r * 0.42, c.dy + r * 0.03)
          ..lineTo(c.dx - r * 0.12, c.dy + r * 0.32)
          ..lineTo(c.dx + r * 0.44, c.dy - r * 0.30);
        canvas.drawPath(path, p);
        break;

      case SentenceStatus.failed:
        _ring(canvas, c, r, kIconFail);
        final p = Paint()
          ..color = kIconFail
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round;
        final d = r * 0.42;
        canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), p);
        canvas.drawLine(c + Offset(d, -d), c + Offset(-d, d), p);
        break;
    }
  }

  void _ring(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  void _disc(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawCircle(c, r, Paint()..color = color);
  }

  void _triangle(Canvas canvas, Offset c, double r) {
    final path = Path()
      ..moveTo(c.dx - r * 0.22, c.dy - r * 0.36)
      ..lineTo(c.dx + r * 0.40, c.dy)
      ..lineTo(c.dx - r * 0.22, c.dy + r * 0.36)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF1A2129));
  }

  @override
  bool shouldRepaint(_StatusPainter old) =>
      old.status != status || old.progress != progress;
}
