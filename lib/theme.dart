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
