import 'dart:async';

import 'package:flutter/material.dart';
import 'package:suto_a/theme.dart';

const _kEnter = Duration(milliseconds: 240);
const _kExit = Duration(milliseconds: 180);
const _kStay = Duration(milliseconds: 1900);

/// 지금 떠 있는 토스트. 새 토스트가 오면 이걸 먼저 걷어낸다.
OverlayEntry? _current;

/// 화면 위에서 아래로 살짝 내려왔다 사라지는 작은 알림.
///
/// 화면 폭을 가득 채우며 아래에서 올라오던 SnackBar 대신 쓴다.
/// 글자 길이만큼만 차지하고, 화면의 다른 요소를 밀어내지 않는다.
void showToast(BuildContext context, String message) {
  if (message.trim().isEmpty) return;

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _dismissCurrent();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      onGone: () {
        if (identical(_current, entry)) _current = null;
        entry.remove();
      },
    ),
  );
  _current = entry;
  overlay.insert(entry);
}

void _dismissCurrent() {
  final e = _current;
  _current = null;
  if (e != null && e.mounted) e.remove();
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.onGone});

  final String message;
  final VoidCallback onGone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _kEnter,
    reverseDuration: _kExit,
  );

  Timer? _timer;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _timer = Timer(_kStay, _leave);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// 되감기가 끝나면 스스로 걷힌다. 손으로 눌러도 같은 길로 나간다.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    await _c.reverse();
    // 되감는 사이에 새 토스트가 들어와 이미 걷혔을 수 있다
    if (mounted) widget.onGone();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topInset + 10,
      left: 20,
      right: 20,
      child: SlideTransition(
        // 화면 위 바깥에서 제자리로 내려온다
        position: Tween<Offset>(
          begin: const Offset(0, -1.4),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: _c,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        )),
        child: FadeTransition(
          opacity: _c,
          // Center 라야 글자 길이만큼만 폭을 차지한다
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: _leave,
                child: PixelCard(
                  fill: kSlate,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Text(
                    byWord(widget.message),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kOnLight,
                      fontSize: 15.5,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
