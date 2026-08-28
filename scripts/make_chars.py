#!/usr/bin/env python3
"""캐릭터 그림을 앱에 넣을 꼴로 다듬는다.

    python3 scripts/make_chars.py ~/Downloads/'SUTO-A asset'

받은 그림은 3072px 정사각형 캔버스에 캐릭터가 떠 있는 꼴이다. 앱은
`assets/char/` 의 그림을 **폭 기준**으로 세워 놓으므로(main.dart 의
_faceWidth), 캔버스의 투명한 자리가 남아 있으면 그만큼 캐릭터가 작아진다.
그래서 두 가지를 한다.

  1. 투명한 가장자리를 모두 잘라낸다 — 남는 것이 곧 보이는 캐릭터다.
  2. '가장 가까운 점'으로 1/8 로 줄인다. 픽셀 그림이라 섞어 줄이면
     가장자리가 뭉갠다. 1/8 은 지금 있는 그림들이 쓰던 배율이라,
     캐릭터끼리의 크기 비율이 그대로 이어진다.

캐릭터마다 세로/가로 비가 다른 것은 일부러 그런 것이다. 폭만 맞춰 세우고
높이는 그림이 정한다.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_icons import BPP, read_png, write_png  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DST = ROOT / 'assets/char'
SHRINK = 8  # 3072px 밑그림 → 앱에 들어가는 크기


def content_box(px, w, h):
    """투명하지 않은 픽셀이 차지하는 네모."""
    x0, y0, x1, y1 = w, h, -1, -1
    for y in range(h):
        row = y * w * BPP
        for x in range(w):
            if px[row + x * BPP + 3] > 8:
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
    if x1 < 0:
        raise SystemExit('그림이 통째로 투명하다')
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1


def crop_shrink(px, w, box, n):
    """[box] 만 잘라내고 n 분의 1 로 줄인다 ('가장 가까운 점')."""
    bx, by, bw, bh = box
    ow, oh = bw // n, bh // n
    out = bytearray(ow * oh * BPP)
    for y in range(oh):
        row = (by + y * n + n // 2) * w * BPP
        base = y * ow * BPP
        for x in range(ow):
            src = row + (bx + x * n + n // 2) * BPP
            out[base + x * BPP:base + (x + 1) * BPP] = px[src:src + BPP]
    return out, ow, oh


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src = Path(sys.argv[1]).expanduser()
    files = sorted(src.glob('*.png'))
    if not files:
        raise SystemExit(f'PNG 가 없다: {src}')

    DST.mkdir(parents=True, exist_ok=True)
    for f in files:
        w, h, px = read_png(f)
        box = content_box(px, w, h)
        out, ow, oh = crop_shrink(px, w, box, SHRINK)
        write_png(DST / f.name, out, ow, oh)
        print(f'  {f.name}  {w}x{h} → 잘라 {box[2]}x{box[3]} → {ow}x{oh}'
              f'  (세로/가로 {oh / ow:.3f})')


if __name__ == '__main__':
    sys.exit(main())
