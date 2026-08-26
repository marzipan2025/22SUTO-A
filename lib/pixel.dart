import 'package:flutter/material.dart';

/// 이 앱의 픽셀 표현을 모아둔 곳.
///
/// 화면에 보이는 "각진 것"은 전부 여기서 나온다.
/// * [PixelIcon] — 네모 칸을 켜고 꺼서 그리는 아이콘
/// * [PixelBorder] — 모서리가 계단처럼 깎인 카드 테두리
///
/// 글자는 여기를 거치지 않는다. 영문·숫자는 Panchang, 한글 본문은
/// 지금 쓰던 글꼴 그대로다.

/// 격자 한 장을 원점 [at]에서부터 찍는다.
void _paintGrid(
  Canvas canvas,
  Paint paint,
  List<String> rows,
  Offset at,
  double cell,
) {
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    var c = 0;
    while (c < row.length) {
      if (row.codeUnitAt(c) == 0x31) {
        // 가로로 이어진 칸은 한 번에 그린다 (경계에 실금이 생기지 않는다)
        var end = c;
        while (end + 1 < row.length && row.codeUnitAt(end + 1) == 0x31) {
          end++;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            at.dx + c * cell,
            at.dy + r * cell,
            (end - c + 1) * cell,
            cell,
          ),
          paint,
        );
        c = end + 1;
      } else {
        c++;
      }
    }
  }
}

/// 같은 격자에 찍는 아이콘들. 폭은 제각각, '1'이 켜진 칸이다.
class PixelGlyph {
  const PixelGlyph(this.rows);
  final List<String> rows;

  int get cols => rows.first.length;
  int get lines => rows.length;
}

/// 왼쪽 화살표 — 진행 화면의 뒤로 가기
const kGlyphBack = PixelGlyph([
  '000100000',
  '001000000',
  '010000000',
  '111111111',
  '010000000',
  '001000000',
  '000100000',
]);

/// 손잡이 두 개 — 설정
const kGlyphSettings = PixelGlyph([
  '1110011',
  '0000011',
  '0000000',
  '1100000',
  '1100111',
]);

/// 재생 삼각형. 줄 수를 [kGlyphDot] 과 똑같이 맞춰 둔다 —
/// 대시보드에서 나란히 설 때 높이가 어긋나지 않게.
const kGlyphPlay = PixelGlyph([
  '11000',
  '11100',
  '11110',
  '11100',
  '11000',
]);

/// 채운 덩어리 — 합성 중
const kGlyphDot = PixelGlyph([
  '01110',
  '11111',
  '11111',
  '11111',
  '01110',
]);

/// 작은 점 — 아직 차례가 오지 않음
const kGlyphTick = PixelGlyph([
  '11',
  '11',
]);

/// 체크 — 다 읽음
const kGlyphCheck = PixelGlyph([
  '0000011',
  '0000110',
  '1001100',
  '1111000',
  '0110000',
]);

/// 작은 가위표 — 문장 합성 실패 (다른 상태 그림과 같은 5줄)
const kGlyphFail = PixelGlyph([
  '10001',
  '01010',
  '00100',
  '01010',
  '10001',
]);

/// 가위표 — 목록에서 지우기. 선을 한 칸 두께로 그어 다른 그림들보다
/// 가볍게 보이게 한다 (두 칸이면 덩어리처럼 뭉쳐 유난히 커 보인다).
const kGlyphCross = PixelGlyph([
  '10000001',
  '01000010',
  '00100100',
  '00011000',
  '00011000',
  '00100100',
  '01000010',
  '10000001',
]);

/// 집게 달린 판 — 붙여넣기
const kGlyphPaste = PixelGlyph([
  '0011100',
  '1111111',
  '1000001',
  '1011101',
  '1000001',
  '1011101',
  '1000001',
  '1111111',
]);

/// 귀퉁이가 접힌 종이 — 파일 추가
const kGlyphFile = PixelGlyph([
  '1111100',
  '1000110',
  '1000011',
  '1011101',
  '1000001',
  '1011101',
  '1000001',
  '1111111',
]);

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
      size: Size(glyph.cols * cell, glyph.lines * cell),
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
    _paintGrid(canvas, Paint()..color = color, glyph.rows, Offset.zero, cell);
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
