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
///
/// 밑그림이 다른 그림들의 두 배 크기 블록(4단위)으로 그려져 있다.
/// 블록이 화면에서 같은 크기로 보이도록 절반으로 줄여 쓴다 —
/// 그림은 그대로고 놓이는 자리만 작아진다.
const kGlyphCheck = PixelGlyph(
  scale: 1 / 2,
  width: 20,
  height: 16,
  paths: [
    GlyphPath([
      [0, 8, 4, 8, 4, 12, 0, 12],
    ]),
    GlyphPath([
      [4, 12, 8, 12, 8, 16, 4, 16],
    ]),
    GlyphPath([
      [16, 4, 20, 4, 20, 0, 16, 0],
    ]),
    GlyphPath([
      [8, 12, 12, 12, 12, 8, 8, 8],
    ]),
    GlyphPath([
      [12, 8, 16, 8, 16, 4, 12, 4],
    ]),
  ],
);

/// 가위표 — 목록에서 지우기
///
/// 밑그림이 다른 그림들의 두 배 크기 블록(4단위)으로 그려져 있다.
/// 블록이 화면에서 같은 크기로 보이도록 절반으로 줄여 쓴다 —
/// 그림은 그대로고 놓이는 자리만 작아진다.
const kGlyphCross = PixelGlyph(
  scale: 1 / 2,
  width: 20,
  height: 20,
  paths: [
    GlyphPath([
      [0, 0, 4, 0, 4, 4, 0, 4],
    ]),
    GlyphPath([
      [4, 4, 8, 4, 8, 8, 4, 8],
    ]),
    GlyphPath([
      [8, 8, 12, 8, 12, 12, 8, 12],
    ]),
    GlyphPath([
      [12, 12, 16, 12, 16, 16, 12, 16],
    ]),
    GlyphPath([
      [16, 16, 20, 16, 20, 20, 16, 20],
    ]),
    GlyphPath([
      [0, 20, 4, 20, 4, 16, 0, 16],
    ]),
    GlyphPath([
      [4, 16, 8, 16, 8, 12, 4, 12],
    ]),
    GlyphPath([
      [12, 8, 16, 8, 16, 4, 12, 4],
    ]),
    GlyphPath([
      [16, 4, 20, 4, 20, 0, 16, 0],
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

/// 한 밑그림의 도형들을 하나로 합쳐 둔 것.
///
/// 도형을 따로따로 칠하면 서로 맞닿는 자리에 실금이 남는다. 가장자리를
/// 부드럽게 그리느라 두 도형이 그 선을 각각 반쯤만 덮는데, 반과 반이
/// 하나가 되지 못하고 바탕이 살짝 비친다. 밑그림 하나가 여러 도형으로
/// 그려져 있으면(재생 삼각형은 셋이다) 그 실금이 얼룩처럼 보인다.
///
/// 미리 합쳐 두면 안쪽 경계 자체가 사라진다. 합치는 값이 싸지 않으므로
/// 밑그림마다 한 번만 하고 들고 있는다 — 밑그림은 const 라 몇 개 안 된다.
Path unionOf(PixelGlyph glyph) {
  final hit = _unionCache[glyph];
  if (hit != null) return hit;

  Path? out;
  for (final g in glyph.paths) {
    final p = g.toPath();
    out = out == null ? p : Path.combine(PathOperation.union, out, p);
  }
  final path = out ?? Path();
  _unionCache[glyph] = path;
  return path;
}

final _unionCache = <PixelGlyph, Path>{};

/// 점 셋 — 문장 셀의 곁차림(케밥).
///
/// 밑그림(kebabmenu.svg)의 점 셋을 좌표 그대로 옮겼다. 빈 가장자리를
/// 잘라 2x10 이라, 눈금 2 로 그리면 왼쪽 상태 그림과 키가 같아진다.
const kGlyphKebab = PixelGlyph(
  width: 2,
  height: 10,
  paths: [
    GlyphPath([[0, 0, 2, 0, 2, 2, 0, 2]]),
    GlyphPath([[0, 4, 2, 4, 2, 6, 0, 6]]),
    GlyphPath([[0, 8, 2, 8, 2, 10, 0, 10]]),
  ],
);

/// 연필 — 메인 화면 인풋칸의 밑그림.
///
/// 밑그림(edit.svg)의 칸을 좌표 그대로 옮겼다. 내보낸 path 가 자기 자신과
/// 겹쳐 있어 그대로 쓰면 구멍이 엉뚱한 자리에 나므로, 24x24 를 2px 칸으로
/// 되짚어 가로로 이어지는 칸만 묶었다. 빈 가장자리는 잘라 20x20 이다.
///
/// 누르는 그림이 아니라 인풋칸 뒤에 깔리는 밑그림이라, 색은 칸보다
/// 어두운 것을 쓴다.
const kGlyphEdit = PixelGlyph(
  width: 20,
  height: 20,
  paths: [
    GlyphPath([[14, 0, 16, 0, 16, 2, 14, 2]]),
    GlyphPath([[12, 2, 14, 2, 14, 4, 12, 4]]),
    GlyphPath([[16, 2, 18, 2, 18, 4, 16, 4]]),
    GlyphPath([[10, 4, 12, 4, 12, 6, 10, 6]]),
    GlyphPath([[18, 4, 20, 4, 20, 6, 18, 6]]),
    GlyphPath([[8, 6, 10, 6, 10, 8, 8, 8]]),
    GlyphPath([[12, 6, 14, 6, 14, 8, 12, 8]]),
    GlyphPath([[16, 6, 18, 6, 18, 8, 16, 8]]),
    GlyphPath([[6, 8, 8, 8, 8, 10, 6, 10]]),
    GlyphPath([[14, 8, 16, 8, 16, 10, 14, 10]]),
    GlyphPath([[4, 10, 6, 10, 6, 12, 4, 12]]),
    GlyphPath([[12, 10, 14, 10, 14, 12, 12, 12]]),
    GlyphPath([[2, 12, 4, 12, 4, 14, 2, 14]]),
    GlyphPath([[10, 12, 12, 12, 12, 14, 10, 14]]),
    GlyphPath([[0, 14, 2, 14, 2, 16, 0, 16]]),
    GlyphPath([[8, 14, 10, 14, 10, 16, 8, 16]]),
    GlyphPath([[0, 16, 4, 16, 4, 18, 0, 18]]),
    GlyphPath([[6, 16, 8, 16, 8, 18, 6, 18]]),
    GlyphPath([[0, 18, 6, 18, 6, 20, 0, 20]]),
  ],
);

/// 고른 얼굴을 감싸는 괄호 — 설정 시트의 목소리 고르개.
///
/// 밑그림(char_sel.svg)의 왼쪽 괄호를 좌표 그대로 옮겼다. 10px 짜리 칸
/// 세 줄 × 열세 칸이고, 세로로 이어지는 칸은 하나로 묶어 두었다.
/// 오른쪽 괄호는 이것을 좌우로 뒤집어 쓴다.
const kGlyphParen = PixelGlyph(
  width: 6,
  height: 26,
  paths: [
    GlyphPath([[4, 0, 6, 0, 6, 2, 4, 2]]),
    GlyphPath([[2, 2, 4, 2, 4, 6, 2, 6]]),
    GlyphPath([[0, 6, 2, 6, 2, 20, 0, 20]]),
    GlyphPath([[2, 20, 4, 20, 4, 24, 2, 24]]),
    GlyphPath([[4, 24, 6, 24, 6, 26, 4, 26]]),
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
    canvas.save();
    canvas.scale(size.width / glyph.width);
    canvas.drawPath(unionOf(glyph), Paint()..color = color);
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
