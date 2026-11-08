#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""窗口复位器 · B 站横版封面一套（A 痛点反差 / B 功能演示 / C 极简品牌）。

规格依据：哔哩哔哩开放平台「封面上传」文档原文 —
    「格式jpeg、png, 文件大小≤5MB, 建议尺寸≥1146x717, 最低尺寸≥960x600」
故输出 1146x717（16:10），PNG + JPG 双格式；2x 超采样绘制后 LANCZOS 缩小。

视觉与《宣传短视频分镜脚本-v3》成片一致：深蓝渐变 + 蓝/青绿强调色、
macOS 仿窗口线稿、同一枚产品图标。画面沿用 v3 合规净版口径：
不含 URL / 域名 / 二维码 / 平台名 / 「简介·评论区·扫码·下载」等导流话术，
不夸大功能、不出现 iPad / 多显示器 / 跨屏。所有画面文字集中登记后自动扫描。

关键安全区：底部 77px 留白，避开 B 站列表页左下分区角标与右下时长角标。

用法：python3 render_bilibili_covers.py [--outdir DIR]
"""

import argparse
import math
import os
import re
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1146, 717
S = 2
CW, CH = W * S, H * S

# ---------- 与 v3 成片完全一致的配色 ----------
BG_TOP = (9, 15, 28)
BG_BOTTOM = (20, 36, 62)
PANEL = (16, 27, 46)
PANEL_BORDER = (47, 70, 105)
TITLEBAR = (36, 53, 80)
WIN_BG = (28, 42, 66)
WIN_BORDER = (66, 94, 134)
WHITE = (240, 246, 255)
MUTED = (150, 172, 202)
ACCENT = (86, 168, 255)
ACCENT2 = (110, 226, 205)
WARM = (255, 178, 140)
LINE = (58, 84, 122)

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
_font_cache = {}
ALL_TEXT = []


def F(size, bold=True):
    key = (int(size * S), bold)
    if key not in _font_cache:
        try:
            _font_cache[key] = ImageFont.truetype(FONT_PATH, key[0], index=2 if bold else 0)
        except OSError:
            _font_cache[key] = ImageFont.truetype(FONT_PATH, key[0], index=0)
    return _font_cache[key]


def C(c, a=255):
    return c if len(c) == 4 else (c[0], c[1], c[2], a)


def sc(v):
    return int(round(v * S))


def R(box):
    return tuple(sc(v) for v in box)


# ---------- 绘制原语 ----------
def rrect(d, box, fill, radius=16, outline=None, width=1):
    d.rounded_rectangle(
        R(box), radius=sc(radius), fill=C(fill),
        outline=C(outline) if outline is not None else None, width=sc(width),
    )


def text(d, xy, s, size, color=WHITE, bold=True, anchor="lt", stroke=0, shadow=True):
    ALL_TEXT.append(s)
    f = F(size, bold)
    col = C(color)
    x, y = sc(xy[0]), sc(xy[1])
    sw = sc(stroke) if stroke else 0
    if shadow:
        d.text((x + sc(2), y + sc(2)), s, font=f, fill=(0, 0, 0, 120), anchor=anchor,
               stroke_width=sw, stroke_fill=(0, 0, 0, 120) if sw else None)
    d.text((x, y), s, font=f, fill=col, anchor=anchor,
           stroke_width=sw, stroke_fill=col if sw else None)


def tw(d, s, size, bold=True):
    b = d.textbbox((0, 0), s, font=F(size, bold), anchor="lt")
    return (b[2] - b[0]) / S


def pill(d, x, y, s, fill, fg=WHITE, size=24, h=40, outline=None, width=1):
    ALL_TEXT.append(s)
    w = tw(d, s, size, True) + 34
    rrect(d, (x, y, x + w, y + h), fill, h / 2, outline, width)
    text(d, (x + w / 2, y + h / 2 + 1), s, size, fg, True, "mm", 0, False)
    return w


def dashed(d, p1, p2, color, width=2, dash=12, gap=12):
    x1, y1 = p1
    x2, y2 = p2
    length = math.hypot(x2 - x1, y2 - y1)
    if length <= 0:
        return
    ux, uy = (x2 - x1) / length, (y2 - y1) / length
    col = C(color)
    t = 0.0
    while t < length:
        e = min(t + dash, length)
        d.line((sc(x1 + ux * t), sc(y1 + uy * t), sc(x1 + ux * e), sc(y1 + uy * e)),
               fill=col, width=sc(width))
        t += dash + gap


def center_guides(d, cx, cy, box, alpha=120):
    """中心对齐虚线：先画，压在窗口下面。"""
    x0, y0, x1, y1 = box
    dashed(d, (cx, y0 + 64), (cx, y1 - 58), C(ACCENT2, alpha), 2)
    dashed(d, (x0 + 30, cy), (x1 - 30, cy), C(ACCENT2, alpha // 2), 2)


def center_lock(d, cx, cy, alpha=170):
    """中心靶环：窗口画完后叠在最上层，表达「锁定中心」。"""
    r = 42
    d.ellipse(R((cx - r, cy - r, cx + r, cy + r)), outline=C(ACCENT2, alpha), width=sc(3))
    d.ellipse(R((cx - 6, cy - 6, cx + 6, cy + 6)), fill=C(ACCENT2, alpha))
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        d.line((sc(cx + dx * (r + 10)), sc(cy + dy * (r + 10)),
                sc(cx + dx * (r + 26)), sc(cy + dy * (r + 26))),
               fill=C(ACCENT2, alpha), width=sc(3))


def window(d, box, title="", active=True, ghost=False):
    x0, y0, x1, y1 = box
    alpha = 40 if ghost else 255
    rrect(d, (x0 + 3, y0 + 12, x1 + 3, y1 + 12), (0, 0, 0, 70), 18)
    rrect(d, box, C(WIN_BG, alpha), 18,
          C(ACCENT, 220) if active else C(WIN_BORDER, 150), 3 if active else 2)
    rrect(d, (x0 + 2, y0 + 2, x1 - 2, y0 + 46), C(TITLEBAR, 60 if ghost else 255), 18)
    d.rectangle(R((x0 + 2, y0 + 26, x1 - 2, y0 + 46)), fill=C(TITLEBAR, 60 if ghost else 255))
    for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        cx, cy = x0 + 24 + i * 22, y0 + 24
        d.ellipse(R((cx - 6, cy - 6, cx + 6, cy + 6)), fill=C(c, 90 if ghost else 220))
    if title:
        text(d, ((x0 + x1) / 2, y0 + 24), title, 20, MUTED, True, "mm", 0, False)
    span = x1 - x0 - 56
    for j, frac in enumerate((0.92, 0.78, 0.86, 0.60)):
        ly = y0 + 82 + j * 38
        if ly > y1 - 28:
            break
        rrect(d, (x0 + 28, ly, x0 + 28 + span * frac, ly + 12), C(LINE, 60 if ghost else 150), 6)


def desktop(d, box):
    x0, y0, x1, y1 = box
    rrect(d, (x0 + 8, y0 + 14, x1 + 8, y1 + 14), (0, 0, 0, 80), 26)
    rrect(d, box, C(PANEL, 238), 26, PANEL_BORDER, 2)
    for i, c in enumerate((ACCENT, ACCENT2, MUTED)):
        cx, cy = x1 - 92 + i * 22, y0 + 29
        d.ellipse(R((cx - 5, cy - 5, cx + 5, cy + 5)), fill=C(c, 150))


def logo(d, box):
    """与抖音封面 / 成片片尾一致的产品图标。"""
    x0, y0, x1, y1 = box
    s = min(x1 - x0, y1 - y0)
    rrect(d, box, ACCENT, s * 0.24)
    m = s * 0.22
    wx0, wy0, wx1, wy1 = x0 + m, y0 + m, x1 - m, y1 - m
    lw = max(3, s * 0.045)
    d.rounded_rectangle(R((wx0, wy0, wx1, wy1)), radius=sc(s * 0.07),
                        outline=C(WHITE, 255), width=sc(lw))
    d.line(R((wx0, wy0 + s * 0.20, wx1, wy0 + s * 0.20)), fill=C(WHITE, 255), width=sc(lw))


def seg_title(d, x, y, parts, size, stroke=0):
    cur = x
    for s, col in parts:
        text(d, (cur, y), s, size, col, True, "lt", stroke, True)
        cur += tw(d, s, size, True) + 4
    return cur


# ---------- 背景 ----------
def make_bg(variant):
    bg = Image.new("RGBA", (CW, CH), (0, 0, 0, 255))
    d = ImageDraw.Draw(bg)
    for y in range(CH):
        u = y / (CH - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * u) for i in range(3))
        d.line((0, y, CW, y), fill=c + (255,))
    spots = {
        "A": ((250, 330, 420, ACCENT, 34), (900, 420, 380, ACCENT2, 18)),
        "B": ((300, 280, 400, ACCENT, 28), (980, 520, 340, ACCENT2, 20)),
        "C": ((520, 340, 520, ACCENT, 30), (920, 270, 300, ACCENT2, 16)),
    }[variant]
    glow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for cx, cy, r, c, a in spots:
        gd.ellipse(R((cx - r, cy - r, cx + r, cy + r)), fill=C(c, a))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(sc(90))))
    ImageDraw.Draw(bg).line(R((56, 705, 1090, 705)), fill=C(ACCENT, 70), width=sc(2))
    return bg


def compose(variant, draw_fn):
    bg = make_bg(variant)
    art = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(art))
    return Image.alpha_composite(bg, art).convert("RGB").resize((W, H), Image.LANCZOS)


# ---------- A · 痛点反差（推荐主投） ----------
def cover_a():
    def draw(d):
        desk = (600, 92, 1098, 612)
        desktop(d, desk)
        cx, cy = 849, 356
        center_guides(d, cx, cy, desk, 120)
        pill(d, 624, 118, "自动居中 · 不用点", C(PANEL_BORDER, 130), ACCENT2, 22, 36,
             C(ACCENT2, 120), 1)
        window(d, (716, 226, 982, 486), "新窗口", True)
        center_lock(d, cx, cy, 165)
        text(d, (624, 556), "新窗口打开，就在正中间", 24, ACCENT2, True, "lt", 0, False)

        pill(d, 56, 50, "macOS 专属", ACCENT, WHITE, 24, 42)
        text(d, (56, 150), "窗口还要自己摆？", 38, WARM, True, "lt", 0, True)
        text(d, (52, 232), "新窗口", 88, WHITE, True, "lt", 0, True)
        text(d, (52, 336), "自己居中", 88, ACCENT2, True, "lt", 0, True)
        logo(d, (56, 462, 100, 506))
        text(d, (116, 484), "窗口复位器", 36, WHITE, True, "lm", 0, True)
        text(d, (56, 540), "菜单栏小工具 · 自动居中默认开启", 26, MUTED, False, "lt", 0, False)
        x = 56
        for s in ("免费", "开源", "不联网"):
            x += pill(d, x, 590, s, C(PANEL, 255), MUTED, 22, 36, PANEL_BORDER, 1) + 12
    return compose("A", draw)


# ---------- B · 功能演示（技术区 / 信息量高） ----------
def cover_b():
    def draw(d):
        desk = (600, 92, 1098, 612)
        desktop(d, desk)
        window(d, (628, 148, 838, 322), "", False)
        window(d, (860, 148, 1070, 322), "", False)
        pill(d, 620, 332, "靠边 · 正常分屏", C(PANEL, 255), MUTED, 22, 34, PANEL_BORDER, 1)
        d.line(R((624, 388, 1074, 388)), fill=C(LINE, 160), width=sc(2))
        center_guides(d, 849, 486, (600, 392, 1098, 612), 110)
        window(d, (742, 406, 956, 566), "", True)
        center_lock(d, 849, 486, 150)
        pill(d, 620, 572, "靠中 · 松手吸回", C(PANEL, 255), ACCENT2, 22, 34,
             C(ACCENT2, 120), 1)

        pill(d, 56, 50, "macOS 效率工具", ACCENT, WHITE, 24, 42)
        seg_title(d, 56, 146, (("窗口", WHITE), ("自动居中", ACCENT2)), 76)
        text(d, (56, 258), "往侧边拉，正常分屏，不打扰", 30, MUTED, False, "lt", 0, False)
        text(d, (56, 300), "往中间靠，松手就吸回来", 30, MUTED, False, "lt", 0, False)
        for i, s in enumerate(("新窗口 · 打开即居中", "菜单栏 · 切换宽窄模式", "中心磁吸 · 靠边不打扰")):
            y = 362 + i * 54
            d.ellipse(R((60, y + 9, 72, y + 21)), fill=C(ACCENT2, 220))
            text(d, (86, y), s, 28, WHITE, True, "lt", 0, False)
        text(d, (56, 556), "窗口复位器 · v1.1.0", 26, MUTED, False, "lt", 0, False)
        text(d, (56, 600), "不联网 · 不收集数据 · MIT 开源", 24, MUTED, False, "lt", 0, False)
    return compose("B", draw)


# ---------- C · 极简品牌（系列 / 合集通用） ----------
def cover_c():
    def draw(d):
        box = (690, 148, 1072, 536)
        cx, cy = 881, 342
        rrect(d, box, C(WIN_BG, 45), 26, C(ACCENT, 90), 2)
        d.line(R((692, 200, 1070, 200)), fill=C(ACCENT, 45), width=sc(2))
        for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
            px = 718 + i * 22
            d.ellipse(R((px - 6, 168, px + 6, 180)), fill=C(c, 120))
        center_guides(d, cx, cy, box, 80)
        center_lock(d, cx, cy, 110)

        logo(d, (92, 132, 222, 262))
        text(d, (92, 300), "窗口复位器", 82, WHITE, True, "lt", 0, True)
        text(d, (94, 412), "窗口，自己会回中间", 38, ACCENT2, True, "lt", 0, True)
        x = 92
        for s in ("macOS 13.0+", "v1.1.0", "免费开源"):
            x += pill(d, x, 486, s, C(PANEL, 255), MUTED, 22, 38, PANEL_BORDER, 1) + 12
        text(d, (92, 556), "纯 Swift · 不联网 · 不收集数据 · MIT 开源", 24, MUTED, False, "lt", 0, False)
        text(d, (92, 600), "菜单栏小工具 · macOS 专属", 24, MUTED, False, "lt", 0, False)
    return compose("C", draw)


# ---------- 三版对照图（仅本地挑选用，不上传） ----------
def contact_sheet(images, labels):
    card_w = 800
    card_h = int(round(card_w * H / W))
    pad, label_h, gap = 32, 46, 26
    sheet = Image.new("RGB", (card_w + pad * 2, pad * 2 + 3 * (label_h + card_h) + 2 * gap),
                      (8, 14, 26))
    d = ImageDraw.Draw(sheet)
    f = ImageFont.truetype(FONT_PATH, 26, index=2)
    for i, (im, lab) in enumerate(zip(images, labels)):
        y = pad + i * (label_h + card_h + gap)
        d.text((pad, y + 4), lab, font=f, fill=WHITE)
        sheet.paste(im.resize((card_w, card_h), Image.LANCZOS), (pad, y + label_h))
    return sheet


# ---------- 合规扫描（与 v3 口径一致） ----------
VIOL = re.compile(
    r"github|gitee|https?://|\.com|二维码|扫码|简介|评论区|置顶|下载|一键安装"
    r"|Releases|iPad|见链接|公众号|多显示器|跨屏|水印", re.I)
EXAG = re.compile(r"自动整理所有窗口|无需任何权限|任何位置都自动归中|自动帮你均分屏幕")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    names = ("A-痛点反差", "B-功能演示", "C-极简品牌")
    covers = (cover_a(), cover_b(), cover_c())
    labels = ("A · 痛点反差（推荐主投）", "B · 功能演示（技术区）", "C · 极简品牌（系列通用）")

    bad = [s for s in ALL_TEXT if VIOL.search(s) or EXAG.search(s)]
    print(f"画面文字登记：{len(ALL_TEXT)} 条；违规命中：{len(bad)}")
    if bad:
        print("违规文字：", bad)
        return 1
    print("合规校验：无 URL / 二维码 / 平台名 / 导流话术 / 夸大表述")

    for name, im in zip(names, covers):
        png = os.path.join(args.outdir, f"窗口复位器-B站封面-{name}.png")
        jpg = os.path.join(args.outdir, f"窗口复位器-B站封面-{name}.jpg")
        im.save(png, "PNG", optimize=True)
        im.save(jpg, "JPEG", quality=94, subsampling=0, optimize=True)
        print(f"{os.path.basename(png)}  {im.size[0]}x{im.size[1]}  "
              f"PNG {os.path.getsize(png)/1024:.0f}KB / JPG {os.path.getsize(jpg)/1024:.0f}KB")

    sheet = contact_sheet(covers, labels)
    sp = os.path.join(args.outdir, "窗口复位器-B站封面-三版对照.png")
    sheet.save(sp, "PNG", optimize=True)
    print(f"{os.path.basename(sp)}  {sheet.size[0]}x{sheet.size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
