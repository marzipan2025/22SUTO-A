import 'package:flutter/material.dart';

/// 이 앱의 픽셀 표현을 모아둔 곳.
///
/// 화면에 보이는 "각진 것"은 전부 여기서 나온다.
/// * [PixelIcon] — 밑그림(SVG)에서 옮겨온 아이콘
/// * [PixelBorder] — 모서리가 계단처럼 깎인 카드 테두리
///
/// 글자는 여기를 거치지 않는다. 영문·숫자는 Panchang, 한글 본문은
/// 지금 쓰던 글꼴 그대로다.

/// 밑그림(SVG)에서 옮겨온 도형 한 장.
///
/// 격자로 다시 뜨지 않는다 — 좌표를 그대로 들고 있다가 그릴 때 크기만
/// 바꾼다. 격자로 옮기면 밑그림의 계단이 눈금에 딱 떨어지지 않는 자리에서
/// 모양이 뭉개진다.
///
/// 좌표는 24칸짜리 밑그림을 기준으로 하고, 원점은 잉크의 왼쪽 위 모서리다.
/// [width]·[height] 는 잉크가 차지하는 크기다.
class PixelGlyph {
  const PixelGlyph({
    required this.width,
    required this.height,
    required this.paths,
    this.scale = 1,
  });

  final double width;
  final double height;
  final List<GlyphPath> paths;

  /// 이 그림만 따로 줄이거나 키울 때. 밑그림은 건드리지 않고 크기만 바꾼다.
  final double scale;

  /// 밑그림의 두 단위를 한 칸으로 친다 — 앱 전체가 이 눈금으로 크기를 잡는다.
  double _k(double cell) => cell / 2 * scale;

  double widthAt(double cell) => width * _k(cell);
  double heightAt(double cell) => height * _k(cell);

  /// 같은 밑그림을 크기만 바꿔 쓰고 싶을 때
  PixelGlyph scaled(double factor) => PixelGlyph(
        width: width,
        height: height,
        paths: paths,
        scale: scale * factor,
      );
}

/// 채워 그리는 도형 하나. [rings] 는 x, y 가 번갈아 든 점 목록의 목록이다.
class GlyphPath {
  const GlyphPath(this.rings, {this.evenOdd = false});

  final List<List<double>> rings;

  /// 안쪽에 구멍을 내는 도형인지 (SVG 의 fill-rule="evenodd")
  final bool evenOdd;

  Path toPath() {
    final p = Path()
      ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    for (final ring in rings) {
      p.moveTo(ring[0], ring[1]);
      for (var i = 2; i < ring.length; i += 2) {
        p.lineTo(ring[i], ring[i + 1]);
      }
      p.close();
    }
    return p;
  }
}

/// 왼쪽 화살표 — 진행 화면의 뒤로 가기
const kGlyphBack = PixelGlyph(
  width: 18,
  height: 14,
  paths: [
    GlyphPath([
      [6, 2, 8, 2, 8, 0, 6, 0, 6, 2],
    ]),
    GlyphPath([
      [4, 4, 4, 2, 6, 2, 6, 4, 4, 4],
    ]),
    GlyphPath([
      [4, 10, 4, 8, 18, 8, 18, 6, 4, 6, 4, 4, 2, 4, 2, 6, 0, 6, 0, 8, 2, 8, 2, 10, 4, 10],
    ]),
    GlyphPath([
      [6, 12, 6, 10, 4, 10, 4, 12, 6, 12],
      [6, 12, 6, 14, 8, 14, 8, 12, 6, 12],
    ], evenOdd: true),
  ],
);

/// 손잡이 두 개 — 설정
const kGlyphSettings = PixelGlyph(
  width: 18,
  height: 18,
  paths: [
    GlyphPath([
      [16, 2, 16, 0, 12, 0, 12, 2, 10, 2, 10, 6, 12, 6, 12, 8, 16, 8, 16, 6, 18, 6, 18, 2, 16, 2],
      [16, 2, 16, 6, 12, 6, 12, 2, 16, 2],
    ], evenOdd: true),
    GlyphPath([
      [8, 5, 8, 3, 2, 3, 2, 5, 8, 5],
    ]),
    GlyphPath([
      [16, 15, 16, 13, 10, 13, 10, 15, 16, 15],
    ]),
    GlyphPath([
      [6, 10, 6, 12, 2, 12, 2, 10, 6, 10],
    ]),
    GlyphPath([
      [0, 12, 2, 12, 2, 16, 0, 16, 0, 12],
    ]),
    GlyphPath([
      [6, 16, 6, 18, 2, 18, 2, 16, 6, 16],
    ]),
    GlyphPath([
      [6, 16, 8, 16, 8, 12, 6, 12, 6, 16],
    ]),
  ],
);

/// 재생 삼각형.
///
/// 밑그림에서 [kGlyphDot] 보다 크게 그려져 있다. 목록과 대시보드에서
/// 늘 그 옆에 나란히 서므로 덩어리 높이를 맞춰 둔다 (14 → 10).
const kGlyphPlay = PixelGlyph(
  scale: 10 / 14,
  width: 12,
  height: 14,
  paths: [
    GlyphPath([
      [0, 0, 0, 14, 4, 14, 4, 12, 7, 12, 7, 10, 10, 10, 10, 8, 12, 8, 12, 6, 10, 6, 10, 4, 7, 4, 7, 2, 4, 2, 4, 0, 0, 0],
      [4, 2, 4, 4, 7, 4, 7, 6, 10, 6, 10, 8, 7, 8, 7, 10, 4, 10, 4, 12, 2, 12, 2, 2, 4, 2],
    ], evenOdd: true),
    GlyphPath([
      [2, 2, 7, 2, 7, 12, 2, 12],
    ]),
    GlyphPath([
      [5, 4, 10, 4, 10, 10, 5, 10],
    ]),
  ],
);

/// 채운 덩어리 — 합성 중
const kGlyphDot = PixelGlyph(
  width: 10,
  height: 10,
  paths: [
    GlyphPath([
      [8, 0, 8, 2, 10, 2, 10, 8, 8, 8, 8, 10, 2, 10, 2, 8, 0, 8, 0, 2, 2, 2, 2, 0, 8, 0],
    ]),
  ],
);

/// 가지런한 두 줄 — 아직 차례가 오지 않음
const kGlyphStandby = PixelGlyph(
  width: 10,
  height: 6,
  paths: [
    GlyphPath([
      [0, 0, 10, 0, 10, 2, 0, 2],
    ]),
    GlyphPath([
      [0, 4, 10, 4, 10, 6, 0, 6],
    ]),
  ],
);

/// 어긋난 두 줄 — 만들기 실패
const kGlyphFailed = PixelGlyph(
  width: 10,
  height: 8,
  paths: [
    GlyphPath([
      [0, 2, 5, 2, 5, 4, 0, 4],
    ]),
    GlyphPath([
      [0, 6, 5, 6, 5, 8, 0, 8],
    ]),
    GlyphPath([
      [5, 0, 10, 0, 10, 2, 5, 2],
    ]),
    GlyphPath([
      [5, 4, 10, 4, 10, 6, 5, 6],
    ]),
  ],
);

/// 체크 — 다 읽음
const kGlyphCheck = PixelGlyph(
  width: 16,
  height: 12,
  paths: [
    GlyphPath([
      [2, 8, 2, 6, 0, 6, 0, 8, 2, 8],
    ]),
    GlyphPath([
      [4, 10, 4, 8, 2, 8, 2, 10, 4, 10],
    ]),
    GlyphPath([
      [6, 10, 4, 10, 4, 12, 6, 12, 6, 10],
    ]),
    GlyphPath([
      [8, 8, 8, 10, 6, 10, 6, 8, 8, 8],
    ]),
    GlyphPath([
      [10, 6, 10, 8, 8, 8, 8, 6, 10, 6],
    ]),
    GlyphPath([
      [12, 4, 12, 6, 10, 6, 10, 4, 12, 4],
    ]),
    GlyphPath([
      [14, 2, 14, 4, 12, 4, 12, 2, 14, 2],
      [14, 2, 14, 0, 16, 0, 16, 2, 14, 2],
    ], evenOdd: true),
  ],
);

/// 가위표 — 목록에서 지우기
const kGlyphCross = PixelGlyph(
  width: 18,
  height: 18,
  paths: [
    GlyphPath([
      [18, 18, 16, 18, 16, 16, 18, 16, 18, 18],
    ]),
    GlyphPath([
      [14, 14, 16, 14, 16, 16, 14, 16, 14, 14],
    ]),
    GlyphPath([
      [12, 12, 14, 12, 14, 14, 12, 14, 12, 12],
    ]),
    GlyphPath([
      [10, 10, 12, 10, 12, 12, 10, 12, 10, 10],
    ]),
    GlyphPath([
      [6, 12, 6, 10, 8, 10, 8, 12, 6, 12],
      [8, 10, 10, 10, 10, 8, 8, 8, 8, 6, 6, 6, 6, 4, 4, 4, 4, 2, 2, 2, 2, 0, 0, 0, 0, 2, 2, 2, 2, 4, 4, 4, 4, 6, 6, 6, 6, 8, 8, 8, 8, 10],
    ], evenOdd: true),
    GlyphPath([
      [4, 14, 4, 16, 2, 16, 2, 14, 4, 14],
      [4, 14, 4, 12, 6, 12, 6, 14, 4, 14],
    ], evenOdd: true),
    GlyphPath([
      [16, 4, 14, 4, 14, 2, 16, 2, 16, 4],
      [16, 2, 16, 0, 18, 0, 18, 2, 16, 2],
    ], evenOdd: true),
    GlyphPath([
      [12, 6, 12, 4, 14, 4, 14, 6, 12, 6],
    ]),
    GlyphPath([
      [12, 6, 10, 6, 10, 8, 12, 8, 12, 6],
    ]),
    GlyphPath([
      [0, 18, 2, 18, 2, 16, 0, 16, 0, 18],
    ]),
  ],
);

/// 따옴표 — 붙여넣기
const kGlyphPaste = PixelGlyph(
  width: 22,
  height: 14,
  paths: [
    GlyphPath([
      [8, 2, 2, 2, 2, 0, 8, 0, 8, 2],
    ]),
    GlyphPath([
      [6, 10, 8, 10, 8, 2, 10, 2, 10, 14, 8, 14, 8, 12, 6, 12, 6, 10],
    ]),
    GlyphPath([
      [2, 8, 6, 8, 6, 10, 2, 10, 2, 8],
    ]),
    GlyphPath([
      [2, 8, 2, 2, 0, 2, 0, 8, 2, 8],
    ]),
    GlyphPath([
      [20, 2, 14, 2, 14, 0, 20, 0, 20, 2],
    ]),
    GlyphPath([
      [18, 10, 20, 10, 20, 2, 22, 2, 22, 14, 20, 14, 20, 12, 18, 12, 18, 10],
    ]),
    GlyphPath([
      [14, 8, 18, 8, 18, 10, 14, 10, 14, 8],
    ]),
    GlyphPath([
      [14, 8, 14, 2, 12, 2, 12, 8, 14, 8],
    ]),
  ],
);

/// 귀퉁이가 접힌 종이 — 파일
const kGlyphFile = PixelGlyph(
  width: 16,
  height: 20,
  paths: [
    GlyphPath([
      [0, 20, 0, 0, 12, 0, 12, 2, 10, 2, 10, 6, 14, 6, 14, 4, 16, 4, 16, 20, 0, 20],
      [8, 2, 2, 2, 2, 18, 14, 18, 14, 8, 8, 8, 8, 2],
    ], evenOdd: true),
    GlyphPath([
      [14, 4, 12, 4, 12, 2, 14, 2, 14, 4],
    ]),
  ],
);

/// 격자 아이콘 하나를 그린다.
class PixelIcon extends StatelessWidget {
  const PixelIcon(
    this.glyph, {
    super.key,
    required this.cell,
    required this.color,
  });

  final PixelGlyph glyph;
  final double cell;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(glyph.widthAt(cell), glyph.heightAt(cell)),
      painter: _PixelIconPainter(glyph, cell, color),
    );
  }
}

class _PixelIconPainter extends CustomPainter {
  _PixelIconPainter(this.glyph, this.cell, this.color);

  final PixelGlyph glyph;
  final double cell;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (glyph.width <= 0) return;
    final paint = Paint()..color = color;
    canvas.save();
    canvas.scale(size.width / glyph.width);
    for (final g in glyph.paths) {
      canvas.drawPath(g.toPath(), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PixelIconPainter old) =>
      old.glyph != glyph || old.cell != cell || old.color != color;
}

// ---------------------------------------------------------------- 카드 모서리

/// 모서리가 계단처럼 깎인 사각형.
///
/// 둥근 모서리 대신 쓴다. 깎인 자리는 **비워 두는 것**이 요령이다.
/// 배경(검정)이 그대로 비쳐 보이므로, 목록이 스크롤되는 동안에도
/// 카드마다 모서리가 물려 나간 모양이 그대로 유지된다.
/// (칠해서 덮으면 뒤에 무엇이 오든 검정 사각형이 남는다)
class PixelBorder extends ShapeBorder {
  const PixelBorder({this.unit = 4, this.steps = 2, this.side = BorderSide.none});

  /// 계단 한 칸의 크기
  final double unit;

  /// 몇 칸을 깎아낼지 (2면 모서리에서 두 칸이 물려 나간다)
  final int steps;

  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  ShapeBorder scale(double t) =>
      PixelBorder(unit: unit * t, steps: steps, side: side.scale(t));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(
      _path(rect.deflate(side.width / 2)),
      side.toPaint()..style = PaintingStyle.stroke,
    );
  }

  Path _path(Rect r) {
    // 모서리에서 깎아낼 폭. 카드가 아주 작아도 겹치지 않도록 묶어 둔다.
    final u = unit.clamp(1.0, r.shortestSide / (steps * 2));
    final n = steps;
    final p = Path()..moveTo(r.left + n * u, r.top);

    // 위 → 오른쪽 위 모서리
    p.lineTo(r.right - n * u, r.top);
    for (var i = n; i > 0; i--) {
      p.lineTo(r.right - i * u, r.top + (n - i + 1) * u);
      p.lineTo(r.right - (i - 1) * u, r.top + (n - i + 1) * u);
    }
    // 오른쪽 → 오른쪽 아래 모서리
    p.lineTo(r.right, r.bottom - n * u);
    for (var i = n; i > 0; i--) {
      p.lineTo(r.right - (n - i + 1) * u, r.bottom - i * u);
      p.lineTo(r.right - (n - i + 1) * u, r.bottom - (i - 1) * u);
    }
    // 아래 → 왼쪽 아래 모서리
    p.lineTo(r.left + n * u, r.bottom);
    for (var i = n; i > 0; i--) {
      p.lineTo(r.left + i * u, r.bottom - (n - i + 1) * u);
      p.lineTo(r.left + (i - 1) * u, r.bottom - (n - i + 1) * u);
    }
    // 왼쪽 → 왼쪽 위 모서리
    p.lineTo(r.left, r.top + n * u);
    for (var i = n; i > 0; i--) {
      p.lineTo(r.left + (n - i + 1) * u, r.top + i * u);
      p.lineTo(r.left + (n - i + 1) * u, r.top + (i - 1) * u);
    }
    return p..close();
  }

  @override
  bool operator ==(Object other) =>
      other is PixelBorder &&
      other.unit == unit &&
      other.steps == steps &&
      other.side == side;

  @override
  int get hashCode => Object.hash(unit, steps, side);
}
