#!/usr/bin/env python3
"""Generate an original synthetic scene and a simple original 3D LUT (stdlib)."""
import argparse
from pathlib import Path
import struct
import zlib


def make_png(path, width=1200, height=800):
    rows = []
    palette = [(211,73,68),(238,153,67),(236,207,110),(114,166,96),
               (69,160,155),(72,130,193),(110,101,170),(181,104,153),
               (245,242,229),(174,174,169),(94,100,103),(37,42,49)]
    for y in range(height):
        row = bytearray([0])
        fy = y / height
        for x in range(width):
            fx = x / width
            if fy < 0.55:
                t = fy / .55
                rgb = (95+100*t, 146+70*t, 193+40*t)
            else:
                t = (fy-.55)/.4
                rgb = (66-19*t, 129-35*t, 153-32*t)
            # A broad headland and a warm winding walking path.
            edge = .84 - .40*fx + .025*((fx*7)%1)
            if fy > edge and fy < .90:
                t = min(1,(fy-edge)/.3)
                rgb = (82+25*t, 108+16*t, 62+7*t)
                trail = .35 + .28*(fy-.55)
                if abs(fx-trail) < .007 + .035*max(0,fy-.55):
                    rgb = (205,184,142)
            # A small lighthouse, made only from primitive shapes.
            if .235 < fx < .268 and .465 < fy < .635:
                rgb = (239,235,220) if fx < .254 else (205,211,204)
            if .23 < fx < .273 and .452 < fy < .47:
                rgb = (54,77,91)
            if .244 < fx < .259 and .429 < fy < .454:
                rgb = (226,180,114)
            if .244 < fx < .259 and .535 < fy < .566:
                rgb = (48,75,88)
            if fy > .91:
                rgb = palette[min(11, int(fx*12))]
            row.extend(max(0,min(255,round(c))) for c in rgb)
        rows.append(row)

    def chunk(kind, data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    raw = b'\x89PNG\r\n\x1a\n'
    raw += chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))
    raw += chunk(b'sRGB',b'\0')
    raw += chunk(b'IDAT',zlib.compress(b''.join(rows),9))+chunk(b'IEND',b'')
    path.write_bytes(raw)


def make_lut(path):
    lines = ['TITLE "Original Demo Warm"','LUT_3D_SIZE 17','DOMAIN_MIN 0 0 0','DOMAIN_MAX 1 1 1']
    for blue in range(17):
        for green in range(17):
            for red in range(17):
                r,g,b = red/16,green/16,blue/16
                out = (r*.99+g*.035+.012,g*.98+.012,b*.88+.02)
                lines.append(' '.join(f'{max(0,min(1,v)):.8f}' for v in out))
    path.write_text('\n'.join(lines)+'\n',encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'dist/demo')
    args = parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    make_png(args.output/'Demo-Coast.png')
    make_lut(args.output/'Demo-Warm.cube')
    print('Generated original Demo-Coast.png and Demo-Warm.cube; no camera or third-party data used.')
