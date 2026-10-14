#!/usr/bin/env python3
"""Официальные контуры значков магазинов -> код SwiftUI.

Источник — Simple Icons (CC0 1.0, simpleicons.org): свободный набор фирменных
векторов, которым пользуются лаунчеры ровно для этой цели. SVG лежат рядом,
в brand-icons/, поэтому результат воспроизводится без сети.

Контур переводится в Path заранее, а не разбирается в рантайме: разбор SVG в
приложении — лишний код и лишнее место для ошибки, а форма знака не меняется.
Дуги SVG (команда A) приводятся к кубическим кривым — у SwiftUI Path нет дуги
в SVG-постановке.

Amazon в Simple Icons НЕТ: владелец знака попросил его удалить. Его рисуем сами.
"""
import math, pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent
ICONS = HERE / "brand-icons"
OUT = HERE.parent / "Sources/MacRunnerControlCenter/Views/Home/StoreBrandPaths.swift"
SOURCES = [("steam", "steam.svg"), ("epic", "epicgames.svg"),
           ("gog", "gogdotcom.svg"), ("itch", "itchdotio.svg"),
           ("battlenet", "battledotnet.svg")]
NUM = re.compile(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?')


class Reader:
    def __init__(self, d): self.d, self.i = d, 0
    def ws(self):
        while self.i < len(self.d) and self.d[self.i] in ' ,\t\r\n': self.i += 1
    def at_end(self):
        self.ws(); return self.i >= len(self.d)
    def cmd(self):
        self.ws(); c = self.d[self.i]
        if c.isalpha() and c not in 'eE':
            self.i += 1; return c
        return None
    def num(self):
        self.ws(); m = NUM.match(self.d, self.i)
        if not m: raise ValueError(f"ожидалось число на {self.i}: {self.d[self.i:self.i+12]!r}")
        self.i = m.end(); return float(m.group(0))
    def flag(self):
        # Флаги дуги пишутся слитно («a1 1 0 01 5 5»), поэтому читаются по одному знаку.
        self.ws(); c = self.d[self.i]
        if c not in '01': raise ValueError(f"ожидался флаг дуги на {self.i}")
        self.i += 1; return c == '1'


def arc_to_cubics(x1, y1, rx, ry, phi_deg, fa, fs, x2, y2):
    """Дуга SVG -> кубические кривые. Постановка по спецификации SVG, приложение F.6."""
    if rx == 0 or ry == 0: return [('L', x2, y2)]
    if (x1, y1) == (x2, y2): return []
    phi = math.radians(phi_deg); cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1: s = math.sqrt(lam); rx *= s; ry *= s
    num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
    den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
    coef = math.sqrt(max(0.0, num / den)) if den else 0.0
    if fa == fs: coef = -coef
    cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2
    ang = lambda ux, uy, vx, vy: math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not fs and dt > 0: dt -= 2 * math.pi
    elif fs and dt < 0: dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    seg = dt / n; k = 4 / 3 * math.tan(seg / 4)
    def tr(u, v):
        X, Y = rx * u, ry * v
        return cp * X - sp * Y + cx, sp * X + cp * Y + cy
    out = []
    for i in range(n):
        a1 = t1 + i * seg; a2 = a1 + seg
        p1 = tr(math.cos(a1) - k * math.sin(a1), math.sin(a1) + k * math.cos(a1))
        p2 = tr(math.cos(a2) + k * math.sin(a2), math.sin(a2) - k * math.cos(a2))
        p3 = tr(math.cos(a2), math.sin(a2))
        out.append(('C', *p1, *p2, *p3))
    return out


def parse(d):
    r = Reader(d); segs = []
    cx = cy = sx = sy = 0.0; lc = lq = None; cmd = None
    while not r.at_end():
        c = r.cmd()
        if c is None:
            if cmd is None: raise ValueError("контур начинается не с команды")
            c = cmd
            if c in 'Mm': c = 'l' if c == 'm' else 'L'   # лишние пары после M — это L
        cmd = c; rel = c.islower(); C = c.upper()
        if C == 'Z':
            segs.append(('Z',)); cx, cy = sx, sy; lc = lq = None
        elif C == 'M':
            x, y = r.num(), r.num()
            if rel: x += cx; y += cy
            segs.append(('M', x, y)); cx, cy = sx, sy = x, y; lc = lq = None
        elif C == 'L':
            x, y = r.num(), r.num()
            if rel: x += cx; y += cy
            segs.append(('L', x, y)); cx, cy = x, y; lc = lq = None
        elif C == 'H':
            x = r.num() + (cx if rel else 0); segs.append(('L', x, cy)); cx = x; lc = lq = None
        elif C == 'V':
            y = r.num() + (cy if rel else 0); segs.append(('L', cx, y)); cy = y; lc = lq = None
        elif C == 'C':
            a = [r.num() for _ in range(6)]
            if rel: a = [a[j] + (cx if j % 2 == 0 else cy) for j in range(6)]
            segs.append(('C', *a)); lc = (a[2], a[3]); cx, cy = a[4], a[5]; lq = None
        elif C == 'S':
            a = [r.num() for _ in range(4)]
            if rel: a = [a[j] + (cx if j % 2 == 0 else cy) for j in range(4)]
            c1 = (2 * cx - lc[0], 2 * cy - lc[1]) if lc else (cx, cy)
            segs.append(('C', *c1, *a)); lc = (a[0], a[1]); cx, cy = a[2], a[3]; lq = None
        elif C in 'QT':
            if C == 'Q':
                a = [r.num() for _ in range(4)]
                if rel: a = [a[j] + (cx if j % 2 == 0 else cy) for j in range(4)]
                qx, qy, x, y = a
            else:
                x, y = r.num(), r.num()
                if rel: x += cx; y += cy
                qx, qy = (2 * cx - lq[0], 2 * cy - lq[1]) if lq else (cx, cy)
            segs.append(('C', cx + 2/3*(qx-cx), cy + 2/3*(qy-cy), x + 2/3*(qx-x), y + 2/3*(qy-y), x, y))
            lq = (qx, qy); cx, cy = x, y; lc = None
        elif C == 'A':
            rx, ry, rot = r.num(), r.num(), r.num(); fa, fs = r.flag(), r.flag()
            x, y = r.num(), r.num()
            if rel: x += cx; y += cy
            segs.extend(arc_to_cubics(cx, cy, rx, ry, rot, fa, fs, x, y)); cx, cy = x, y; lc = lq = None
        else:
            raise ValueError(f"неизвестная команда {c!r}")
    return segs


def fmt(v):
    s = f"{v:.3f}".rstrip('0').rstrip('.')
    return '0' if s in ('', '-0') else s


def swift_fn(name, segs):
    L = [f"    static func {name}(in r: CGRect) -> Path {{",
         "        let s = min(r.width, r.height) / 24",
         "        let ox = r.midX - 12 * s, oy = r.midY - 12 * s",
         "        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }",
         "        var path = Path()"]
    for g in segs:
        if g[0] == 'M': L.append(f"        path.move(to: p({fmt(g[1])}, {fmt(g[2])}))")
        elif g[0] == 'L': L.append(f"        path.addLine(to: p({fmt(g[1])}, {fmt(g[2])}))")
        elif g[0] == 'C': L.append(f"        path.addCurve(to: p({fmt(g[5])}, {fmt(g[6])}), "
                                   f"control1: p({fmt(g[1])}, {fmt(g[2])}), control2: p({fmt(g[3])}, {fmt(g[4])}))")
        else: L.append("        path.closeSubpath()")
    L += ["        return path", "    }"]
    return "\n".join(L)


def main():
    fns = []
    for name, fname in SOURCES:
        svg = (ICONS / fname).read_text(encoding="utf-8")
        if 'viewBox="0 0 24 24"' not in svg:
            sys.exit(f"ОТКАЗ: {fname} не в сетке 24×24 — масштаб в коде был бы неверен")
        d = re.findall(r'\sd="([^"]+)"', svg)
        if len(d) != 1: sys.exit(f"ОТКАЗ: {fname} несёт {len(d)} контуров, ждали один")
        segs = parse(d[0])
        pts = [(g[k], g[k + 1]) for g in segs if g[0] != 'Z' for k in range(1, len(g), 2)]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        print(f"  {name:6} {len(segs):4} сегментов  рамка x {min(xs):6.2f}..{max(xs):6.2f}  "
              f"y {min(ys):6.2f}..{max(ys):6.2f}")
        if min(xs) < -0.5 or max(xs) > 24.5 or min(ys) < -0.5 or max(ys) > 24.5:
            sys.exit(f"ОТКАЗ: {name} вылез за сетку 24×24 — разбор контура неверен")
        fns.append(swift_fn(name, segs))
    header = '''import SwiftUI

// СГЕНЕРИРОВАНО scripts/gen-store-brand-paths.py — НЕ ПРАВИТЬ РУКАМИ.
// Контуры — официальные формы знаков из Simple Icons (CC0 1.0, simpleicons.org).
// Права на сами товарные знаки у их владельцев; показываем их только затем,
// чтобы обозначить магазин, к которому подключён человек.
enum StoreBrandPaths {
'''
    # Разбор по магазинам строится из SOURCES, а не пишется руками: добавили значок —
    # ветка появилась сама. Иначе новый магазин молча остался бы без контура.
    cases = "\n".join(f"        case .{name}: return StoreBrandPaths.{name}(in: rect)"
                      for name, _ in SOURCES)
    shape = ("\n}\n\n"
             "/// Официальный контур знака магазина.\n"
             "struct StoreGlyphShape: Shape {\n"
             "    let store: GameStore\n\n"
             "    func path(in rect: CGRect) -> Path {\n"
             "        switch store {\n"
             f"{cases}\n"
             "        }\n"
             "    }\n"
             "}\n")
    OUT.write_text(header + "\n\n".join(fns) + shape, encoding="utf-8")
    print(f"записано: {OUT.name}, {OUT.stat().st_size} байт")


if __name__ == "__main__":
    main()
