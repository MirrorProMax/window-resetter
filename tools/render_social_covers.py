#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""窗口复位器 · 小红书 / 抖音竖版封面一套（各三版）。

规格口径（**非官方公开文档原文**，来自创作者后台提示与行业通行实测，
发布前请按平台当期后台提示复核）：
  - 小红书：3:4 竖版 1080×1440，核心文字放在中央安全区（四周 ≥96px 留白），
            避开右上角图片数量角标与底部标题/话题 UI。
  - 抖音：9:16 竖版 1080×1920，核心文字放在中央 1080×1320 安全区，
            顶部避开账号信息、底部避开文案与按钮区；主页九宫格会裁成约 3:4，
            故主标题一律放在 y=240..1680 的中央裁切区内。

视觉沿用 v3 成片与 B 站封面：深蓝渐变 + 蓝/青绿强调色、同一枚产品图标、
macOS 仿窗口线稿 + 中心靶环。合规沿用 v3 净版口径：不含 URL / 域名 / 二维码 /
平台名 / 「简介·评论区·扫码·下载」等导流词，不夸大功能、不出现 iPad / 多屏。
所有画面文字集中登记后自动扫描。

输出：PNG + JPG 双格式 + 每平台一张三版对照图；2× 超采样后 LANCZOS 缩小。
用法：python3 render_social_covers.py [--outdir DIR]
"""

import argparse
import math
import os
import re
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ---------- 画布（运行时切换） ----------
W, H = 1080, 1440
S = 2
CW, CH = W * S, H * S


def set_canvas(w, h):
    global W, H, CW, CH
    W, H = w, h
    CW, CH = W * S, H * S


# ---------- 与成片 / B 站封面一致的配色 ----------
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
    d.rounded_rectangle(R(box), radius=sc(radius), fill=C(fill),
                        outline=C(outline) if outline is not None else None, width=sc(width))


def text(d, xy, s, size, color=WHITE, bold=True, anchor="lt", shadow=True):
    ALL_TEXT.append(s)
    f = F(size, bold)
    col = C(color)
    x, y = sc(xy[0]), sc(xy[1])
    if shadow:
        d.text((x + sc(2), y + sc(2)), s, font=f, fill=(0, 0, 0, 120), anchor=anchor)
    d.text((x, y), s, font=f, fill=col, anchor=anchor)


def tw(d, s, size, bold=True):
    b = d.textbbox((0, 0), s, font=F(size, bold), anchor="lt")
    return (b[2] - b[0]) / S


def pill(d, x, y, s, fill, fg=WHITE, size=26, h=46, outline=None, width=1, anchor="lt"):
    ALL_TEXT.append(s)
    w = tw(d, s, size, True) + 34
    left = x - w / 2 if anchor == "mt" else x
    rrect(d, (left, y, left + w, y + h), fill, h / 2, outline, width)
    text(d, (left + w / 2, y + h / 2 + 1), s, size, fg, True, "mm", False)
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


def center_guides(d, cx, cy, box, alpha=110):
    x0, y0, x1, y1 = box
    dashed(d, (cx, y0 + 50), (cx, y1 - 96), C(ACCENT2, alpha), 2)
    dashed(d, (x0 + 26, cy), (x1 - 26, cy), C(ACCENT2, alpha // 2), 2)


def center_lock(d, cx, cy, alpha=170, r=46):
    d.ellipse(R((cx - r, cy - r, cx + r, cy + r)), outline=C(ACCENT2, alpha), width=sc(3))
    d.ellipse(R((cx - 6, cy - 6, cx + 6, cy + 6)), fill=C(ACCENT2, alpha))
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        d.line((sc(cx + dx * (r + 10)), sc(cy + dy * (r + 10)),
                sc(cx + dx * (r + 24)), sc(cy + dy * (r + 24))),
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
        text(d, ((x0 + x1) / 2, y0 + 24), title, 22, MUTED, True, "mm", False)
    span = x1 - x0 - 56
    for j, frac in enumerate((0.92, 0.78, 0.86, 0.60)):
        ly = y0 + 82 + j * 46
        if ly > y1 - 28:
            break
        rrect(d, (x0 + 28, ly, x0 + 28 + span * frac, ly + 14), C(LINE, 60 if ghost else 150), 7)


def card(d, box, dots=True):
    x0, y0, x1, y1 = box
    rrect(d, (x0 + 6, y0 + 12, x1 + 6, y1 + 12), (0, 0, 0, 70), 28)
    rrect(d, box, C(PANEL, 225), 28, PANEL_BORDER, 2)
    if dots:
        for i, c in enumerate((ACCENT, ACCENT2, MUTED)):
            cx, cy = x1 - 88 + i * 22, y0 + 32
            d.ellipse(R((cx - 5, cy - 5, cx + 5, cy + 5)), fill=C(c, 140))


def logo(d, box):
    x0, y0, x1, y1 = box
    s = min(x1 - x0, y1 - y0)
    rrect(d, box, ACCENT, s * 0.24)
    m = s * 0.22
    wx0, wy0, wx1, wy1 = x0 + m, y0 + m, x1 - m, y1 - m
    lw = max(3, s * 0.045)
    d.rounded_rectangle(R((wx0, wy0, wx1, wy1)), radius=sc(s * 0.07),
                        outline=C(WHITE, 255), width=sc(lw))
    d.line(R((wx0, wy0 + s * 0.20, wx1, wy0 + s * 0.20)), fill=C(WHITE, 255), width=sc(lw))


def check_mark(d, cx, cy, r=22):
    d.ellipse(R((cx - r, cy - r, cx + r, cy + r)), fill=C(ACCENT2, 230))
    d.line((sc(cx - r * 0.45), sc(cy), sc(cx - r * 0.10), sc(cy + r * 0.42)),
           fill=C(PANEL, 255), width=sc(4))
    d.line((sc(cx - r * 0.10), sc(cy + r * 0.42), sc(cx + r * 0.52), sc(cy - r * 0.42)),
           fill=C(PANEL, 255), width=sc(4))


def ghost_window(d, box, color=None):
    """靠边/未对齐状态的虚线窗口轮廓。"""
    x0, y0, x1, y1 = box
    col = C(color or WIN_BORDER, 150)
    for p1, p2 in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)),
                   ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        dashed(d, p1, p2, col, 3, 14, 10)


def arrow(d, x0, y0, x1, y1, color):
    dashed(d, (x0, y0), (x1, y1), C(color, 200), 4, 16, 10)
    ang = math.atan2(y1 - y0, x1 - x0)
    L, spread = 22, 0.5
    p2 = (x1 - L * math.cos(ang - spread), y1 - L * math.sin(ang - spread))
    p3 = (x1 - L * math.cos(ang + spread), y1 - L * math.sin(ang + spread))
    d.polygon((sc(x1), sc(y1), sc(p2[0]), sc(p2[1]), sc(p3[0]), sc(p3[1])), fill=C(color, 220))


def make_bg(spots):
    bg = Image.new("RGBA", (CW, CH), (0, 0, 0, 255))
    d = ImageDraw.Draw(bg)
    for y in range(CH):
        u = y / (CH - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * u) for i in range(3))
        d.line((0, y, CW, y), fill=c + (255,))
    glow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for cx, cy, r, c, a in spots:
        gd.ellipse(R((cx - r, cy - r, cx + r, cy + r)), fill=C(c, a))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(sc(90))))
    ImageDraw.Draw(bg).line(R((W * 0.07, H - 26, W * 0.93, H - 26)),
                           fill=C(ACCENT, 60), width=sc(2))
    return bg


def compose(spots, draw_fn):
    bg = make_bg(spots)
    art = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(art))
    return Image.alpha_composite(bg, art).convert("RGB").resize((W, H), Image.LANCZOS)


XHS_GLOW = ((240, 340, 430, ACCENT, 34), (860, 1080, 380, ACCENT2, 18))
DY_GLOW = ((220, 500, 460, ACCENT, 32), (880, 1320, 420, ACCENT2, 20))


# ================= 小红书 1080×1440 =================
def xhs_a():
    """A · 痛点共鸣（推荐）：共鸣钩子 + 大字结果 + 居中演示。"""
    def draw(d):
        pill(d, 96, 110, "macOS 专属", ACCENT, WHITE, 28, 48)
        text(d, (96, 208), "每次开窗口，都要自己拉一遍…", 36, WARM, False)
        text(d, (92, 292), "窗口终于", 100, WHITE)
        text(d, (92, 410), "自己居中", 100, ACCENT2)
        text(d, (96, 548), "打开就摆好，不用点", 36, MUTED, False)

        box = (96, 640, 984, 1132)
        card(d, box)
        pill(d, 128, 672, "新窗口 · 自动落位", C(PANEL_BORDER, 130), ACCENT2, 24, 38,
             C(ACCENT2, 120), 1)
        cx, cy = 540, 890
        center_guides(d, cx, cy, box, 100)
        window(d, (356, 736, 724, 1054), "", True)
        center_lock(d, cx, cy, 165)
        text(d, (128, 1082), "往侧边拉，仍然可以正常分屏", 28, MUTED, False)

        logo(d, (96, 1170, 152, 1226))
        text(d, (168, 1198), "窗口复位器", 34, WHITE, True, "lm")
        text(d, (96, 1262), "免费开源 · 不联网 · 不收集数据", 26, MUTED, False)
    return compose(XHS_GLOW, draw)


def xhs_b():
    """B · 清单种草（小红书原生体）：三条可兑现的功能清单。"""
    def draw(d):
        pill(d, 96, 110, "macOS 效率工具", ACCENT, WHITE, 28, 48)
        text(d, (92, 200), "窗口", 96, WHITE)
        text(d, (92, 318), "自己会回中间", 96, ACCENT2)
        text(d, (96, 456), "一个住在菜单栏的小工具", 34, MUTED, False)

        card(d, (96, 536, 984, 1136))
        rows = (
            ("新窗口打开，就在正中间", "自动居中默认开启，不用点"),
            ("拉到侧边，正常分屏", "靠边放就不打扰"),
            ("往中间靠，松手吸回", "中心磁吸范围可调"),
        )
        for i, (main, sub) in enumerate(rows):
            y = 606 + i * 176
            check_mark(d, 154, y + 18)
            text(d, (200, y), main, 40, WHITE)
            text(d, (200, y + 58), sub, 28, MUTED, False)
            if i < 2:
                d.line(R((140, y + 132, 940, y + 132)), fill=C(LINE, 110), width=sc(2))

        logo(d, (96, 1190, 152, 1246))
        text(d, (168, 1218), "窗口复位器", 34, WHITE, True, "lm")
        text(d, (96, 1282), "免费 · 开源 · 不联网", 26, MUTED, False)
    return compose(XHS_GLOW, draw)


def xhs_c():
    """C · 极简品牌：居中构图，适合系列封面 / 合集。"""
    def draw(d):
        pill(d, 540, 110, "macOS 专属", ACCENT, WHITE, 28, 48, anchor="mt")
        logo(d, (440, 250, 640, 450))
        text(d, (540, 566), "窗口复位器", 96, WHITE, True, "mm")
        text(d, (540, 682), "窗口，自己会回中间", 40, ACCENT2, True, "mm")
        tags = ("macOS 13.0+", "v1.1.0", "免费开源")
        total = sum(tw(d, s, 24, True) + 34 for s in tags) + 14 * (len(tags) - 1)
        x = (W - total) / 2
        for s in tags:
            x += pill(d, x, 770, s, C(PANEL, 255), MUTED, 24, 44, PANEL_BORDER, 1) + 14
        box = (180, 900, 900, 1252)
        rrect(d, box, C(WIN_BG, 45), 28, C(ACCENT, 90), 2)
        d.line(R((182, 958, 898, 958)), fill=C(ACCENT, 45), width=sc(2))
        for i, c in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
            px = 210 + i * 22
            d.ellipse(R((px - 6, 926, px + 6, 938)), fill=C(c, 120))
        center_guides(d, 540, 1076, box, 80)
        center_lock(d, 540, 1076, 110)
        text(d, (540, 1332), "菜单栏小工具 · macOS 专属", 26, MUTED, False, "mm")
    return compose(XHS_GLOW, draw)


# ================= 抖音 1080×1920 =================
def dy_a():
    """A · 强钩子（推荐）：反问钩子 + 超大字 + 居中演示，主页 3:4 裁切不丢信息。"""
    def draw(d):
        pill(d, 80, 300, "macOS 专属", ACCENT, WHITE, 30, 52)
        text(d, (76, 426), "窗口还要", 110, WHITE)
        text(d, (76, 566), "自己摆？", 110, WARM)
        text(d, (80, 736), "让它自己居中", 76, ACCENT2)

        box = (80, 860, 1000, 1400)
        card(d, box)
        pill(d, 120, 892, "新窗口 · 自动落位", C(PANEL_BORDER, 130), ACCENT2, 26, 42,
             C(ACCENT2, 120), 1)
        cx, cy = 540, 1140
        center_guides(d, cx, cy, box, 100)
        window(d, (326, 946, 754, 1300), "", True)
        center_lock(d, cx, cy, 165)
        text(d, (120, 1350), "打开就摆好 · 不用点", 28, ACCENT2)

        logo(d, (80, 1448, 132, 1500))
        text(d, (148, 1474), "窗口复位器", 32, WHITE, True, "lm")
    return compose(DY_GLOW, draw)


def dy_b():
    """B · 结果反差：上「靠边不对齐」→ 下「松手回正中」，先亮结果。"""
    def draw(d):
        pill(d, 80, 300, "macOS 专属", ACCENT, WHITE, 30, 52)
        text(d, (76, 426), "不用手动摆", 88, WHITE)
        text(d, (76, 556), "新窗口", 110, WHITE)
        text(d, (76, 696), "自己居中", 110, ACCENT2)

        top = (80, 880, 1000, 1150)
        card(d, top, dots=False)
        ghost_window(d, (150, 934, 520, 1110))
        pill(d, 560, 962, "手动拉伸，还是对不齐", C(PANEL, 255), MUTED, 26, 42,
             PANEL_BORDER, 1)
        arrow(d, 560, 1060, 900, 1060, ACCENT)

        text(d, (540, 1178), "松手就吸回来", 40, ACCENT2, True, "mm")

        bot = (80, 1230, 1000, 1510)
        card(d, bot, dots=False)
        center_guides(d, 540, 1370, bot, 100)
        window(d, (330, 1270, 750, 1470), "", True)
        center_lock(d, 540, 1370, 165, 40)

        logo(d, (80, 1550, 132, 1602))
        text(d, (148, 1576), "窗口复位器", 32, WHITE, True, "lm")
    return compose(DY_GLOW, draw)


def dy_c():
    """C · 品牌定格：升级版片尾定格，适合系列化统一封面。"""
    def draw(d):
        pill(d, 540, 300, "macOS 专属", ACCENT, WHITE, 30, 52, anchor="mt")
        logo(d, (400, 430, 680, 710))
        text(d, (540, 826), "窗口复位器", 96, WHITE, True, "mm")
        text(d, (540, 950), "窗口，自己会回中间", 44, ACCENT2, True, "mm")

        card(d, (120, 1050, 960, 1320), dots=False)
        text(d, (540, 1120), "v1.1.0 · 免费开源", 38, WHITE, True, "mm")
        text(d, (540, 1196), "不联网 · 不收集数据 · MIT 开源", 28, MUTED, False, "mm")
        text(d, (540, 1260), "macOS 13.0+ · 需辅助功能权限", 26, MUTED, False, "mm")

        text(d, (540, 1420), "菜单栏小工具 · macOS 专属", 28, MUTED, False, "mm")
    return compose(DY_GLOW, draw)


# ---------- 三版对照图（仅本地挑选，不上传） ----------
def contact_sheet(images, labels, card_w, card_h):
    pad, label_h, gap = 24, 46, 20
    sheet = Image.new("RGB", (3 * card_w + 4 * pad, card_h + label_h + pad * 2), (8, 14, 26))
    d = ImageDraw.Draw(sheet)
    f = ImageFont.truetype(FONT_PATH, 24, index=2)
    for i, (im, lab) in enumerate(zip(images, labels)):
        x = pad + i * (card_w + gap)
        d.text((x, pad), lab, font=f, fill=WHITE)
        sheet.paste(im.resize((card_w, card_h), Image.LANCZOS), (x, pad + label_h))
    return sheet


# ---------- 合规扫描（与 v3 / B 站封面一致） ----------
VIOL = re.compile(
    r"github|gitee|https?://|\.com|二维码|扫码|简介|评论区|置顶|下载|一键安装"
    r"|Releases|iPad|见链接|公众号|多显示器|跨屏|水印|点赞|关注|收藏", re.I)
EXAG = re.compile(r"自动整理所有窗口|无需任何权限|任何位置都自动归中|自动帮你均分屏幕")

SPECS = (
    dict(platform="小红书", size=(1080, 1440),
         names=("A-痛点共鸣", "B-清单种草", "C-极简品牌"),
         labels=("A · 痛点共鸣（推荐）", "B · 清单种草", "C · 极简品牌"),
         makers=(xhs_a, xhs_b, xhs_c), sheet=(300, 400)),
    dict(platform="抖音", size=(1080, 1920),
         names=("A-强钩子", "B-结果反差", "C-品牌定格"),
         labels=("A · 强钩子（推荐）", "B · 结果反差", "C · 品牌定格"),
         makers=(dy_a, dy_b, dy_c), sheet=(240, 427)),
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    outputs = []
    for spec in SPECS:
        set_canvas(*spec["size"])
        covers = [maker() for maker in spec["makers"]]
        outputs.append((spec["platform"], spec["names"], covers,
                        spec["labels"], spec["sheet"]))

    bad = [s for s in ALL_TEXT if VIOL.search(s) or EXAG.search(s)]
    print(f"画面文字登记：{len(ALL_TEXT)} 条；违规命中：{len(bad)}")
    if bad:
        print("违规文字：", bad)
        return 1
    print("合规校验：无 URL / 二维码 / 平台名 / 导流话术 / 夸大表述 / 互动引导")

    for platform, names, covers, labels, sheet_size in outputs:
        for name, im in zip(names, covers):
            png = os.path.join(args.outdir, f"窗口复位器-{platform}封面-{name}.png")
            jpg = os.path.join(args.outdir, f"窗口复位器-{platform}封面-{name}.jpg")
            im.save(png, "PNG", optimize=True)
            im.save(jpg, "JPEG", quality=94, subsampling=0, optimize=True)
            print(f"{os.path.basename(png)}  {im.size[0]}x{im.size[1]}  "
                  f"PNG {os.path.getsize(png)/1024:.0f}KB / JPG {os.path.getsize(jpg)/1024:.0f}KB")
        sp = os.path.join(args.outdir, f"窗口复位器-{platform}封面-三版对照.png")
        contact_sheet(covers, labels, *sheet_size).save(sp, "PNG", optimize=True)
        print(f"{os.path.basename(sp)}  (挑选对照图)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
