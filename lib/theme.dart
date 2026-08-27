import 'package:flutter/material.dart';
import 'package:suto_a/pixel.dart';

/// 화면의 색과 글꼴을 한자리에 모아둔 곳.
///
/// 바탕은 완전한 검정이고, 그 위에 색 카드만 얹는다. 카드 색은
/// 문장이 어디까지 왔는지를 그대로 나타낸다 — 어두운 데서 시작해
/// 밝아졌다가, 다 읽고 나면 다시 가라앉는다.
///
///   대기(steel) → 합성 중(rust) → 준비됨(slate) → 재생 중(yellow) → 완료(olive)

const kBg = Color(0xFF000000);

const kYellow = Color(0xFFEBD93C); // 지금 재생 중 · 주요 표시어
const kOlive = Color(0xFF8A7A17); // 다 읽은 문장
const kRust = Color(0xFFA93C0B); // 만드는 중
const kSlate = Color(0xFF7A959B); // 대시보드 · 다음 차례
const kSteel = Color(0xFF35423F); // 아직 차례가 오지 않은 문장
const kRed = Color(0xFFD8341F); // 실패

/// 밝은 카드 위에 얹는 글자 — 바탕과 같은 검정
const kOnLight = Color(0xFF0A0A0A);

/// 어두운 카드 위에 얹는 글자
const kOnSteel = Color(0xFF93A6A2);
const kOnOlive = Color(0xFFD5C86B);
const kOnRust = Color(0xFFF4C9A8);

/// 카드 밖, 바탕 위에 바로 놓이는 보조 글자
const kMuted = Color(0xFF5C6664);

/// 입력칸 테두리처럼 아주 옅게만 그어야 하는 선
const kLine = Color(0xFF223028);

/// 문장 상태에 따라 카드가 입는 옷 한 벌
class CardSkin {
  const CardSkin(this.fill, this.ink);

  /// 카드 바탕
  final Color fill;

  /// 그 위에 얹는 글자·아이콘
  final Color ink;
}

const kSkinPending = CardSkin(kSteel, kOnSteel);
const kSkinSynth = CardSkin(kRust, kOnRust);
const kSkinReady = CardSkin(kSlate, kOnLight);
const kSkinPlaying = CardSkin(kYellow, kOnLight);
const kSkinDone = CardSkin(kOlive, kOnOlive);
const kSkinFailed = CardSkin(kRed, Color(0xFFFFE3DE));

/// 계단 모서리의 한 칸 크기. 앱 전체가 같은 눈금을 쓴다.
const kPixelUnit = 4.0;

const kPixelShape = PixelBorder(unit: kPixelUnit);

/// 픽셀 카드 하나. 색만 다르고 모양은 전부 이걸로 통일한다.
class PixelCard extends StatelessWidget {
  const PixelCard({
    super.key,
    required this.fill,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.onTap,
    this.unit = kPixelUnit,
  });

  final Color fill;
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final shape = PixelBorder(unit: unit);
    final card = Container(
      padding: padding,
      decoration: ShapeDecoration(color: fill, shape: shape),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: card,
      ),
    );
  }
}

/// JTBC — 본문 기본 글꼴. 한글이 들어가는 자리는 전부 이걸 쓴다.
///
/// 무게가 한 벌뿐이다. 굵게 쓰고 싶은 자리가 생기면 fontWeight 를 주는
/// 대신 색이나 크기로 가르는 편이 낫다 — 없는 굵기를 달라고 하면
/// 엔진이 억지로 굵혀서 자형이 뭉갠다.
const kBodyFamily = 'JTBC';

/// Panchang 대문자의 실제 캡 하이트 비율.
///
/// 크기가 다른 두 표시어의 '윗선'을 맞출 때 쓴다 — 밑선을 맞춘 다음
/// 이 비율에 크기 차이를 곱한 만큼 작은 쪽을 끌어올리면 위가 가지런해진다.
///
/// 폰트가 OS/2 에 적어둔 sCapHeight(0.682)는 실제로 그려지는 자형과 맞지
/// 않는다. 그 값을 그대로 쓰면 작은 쪽이 1.3dp 떠 보인다. 그래서 폰에
/// 실제로 찍힌 픽셀을 재서 나온 값을 쓴다 (34dp 로 그린 PAUSE 의 대문자
/// 높이 59px, 3배 화면 → 19.7dp).
///
/// S·O 같은 둥근 글자는 캡 라인보다 0.8% 쯤 더 위로 넘치는데, 이 크기
/// 차이에서는 반 픽셀도 안 되므로 따지지 않는다.
const kPanchangCapRatio = 0.578;

/// Panchang — 숫자와 영문 보조 글자에 쓴다.
/// 한글 자형이 없으므로 본문에는 절대 물리지 않는다.
const kDisplayFamily = 'Panchang';

TextStyle displayStyle({
  required double size,
  required Color color,
  FontWeight weight = FontWeight.w600,
  double letterSpacing = 0.5,
}) =>
    TextStyle(
      fontFamily: kDisplayFamily,
      fontSize: size,
      height: 1.2,
      color: color,
      fontWeight: weight,
      letterSpacing: letterSpacing,
    );

/// 네모난 슬라이더 손잡이 — 동그란 기본 손잡이 대신 쓴다.
class PixelThumbShape extends SliderComponentShape {
  const PixelThumbShape({this.size = 14});

  final double size;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size(size, size);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    context.canvas.drawRect(
      Rect.fromCenter(center: center, width: size, height: size),
      Paint()..color = sliderTheme.thumbColor ?? kYellow,
    );
  }
}

/// 굴러가는 목록의 위아래 끝을 픽셀 모서리로 물어내는 덮개.
///
/// 목록은 뷰포트 끝에서 카드를 일자로 잘라 버린다. 그러면 잘린 자리만
/// 각지지 않은 채 남아, 굴리는 동안 계단 모서리가 거기서만 끊긴다.
/// 잘리는 네 귀퉁이에 배경색으로 [PixelBorder]와 똑같은 계단을 덧그려,
/// 어디까지 굴려도 끝이 물려 나간 것처럼 보이게 한다.
///
/// 덮개는 손가락을 가로막지 않는다 — 밑의 목록이 그대로 눌린다.
class PixelScrollMask extends StatelessWidget {
  const PixelScrollMask({
    super.key,
    required this.child,
    this.unit = kPixelUnit,
    this.steps = 2,
    this.color = kBg,
  });

  final Widget child;

  /// 계단 한 칸의 크기 — 카드와 같은 눈금을 써야 이가 맞는다
  final double unit;
  final int steps;

  /// 덧그릴 색. 카드 뒤에 깔린 바탕과 같아야 한다.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ScrollMaskPainter(unit, steps, color),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScrollMaskPainter extends CustomPainter {
  _ScrollMaskPainter(this.unit, this.steps, this.color);

  final double unit;
  final int steps;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var i = 0; i < steps; i++) {
      // 끝에서 i번째 줄에서 물어낼 폭 — 안쪽으로 갈수록 좁아진다
      final w = (steps - i) * unit;
      final top = i * unit;
      final bottom = size.height - (i + 1) * unit;
      for (final y in [top, bottom]) {
        canvas.drawRect(Rect.fromLTWH(0, y, w, unit), p);
        canvas.drawRect(Rect.fromLTWH(size.width - w, y, w, unit), p);
      }
    }
  }

  @override
  bool shouldRepaint(_ScrollMaskPainter old) =>
      old.unit != unit || old.steps != steps || old.color != color;
}

/// 낱말 안쪽 글자 사이를 붙여 둔 글.
///
/// 한글은 글자 사이 아무 데서나 줄이 넘어간다. 그대로 두면
/// '도토/리가 맛있다' 처럼 낱말이 잘린다. 낱말 안쪽 글자마다 이음표
/// (U+2060 WORD JOINER)를 끼워 그 자리에서는 넘어가지 못하게 하면
/// '도토리가/맛있다' 로 띄어쓰기 자리에서만 줄이 바뀐다.
/// 눈에 보이지 않고 폭도 차지하지 않는 글자다.
///
/// **화면에 그릴 때만 쓴다.** 저장하거나 읽어주는 글은 원문 그대로여야
/// 한다 — 이음표가 섞이면 합성기가 엉뚱하게 읽는다.
///
/// 띄어쓰기 없이 아주 긴 덩어리는 손대지 않는다. 통째로 붙여 두면
/// 어디서도 줄이 바뀌지 못해 화면 밖으로 삐져나간다.
String byWord(String text) {
  final hit = _byWordCache[text];
  if (hit != null) return hit;

  const joiner = '⁠';
  const tooLong = 20; // 이보다 긴 덩어리는 줄이 바뀔 자리를 남겨 둔다

  final out = StringBuffer();
  final chunk = StringBuffer();

  void flush() {
    final w = chunk.toString();
    chunk.clear();
    if (w.length <= 1 || w.length > tooLong) {
      out.write(w);
      return;
    }
    for (var i = 0; i < w.length; i++) {
      if (i > 0) out.write(joiner);
      out.write(w[i]);
    }
  }

  for (final ch in text.split('')) {
    if (ch == ' ' || ch == '\n' || ch == '\t') {
      flush();
      out.write(ch);
    } else {
      chunk.write(ch);
    }
  }
  flush();

  final result = out.toString();
  // 같은 문장을 매 프레임 다시 만들지 않도록 조금만 들고 있는다
  if (_byWordCache.length > 256) _byWordCache.clear();
  _byWordCache[text] = result;
  return result;
}

final _byWordCache = <String, String>{};
