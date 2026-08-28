#!/usr/bin/env python3
"""밑그림 한 장에서 앱 아이콘을 전부 뽑는다.

밑그림은 저장소 맨 위의 AppIcon_22SUTO-A.png (3072px) 하나뿐이다.
그림을 고쳤으면 그 파일만 갈아 끼우고 이걸 돌리면 된다:

    python3 scripts/make_icons.py

뽑는 곳은 네 군데다.

  assets/icon/app_icon.png                     밑그림 그대로 (flutter_launcher_icons 용)
  res/drawable-nodpi/splash_logo.png           밑그림 그대로 (시작 화면)
  res/mipmap-*/ic_launcher.png                 48·72·96·144·192px 로 줄인 것

**`dart run flutter_launcher_icons` 를 쓰지 말 것.** 그쪽은 부드럽게 보간해
줄이는데, 픽셀 그림은 그러면 가장자리가 뭉개져 뿌옇게 나온다. 여기서는
'가장 가까운 점'만 골라 픽셀 경계를 살린다.

밑그림이 3072px 인 것도 그래서다 — 48·96·192 로 딱 나누어떨어진다.
(72·144 는 안 떨어지지만, 안드로이드가 실제로 쓰는 것은 대개 그쪽이 아니다.)

파이썬 기본 모듈만 쓴다. 아이콘을 다시 뽑는 일은 드물어서 느려도 상관없다.
"""

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / 'AppIcon_22SUTO-A.png'
RES = ROOT / 'android/app/src/main/res'

COPIES = [
    ROOT / 'assets/icon/app_icon.png',
    RES / 'drawable-nodpi/splash_logo.png',
]
MIPMAPS = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

BPP = 4  # RGBA 8비트


def read_png(path):
    """RGBA 8비트 · 인터레이스 없는 PNG 를 (폭, 높이, 픽셀바이트) 로 읽는다."""
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path.name}: PNG 가 아니다')

    idat, i = bytearray(), 8
    w = h = None
    while i < len(data):
        (length,) = struct.unpack('>I', data[i:i + 4])
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        if kind == b'IHDR':
            w, h, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if (depth, color, interlace) != (8, 6, 0):
                raise SystemExit(
                    f'{path.name}: 8비트 RGBA 에 인터레이스 없는 PNG 여야 한다 '
                    f'(지금은 depth={depth} color={color} interlace={interlace})')
        elif kind == b'IDAT':
            idat += body
        i += 12 + length

    return w, h, _unfilter(zlib.decompress(bytes(idat)), w, h)


def _unfilter(raw, w, h):
    """PNG 의 줄별 필터를 되돌린다. 줄마다 앞줄 값이 필요해 순서대로 푼다."""
    stride = w * BPP
    out = bytearray(h * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        kind = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride

        if kind == 1:  # Sub — 왼쪽
            for i in range(BPP, stride):
                line[i] = (line[i] + line[i - BPP]) & 0xFF
        elif kind == 2:  # Up — 위
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif kind == 3:  # Average — 왼쪽과 위의 평균
            for i in range(stride):
                left = line[i - BPP] if i >= BPP else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:  # Paeth
            for i in range(stride):
                left = line[i - BPP] if i >= BPP else 0
                upleft = prev[i - BPP] if i >= BPP else 0
                up = prev[i]
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                if pa <= pb and pa <= pc:
                    guess = left
                elif pb <= pc:
                    guess = up
                else:
                    guess = upleft
                line[i] = (line[i] + guess) & 0xFF
        elif kind != 0:
            raise SystemExit(f'모르는 줄 필터 {kind}')

        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def nearest(px, w, h, size):
    """'가장 가까운 점' 하나만 골라 줄인다. 섞지 않으므로 색이 흐려지지 않는다."""
    out = bytearray(size * size * BPP)
    xs = [((x * 2 + 1) * w // (size * 2)) * BPP for x in range(size)]
    for y in range(size):
        row = ((y * 2 + 1) * h // (size * 2)) * w * BPP
        base = y * size * BPP
        for x, sx in enumerate(xs):
            src = row + sx
            out[base + x * BPP:base + x * BPP + BPP] = px[src:src + BPP]
    return out


def write_png(path, px, w, h=None):
    h = h if h is not None else w
    raw = bytearray()
    stride = w * BPP
    for y in range(h):
        raw.append(0)  # 필터 없음 — 작은 그림이라 굳이 줄일 것이 없다
        raw += px[y * stride:(y + 1) * stride]

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body
                + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF))

    path.write_bytes(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
        + chunk(b'IEND', b''))


def main():
    if not MASTER.exists():
        raise SystemExit(f'밑그림이 없다: {MASTER}')

    w, h, px = read_png(MASTER)
    if w != h:
        raise SystemExit(f'밑그림이 정사각형이 아니다: {w}x{h}')
    print(f'밑그림 {MASTER.name} — {w}x{h}')

    master_bytes = MASTER.read_bytes()
    for dst in COPIES:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(master_bytes)
        print(f'  그대로 → {dst.relative_to(ROOT)}')

    for bucket, size in MIPMAPS.items():
        dst = RES / f'mipmap-{bucket}' / 'ic_launcher.png'
        dst.parent.mkdir(parents=True, exist_ok=True)
        write_png(dst, nearest(px, w, h, size), size)
        exact = ' (딱 나누어떨어진다)' if w % size == 0 else ''
        print(f'  {size:>3}px → {dst.relative_to(ROOT)}{exact}')


if __name__ == '__main__':
    sys.exit(main())
