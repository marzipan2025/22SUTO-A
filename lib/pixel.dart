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

/// 격자에 찍는 아이콘 한 장. 폭은 제각각, '1'이 켜진 칸이다.
///
/// 밑그림(SVG)에서 옮겨온 것들이라 그린 눈금이 서로 다르다. 설정과 재생은
/// 나머지의 절반 칸으로 그려져 있어서, 그 그림들은 [sub] 를 2 로 둔다.
/// 그리는 쪽은 늘 같은 [cell] 을 넘기면 되고, 비율은 여기서 맞춘다.
class PixelGlyph {
  const PixelGlyph(this.rows, {this.sub = 1});

  final List<String> rows;

  /// 이 그림이 쓴 칸이 기본 칸의 1/sub 이라는 뜻
  final int sub;

  int get cols => rows.first.length;
  int get lines => rows.length;

  /// 기본 칸 [cell] 로 그렸을 때 차지하는 크기
  double widthAt(double cell) => cols * cell / sub;
  double heightAt(double cell) => lines * cell / sub;
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
  '000000000000111100',
  '000000000000111100',
  '000000000011000011',
  '001111110011000011',
  '001111110011000011',
  '000000000011000011',
  '000000000000111100',
  '000000000000111100',
  '000000000000000000',
  '000000000000000000',
  '001111000000000000',
  '001111000000000000',
  '110000110000000000',
  '110000110011111100',
  '110000110011111100',
  '110000110000000000',
  '001111000000000000',
  '001111000000000000',
], sub: 2);

/// 재생 삼각형
const kGlyphPlay = PixelGlyph([
  '111100000000',
  '111100000000',
  '111111100000',
  '111111100000',
  '111111111100',
  '111111111100',
  '111111111111',
  '111111111111',
  '111111111100',
  '111111111100',
  '111111100000',
  '111111100000',
  '111100000000',
  '111100000000',
], sub: 2);

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
  '00000001',
  '00000010',
  '00000100',
  '10001000',
  '01010000',
  '00100000',
]);

/// 작은 가위표 — 문장 합성 실패 (다른 상태 그림과 같은 5줄)
const kGlyphFail = PixelGlyph([
  '10001',
  '01010',
  '00100',
  '01010',
  '10001',
]);

/// 가위표 — 목록에서 지우기
const kGlyphCross = PixelGlyph([
  '100000001',
  '010000010',
  '001000100',
  '000101000',
  '000010000',
  '000101000',
  '001000100',
  '010000010',
  '100000001',
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
    // 잘게 그린 그림은 칸도 그만큼 잘게 찍는다
    final c = cell / glyph.sub;
    return CustomPaint(
      size: Size(glyph.cols * c, glyph.lines * c),
      painter: _PixelIconPainter(glyph, c, color),
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
