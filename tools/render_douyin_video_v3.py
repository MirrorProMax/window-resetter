#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""窗口复位器 · 抖音 30 秒竖屏宣传片 v3 逐帧渲染器（1080x1920 / 30fps）。

对应《窗口复位器-宣传短视频分镜脚本-v3.md》四组 / 8 镜，落实 v2「待修订项」：
  一 钩子与愿望（0.8 秒视觉反差 → 平板式自动居中，产品名提前露出）
  二 介绍（产品出场 / 新窗口自动居中 / 菜单栏切换宽窄 + 记忆角标）
  三 不打扰（侧拉正常分屏 → 往中间靠吸回中心）
  四 收尾（Slogan + 品牌净版定格：v1.1.0 / 隐私 / 系统要求）

**全平台合规净版**：画面不含任何链接、二维码、平台名与「见简介 / 评论区」导流话术，
下载地址全部外置到发布文案，同一支片可通发抖音、B站、小红书、视频号等平台。
画面为按项目真实功能绘制的「仿录屏」动效，非真实屏幕录制。
配音为温柔女声（Edge TTS 晓晓 / Warm），缓存在 voiceover_v3/，离线可重渲染。
用法：python3 render_douyin_video_v3.py --output <path.mp4>
"""

import argparse
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave
from PIL import Image, ImageDraw, ImageFont

W, H, FPS, DUR = 1080, 1920, 30, 30
FRAMES = FPS * DUR
SR = 44100

# ---------- 时间轴与配音 ----------
# v3：四组 / 8 镜。按 8 段旁白实测时长校准，并刻意做出「快—慢—停」起伏：
# 镜 01 压到 2.25s（视觉钩子）、镜 05 留足静止、片尾 7.25s 给品牌定格。
SCENE_START = [0.00, 2.25, 5.60, 9.10, 12.15, 16.00, 19.10, 22.75]
CUR_START = 0.0


def G(local_t):
    """局部时间 → 全局时间。"""
    return local_t + CUR_START


# 温柔女声：Edge TTS 晓晓（Warm），语速 +10%；缓存缺失时才联网合成。
VOICE_NAME = "zh-CN-XiaoxiaoNeural"
VOICE_RATE = "+10%"
FALLBACK_VOICE = "Tingting"
FALLBACK_RATE = 200
VOICE_CACHE = "voiceover_v3"

# 旁白：(起点秒, 文案)。8 段实测合计 23.57s，段间留呼吸，末尾留 3.7s 定格。
VOICEOVER = [
    (0.15, "窗口还要自己摆？"),
    (2.40, "像平板一样，打开就自己居中。"),
    (5.75, "窗口复位器，新窗口自己居中。"),
    (9.25, "点一下菜单栏，切换宽窄。"),
    (12.30, "往侧边拉，正常分屏，不打扰。"),
    (16.15, "往中间靠，松手就吸回来。"),
    (19.25, "不联网，不收集数据，代码开源。"),
    (22.90, "新版已经发布，免费开源。"),
]

# ---------- 配色 ----------
BG_TOP = (9, 15, 28)
BG_BOTTOM = (20, 36, 62)
PANEL = (16, 27, 46)
PANEL_BORDER = (47, 70, 105)
MENUBAR = (24, 38, 62)
WIN_BG = (28, 42, 66)
WIN_BORDER = (66, 94, 134)
TITLEBAR = (36, 53, 80)
WHITE = (240, 246, 255)
MUTED = (150, 172, 202)
ACCENT = (86, 168, 255)
ACCENT2 = (110, 226, 205)
WARN = (255, 138, 101)
LINE = (58, 84, 122)

HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
_font_cache = {}


def font(size, bold=False):
    key = (size, bold)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(HIRAGINO, size, index=2 if bold else 0)
    return _font_cache[key]


# ---------- 工具 ----------
def clamp(v, a=0.0, b=1.0):
    return max(a, min(b, v))


def lerp(a, b, u):
    return a + (b - a) * u


def ease_out(u):
    return 1 - (1 - u) ** 3


def ease_inout(u):
    return 3 * u * u - 2 * u * u * u


def seg(t, a, b):
    return clamp((t - a) / (b - a))


def lerp_rect(a, b, u):
    return tuple(lerp(x, y, u) for x, y in zip(a, b))


def blend(c1, c2, u):
    return tuple(int(lerp(x, y, u)) for x, y in zip(c1, c2))


def alpha_shape(img, box, draw_fn, alpha=255):
    """在局部透明图层上绘制，再按 alpha 贴回。"""
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 or alpha <= 0:
        return
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(layer), w, h)
    if alpha < 255:
        a = layer.getchannel("A").point(lambda v: v * alpha // 255)
        layer.putalpha(a)
    img.paste(layer, (x0, y0), layer)


def rrect(img, box, fill, radius=16, alpha=255, outline=None, width=1):
    def fn(d, w, h):
        d.rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=fill + (255,),
                            outline=(outline + (255,)) if outline else None, width=width)
    alpha_shape(img, box, fn, alpha)


def txt(img, xy, s, size, color=WHITE, bold=False, anchor="mm", alpha=255, shadow=True):
    if alpha <= 0:
        return
    f = font(size, bold)
    bbox = f.getbbox(s)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = 12
    lw, lh = tw + pad * 2, th + pad * 2
    layer = Image.new("RGBA", (lw, lh), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    if shadow:
        d.text((pad - bbox[0] + 2, pad - bbox[1] + 3), s, font=f, fill=(0, 0, 0, 170))
    d.text((pad - bbox[0], pad - bbox[1]), s, font=f, fill=color + (255,))
    if alpha < 255:
        layer.putalpha(layer.getchannel("A").point(lambda v: v * alpha // 255))
    x, y = xy
    if anchor == "mm":
        px, py = x - lw / 2, y - lh / 2
    elif anchor == "lm":
        px, py = x, y - lh / 2
    elif anchor == "rm":
        px, py = x - lw, y - lh / 2
    else:
        px, py = x, y
    img.paste(layer, (int(px), int(py)), layer)


def dashed_box(img, box, color=ACCENT, width=3, dash=16, gap=12, alpha=180):
    x0, y0, x1, y1 = [int(v) for v in box]
    def fn(d, w, h):
        c = color + (255,)
        x = 0
        while x < w:
            d.line((x, 0, min(x + dash, w), 0), fill=c, width=width)
            d.line((x, h - 1, min(x + dash, w), h - 1), fill=c, width=width)
            x += dash + gap
        y = 0
        while y < h:
            d.line((0, y, 0, min(y + dash, h)), fill=c, width=width)
            d.line((w - 1, y, w - 1, min(y + dash, h)), fill=c, width=width)
            y += dash + gap
    alpha_shape(img, (x0, y0, x1, y1), fn, alpha)


def ring(img, cx, cy, r, color=ACCENT, width=6, alpha=200):
    def fn(d, w, h):
        d.ellipse((0, 0, w - 1, h - 1), outline=color + (255,), width=width)
    alpha_shape(img, (cx - r, cy - r, cx + r, cy + r), fn, alpha)


# ---------- 背景 ----------
def make_base():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        d.line((0, y, W, y), fill=blend(BG_TOP, BG_BOTTOM, y / H))
    # 柔光
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-260, -420, 1340, 900), fill=(58, 122, 200, 26))
    gd.ellipse((-180, 1180, 1260, 2260), fill=(40, 160, 170, 18))
    img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
    return img


BASE = make_base()

PANEL_BOX = (70, 330, 1010, 1370)
MENU_TOP, MENU_BOT = 330, 392
DOCK_TOP = 1300
DESK_TOP, DESK_BOT = MENU_BOT, DOCK_TOP


def draw_desktop(img, dim=0.0):
    """绘制 macOS 风格桌面面板。dim>0 时叠加暗色。"""
    rrect(img, PANEL_BOX, PANEL, radius=28, outline=PANEL_BORDER, width=2)
    # 桌面区域
    rrect(img, (PANEL_BOX[0] + 2, DESK_TOP, PANEL_BOX[2] - 2, DESK_BOT),
          (18, 33, 58), radius=0)
    # 菜单栏
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((PANEL_BOX[0] + 2, MENU_TOP + 2, PANEL_BOX[2] - 2, MENU_BOT),
                        radius=0, fill=MENUBAR)
    txt(img, (110, 361), "窗口复位器", 24, WHITE, bold=True, anchor="lm", shadow=False)
    for i, s in enumerate(["文件", "编辑", "显示", "窗口", "帮助"]):
        txt(img, (280 + i * 78, 361), s, 22, MUTED, anchor="lm", shadow=False)
    # 右侧状态图标 + 本应用图标（高亮）
    txt(img, (875, 361), "9:41", 22, WHITE, anchor="mm", shadow=False)
    rrect(img, (920, 340, 972, 384), (43, 92, 156), radius=10)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((930, 350, 962, 374), radius=4, outline=WHITE, width=3)
    d.line((930, 359, 962, 359), fill=WHITE, width=3)
    # Dock
    rrect(img, (300, 1310, 780, 1362), (38, 56, 84), radius=20, alpha=225)
    cols = [(86, 168, 255), (110, 226, 205), (255, 178, 92), (206, 138, 255), (120, 150, 190)]
    for i, c in enumerate(cols):
        rrect(img, (326 + i * 88, 1320, 386 + i * 88, 1352), c, radius=12, alpha=230)
    if dim > 0:
        def fn(dr, w, h):
            dr.rectangle((0, 0, w, h), fill=(6, 11, 22, int(255 * dim)))
        alpha_shape(img, PANEL_BOX, fn, 255)


def draw_window(img, box, title, narrow=False, active=True):
    x0, y0, x1, y1 = [int(v) for v in box]
    if x1 - x0 < 40 or y1 - y0 < 40:
        return
    # 阴影
    def shadow(dr, w, h):
        dr.rounded_rectangle((0, 0, w - 1, h - 1), radius=18, fill=(2, 6, 14, 150))
    alpha_shape(img, (x0 + 10, y0 + 14, x1 + 10, y1 + 14), shadow, 255)
    rrect(img, box, WIN_BG, radius=18, outline=ACCENT if active else WIN_BORDER, width=3 if active else 2)
    # 标题栏
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((x0, y0, x1, y0 + 52), radius=18, fill=TITLEBAR)
    d.rectangle((x0, y0 + 34, x1, y0 + 52), fill=TITLEBAR)
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy = x0 + 30 + i * 26, y0 + 26
        d.ellipse((cx - 8, cy - 8, cx + 8, cy + 8), fill=c)
    txt(img, ((x0 + x1) / 2, y0 + 26), title, 24, WHITE, bold=True, shadow=False)
    # 内容骨架
    cy = y0 + 88
    sidebar = (x1 - x0) > 560 and not narrow
    sx0 = x0 + 28
    body_x0 = x0 + 210 if sidebar else x0 + 32
    body_w = (x1 - 32) - body_x0
    if sidebar:
        for i in range(5):
            rrect(img, (sx0, cy + i * 62, sx0 + 150, cy + i * 62 + 18), LINE, radius=8, alpha=190)
    for i in range(9):
        if cy + i * 74 + 22 > y1 - 24:
            break
        wdt = body_w * ([0.92, 0.72, 0.84, 0.55, 0.9, 0.66, 0.8, 0.48, 0.75][i])
        col = ACCENT if i == 0 else LINE
        rrect(img, (body_x0, cy + i * 74, body_x0 + wdt, cy + i * 74 + 16), col,
              radius=8, alpha=225 if i == 0 else 180)


def draw_cursor(img, x, y):
    def fn(d, w, h):
        pts = [(2, 2), (2, 34), (11, 26), (19, 42), (26, 38), (18, 23), (31, 23)]
        d.polygon(pts, fill=(255, 255, 255, 255), outline=(10, 16, 28, 255))
    alpha_shape(img, (x, y, x + 34, y + 46), fn, 255)


def draw_icon(img, cx, cy, size, bg=ACCENT, glyph=WHITE):
    r = size / 2
    rrect(img, (cx - r, cy - r, cx + r, cy + r), bg, radius=int(size * 0.24))
    d = ImageDraw.Draw(img)
    g = size * 0.5
    d.rounded_rectangle((cx - g / 2, cy - g / 2, cx + g / 2, cy + g / 2),
                        radius=int(size * 0.07), outline=glyph, width=max(4, int(size * 0.045)))
    d.line((cx - g / 2, cy - g / 2 + g * 0.24, cx + g / 2, cy - g / 2 + g * 0.24),
           fill=glyph, width=max(4, int(size * 0.045)))


def chrome(img, t, scene_idx, scene_name, caption_lines, note, kicker=True, fade_t=None,
           tag=None, fade_dur=0.25):
    """统一的字幕、页眉与进度条。t 必须是全局时间 G(local_t)；
    fade_t 用镜头内局部时间，进度条始终按全局 t 单调递增。
    tag 用于把「可选操作」类镜头与主角功能区分开；
    fade_dur 控制字幕淡入时长，开场用较长值让节奏更缓。"""
    # 平台标注常驻，避免观众误以为是 Windows 工具
    rrect(img, (70, 84, 330, 146), (43, 92, 156), radius=31)
    txt(img, (200, 115), "macOS 专属", 29, WHITE, bold=True, shadow=False)
    if tag:
        rrect(img, (650, 84, 1000, 146), (34, 54, 82), radius=31)
        txt(img, (825, 115), tag, 26, ACCENT2, bold=True, shadow=False)
    if kicker:
        txt(img, (90, 208), "窗口复位器 · 菜单栏小工具", 29, MUTED, anchor="lm", shadow=False)
        txt(img, (990, 208), f"{scene_idx:02d} / {len(SCENES):02d}  {scene_name}", 28, MUTED,
            anchor="rm", shadow=False)
    ft = t if fade_t is None else fade_t
    fade = int(255 * seg(ft, 0.0, fade_dur))
    n = len(caption_lines)
    ys = [1510, 1602] if n == 2 else [1555]
    size = 66 if n == 2 else 72
    for s, y in zip(caption_lines, ys):
        txt(img, (540, y), s, size, WHITE, bold=True, alpha=fade)
    txt(img, (540, 1702), note, 32, MUTED, alpha=fade)
    txt(img, (540, 1838), "不联网 · 不收集数据 · MIT 开源", 26, MUTED, alpha=200, shadow=False)
    # 进度条
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((70, 1896, 1010, 1902), radius=3, fill=(46, 66, 96))
    d.rounded_rectangle((70, 1896, int(lerp(70, 1010, t / DUR)), 1902), radius=3, fill=ACCENT)


def hint_pill(img, s, color=ACCENT2, alpha=255):
    """面板下方的说明胶囊，避开 Dock 与字幕区。"""
    rrect(img, (210, 1384, 870, 1438), (30, 48, 76), radius=26, alpha=alpha)
    txt(img, (540, 1411), s, 27, color, bold=True, shadow=False, alpha=alpha)


# ---------- 各镜头（v3 / 8 镜） ----------
WIDE = (120, 400, 960, 1300)
NARROW = (330, 400, 750, 1300)
LEFT = (80, 400, 500, 1300)
RIGHT = (580, 400, 1000, 1300)
OFFCENTER = (70, 430, 490, 1230)
MESSY = [(120, 470, 610, 930), (450, 540, 950, 1030),
         (170, 780, 690, 1250), (560, 880, 970, 1300)]
MESSY_TITLES = ["浏览器", "编辑器", "终端", "备忘录"]

def center_line(img, alpha=255):
    """贯穿桌面的中心辅助线：第一组建立、第二组复用、第三组收尾亮起。"""
    def fn(d, w, h):
        d.line((w // 2, 0, w // 2, h), fill=(86, 168, 255, 150), width=3)
    alpha_shape(img, (540, DESK_TOP, 543, DESK_BOT), fn, alpha)


def end_chrome(img, t):
    """片尾两镜的公共元素：macOS 角标、底部信任语、进度条。"""
    rrect(img, (70, 84, 330, 146), (43, 92, 156), radius=31)
    txt(img, (200, 115), "macOS 专属", 29, WHITE, bold=True, shadow=False)
    txt(img, (540, 1838), "不联网 · 不收集数据 · MIT 开源", 26, MUTED,
        alpha=200, shadow=False)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((70, 1896, 1010, 1902), radius=3, fill=(46, 66, 96))
    d.rounded_rectangle((70, 1896, int(lerp(70, 1010, G(t) / DUR)), 1902),
                        radius=3, fill=ACCENT)


def scene_hook(img, t):
    """镜 01 · 钩子：0–0.78s 先给「歪斜 → 瞬间居中」强反差，再回放痛点。

    主字幕全镜固定一句反问，不在镜头内闪切（延续 v1.3 的字幕节奏结论）。
    """
    draw_desktop(img)
    if t < 0.78:
        # 先亮结果：窗口自己滑到正中间
        u = ease_out(seg(t, 0.06, 0.70))
        box = lerp_rect(OFFCENTER, NARROW, u)
        center_line(img, int(235 * seg(t, 0.12, 0.55)))
        draw_window(img, box, "浏览器", narrow=True, active=True)
        if t > 0.42:
            q = seg(t, 0.42, 0.78)
            ring(img, 540, 850, int(lerp(60, 305, ease_out(q))), color=WHITE, width=7,
                 alpha=int(215 * (1 - q)))
        a = int(255 * seg(t, 0.32, 0.60))
        txt(img, (540, 470), "本来就该这样", 30, ACCENT2, bold=True,
            shadow=False, alpha=a)
    else:
        # 回放痛点：三个歪斜窗口 + 反复拖拽右下角还是没对齐
        p = t - 0.78
        for i, (b, title) in enumerate(zip(MESSY[:3], MESSY_TITLES[:3])):
            wobble = math.sin(p * 2.6 + i * 1.4) * 6
            draw_window(img, (b[0] + wobble, b[1] - wobble,
                              b[2] + wobble, b[3] - wobble),
                        title, narrow=(i != 0), active=(i == 2))
        stretch = 46 * math.sin(p * 4.2) ** 2
        b = MESSY[2]
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((b[2] - 26 + stretch, b[3] - 26 + stretch * 0.6,
                             b[2] + 12 + stretch, b[3] + 12 + stretch * 0.6),
                            radius=6, outline=WARN, width=4)
        draw_cursor(img, 700 + stretch * 0.4, 1155 + stretch * 0.3)
        a = int(255 * seg(t, 1.35, 1.65))
        rrect(img, (700, 1180, 960, 1246), (40, 60, 88), radius=20, alpha=a)
        txt(img, (830, 1213), "又没对齐", 26, WARN, bold=True,
            shadow=False, alpha=a)
    badge = int(255 * seg(t, 0.05, 0.35))
    rrect(img, (300, 248, 780, 314), (43, 92, 156), radius=33, alpha=badge)
    txt(img, (540, 281), "自动居中 · 默认开启", 30, WHITE, bold=True,
        shadow=False, alpha=badge)
    chrome(img, G(t), 1, "钩子", ["窗口还要自己摆？"],
           "每次开窗口，都得拉大小、挪位置", fade_t=t, fade_dur=0.35)


def scene_wish(img, t):
    """镜 02 · 愿望：像平板一样打开就摆好；末尾提前露出产品名。"""
    draw_desktop(img)
    u = ease_out(seg(t, 0.30, 1.75))
    box = lerp_rect(OFFCENTER, NARROW, u)
    center_line(img, int(220 * seg(t, 0.2, 0.9)))
    draw_window(img, box, "浏览器", narrow=True, active=True)
    if t > 1.5:
        q = seg(t, 1.5, 2.3)
        ring(img, 540, 850, int(lerp(60, 310, ease_out(q))), color=WHITE, width=7,
             alpha=int(200 * (1 - q)))
    rrect(img, (250, 248, 830, 314), (34, 54, 82), radius=33)
    txt(img, (540, 281), "像平板一样 · 打开就摆好", 30, ACCENT2,
        bold=True, shadow=False)
    # P1-2：产品名在约 4.7 秒（全局）先露一次，比 v2 的 6.48s 提前
    pa = int(255 * seg(t, 2.40, 2.80))
    rrect(img, (760, 600, 990, 672), (43, 92, 156), radius=22, alpha=pa)
    txt(img, (875, 636), "窗口复位器", 28, WHITE, bold=True,
        shadow=False, alpha=pa)
    chrome(img, G(t), 2, "愿望", ["要是能像平板一样", "打开就自己居中"],
           "不用点，不用拖，自己落位", fade_t=t)


def scene_intro(img, t):
    """镜 03 · 产品出场 + 新窗口自动居中。"""
    draw_desktop(img)
    rrect(img, (906, 334, 986, 390), (43, 92, 156), radius=12,
          outline=ACCENT, width=3)
    q = seg(t, 0.1, 0.8)
    ring(img, 946, 361, int(lerp(24, 76, ease_out(q))), color=ACCENT2, width=4,
         alpha=int(210 * (1 - q)))
    rrect(img, (270, 248, 810, 314), (43, 92, 156), radius=33)
    txt(img, (540, 281), "窗口复位器 · macOS 菜单栏", 30, WHITE,
        bold=True, shadow=False)
    u = ease_out(seg(t, 0.45, 1.95))
    box = lerp_rect(OFFCENTER, NARROW, u)
    center_line(img, int(230 * seg(t, 0.5, 1.2)))
    draw_window(img, box, "浏览器", narrow=True, active=True)
    if t > 1.9:
        w = seg(t, 1.9, 2.7)
        ring(img, 540, 850, int(lerp(60, 300, ease_out(w))), color=ACCENT2, width=6,
             alpha=int(190 * (1 - w)))
    chrome(img, G(t), 3, "自动居中", ["窗口复位器", "打开新窗口，自己居中"],
           "默认开启 · 常驻后台 · 不用点", fade_t=t)


def scene_mode_toggle(img, t):
    """镜 04 · 点菜单栏切换宽 / 窄；尾部用一枚角标带出「每 App 记忆」。"""
    draw_desktop(img)
    if t < 1.55:
        u = ease_inout(seg(t, 0.55, 1.05))
        box = lerp_rect(WIDE, NARROW, u)
        narrow = u > 0.5
    else:
        u = ease_inout(seg(t, 1.90, 2.40))
        box = lerp_rect(NARROW, WIDE, u)
        narrow = u < 0.5
    draw_window(img, box, "浏览器", narrow=narrow, active=True)
    for x0, x1 in [(0.45, 0.95), (1.80, 2.30)]:
        q = seg(t, x0, x1)
        if 0 < q < 1:
            ring(img, 946, 361, int(lerp(24, 92, ease_out(q))), color=WHITE, width=6,
                 alpha=int(220 * (1 - q)))
    txt(img, (860, 430), "左键", 24, MUTED, shadow=False)
    # P1-3：原独立镜 05 压缩为尾部角标，不单独占 2.9 秒
    hint_pill(img, "每个 App 各记各的模式 · 偏好只存本机", ACCENT2,
              int(255 * seg(t, 1.70, 2.10)))
    chrome(img, G(t), 4, "切换宽窄", ["点一下菜单栏", "切换宽 / 窄"],
           "宽模式 / 窄模式，尺寸变化看得见", fade_t=t)


def scene_split(img, t):
    """镜 05 · 侧拉正常分屏，靠边后静止 0.8 秒以上证明不被硬拽回。"""
    draw_desktop(img)
    u = ease_inout(seg(t, 0.25, 1.35))
    box = lerp_rect(NARROW, LEFT, u)
    draw_window(img, box, "浏览器", narrow=True, active=True)
    if u > 0.85:
        draw_cursor(img, lerp(540, 250, u), lerp(760, 850, u))
    # 1.35s 后第一个窗口完全静止，直到 2.35s 第二个窗口到位
    u2 = ease_out(seg(t, 1.45, 2.35))
    if u2 > 0:
        box2 = lerp_rect((980, 400, 1010, 1300), RIGHT, u2)
        draw_window(img, box2, "备忘录", narrow=True, active=False)
    hint_pill(img, "靠边放 · 停住不动 · 不硬拽回中间", ACCENT2,
              int(255 * seg(t, 1.55, 1.95)))
    chrome(img, G(t), 5, "分屏不打扰", ["往侧边一拉", "正常分屏，不打扰"],
           "手动放到哪，就留在哪", fade_t=t)


def scene_snapback(img, t):
    """镜 06 · 往中间靠，松手后吸回中心。"""
    draw_desktop(img)
    a = int(190 * seg(t, 0.2, 0.7))
    dashed_box(img, (300, 400, 780, 1300), color=ACCENT2, alpha=a)
    center_line(img, int(200 * seg(t, 0.3, 0.9)))
    if t < 1.8:
        u = ease_inout(seg(t, 0.25, 1.6))
        box = lerp_rect(LEFT, (250, 400, 670, 1300), u)
    else:
        u = ease_out(seg(t, 1.8, 2.55))
        box = lerp_rect((250, 400, 670, 1300), NARROW, u)
    draw_window(img, box, "浏览器", narrow=True, active=True)
    if t > 1.85:
        q = seg(t, 1.85, 2.6)
        ring(img, 540, 850, int(lerp(50, 330, ease_out(q))), color=WHITE, width=7,
             alpha=int(210 * (1 - q)))
    hint_pill(img, "中心磁吸 8% · 可调 1~20", ACCENT2,
              int(255 * seg(t, 0.55, 0.95)))
    chrome(img, G(t), 6, "吸回中心", ["往中间靠", "松手就吸回来"],
           "吸附发生在松手之后 · 范围可调", fade_t=t)


def scene_slogan(img, t):
    """镜 07 · Slogan + 隐私 / 开源 / 系统要求 / 未签名提示。"""
    u = ease_out(seg(t, 0.05, 0.7))
    draw_icon(img, 540, 700, int(230 * (0.7 + 0.3 * u)), bg=(43, 92, 156))
    if t > 0.3:
        q = seg(t, 0.3, 1.1)
        ring(img, 540, 700, int(lerp(140, 340, ease_out(q))), color=ACCENT,
             width=6, alpha=int(160 * (1 - q)))
    a = int(255 * seg(t, 0.35, 0.95))
    txt(img, (540, 960), "窗口复位器", 86, WHITE, bold=True, alpha=a)
    txt(img, (540, 1075), "窗口，自己会回中间", 54, ACCENT2, bold=True,
        alpha=int(255 * seg(t, 0.65, 1.25)))
    txt(img, (540, 1170), "不联网 · 不收集数据 · MIT 开源", 30, MUTED,
        shadow=False, alpha=int(255 * seg(t, 0.9, 1.5)))
    txt(img, (540, 1240), "仅支持 macOS 13.0 及以上 · 需辅助功能权限", 26, MUTED,
        shadow=False, alpha=int(255 * seg(t, 1.0, 1.6)))
    txt(img, (540, 1305), "首次打开：右键 → 打开（未签名）", 26, MUTED,
        shadow=False, alpha=int(255 * seg(t, 1.1, 1.7)))
    end_chrome(img, t)


def scene_outro(img, t):
    """镜 08 · 全平台合规净版收尾。

    不出现任何 URL、二维码、平台名，也不出现「见简介 / 评论区 / 扫码」等导流话术；
    下载地址与仓库链接全部外置到发布文案，使同一支片可通发各平台。
    """
    breathe = 1 + 0.02 * math.sin(t * 2.2)
    u = ease_out(seg(t, 0.05, 0.70))
    draw_icon(img, 540, 560, int(200 * (0.85 + 0.15 * u) * breathe),
              bg=(43, 92, 156))
    if t > 0.25:
        q = seg(t, 0.25, 1.05)
        ring(img, 540, 560, int(lerp(120, 300, ease_out(q))), color=ACCENT,
             width=6, alpha=int(150 * (1 - q)))
    a = int(255 * seg(t, 0.25, 0.80))
    txt(img, (540, 810), "窗口复位器", 84, WHITE, bold=True, alpha=a)
    txt(img, (540, 920), "窗口，自己会回中间", 48, ACCENT2, bold=True,
        alpha=int(255 * seg(t, 0.50, 1.05)))
    txt(img, (540, 1020), "v1.1.0 · 免费开源", 32, MUTED,
        shadow=False, alpha=int(255 * seg(t, 0.70, 1.25)))

    u2 = ease_out(seg(t, 0.90, 1.40))
    if u2 > 0:
        b = (110, 1100 + (1 - u2) * 45, 970, 1285 + (1 - u2) * 45)
        rrect(img, b, (30, 47, 74), radius=26, alpha=int(245 * u2),
              outline=PANEL_BORDER, width=2)
        a2 = int(255 * u2)
        dy = (1 - u2) * 45
        txt(img, (540, 1155 + dy), "默认开启 · 常驻后台 · 不用点", 30, WHITE,
            bold=True, shadow=False, alpha=a2)
        txt(img, (540, 1230 + dy), "纯 Swift 开发 · 无第三方依赖", 26, MUTED,
            shadow=False, alpha=a2)

    txt(img, (540, 1365), "仅支持 macOS 13.0 及以上 · 需辅助功能权限", 25, MUTED,
        shadow=False, alpha=int(255 * seg(t, 1.30, 1.80)))
    txt(img, (540, 1415), "首次打开：右键 → 打开（未签名）", 25, MUTED,
        shadow=False, alpha=int(255 * seg(t, 1.45, 1.95)))
    txt(img, (540, 1560), "macOS 专属 · 菜单栏小工具", 42, WHITE, bold=True,
        alpha=int(255 * seg(t, 1.10, 1.65)))
    end_chrome(img, t)


SCENES = [
    (SCENE_START[0], SCENE_START[1], scene_hook),        # 01 钩子 / 痛点
    (SCENE_START[1], SCENE_START[2], scene_wish),        # 02 愿望（提前露名）
    (SCENE_START[2], SCENE_START[3], scene_intro),       # 03 产品出场 / 自动居中
    (SCENE_START[3], SCENE_START[4], scene_mode_toggle), # 04 宽窄 + 记忆角标
    (SCENE_START[4], SCENE_START[5], scene_split),       # 05 侧拉分屏不打扰
    (SCENE_START[5], SCENE_START[6], scene_snapback),    # 06 吸回中心
    (SCENE_START[6], SCENE_START[7], scene_slogan),      # 07 Slogan / 信任
    (SCENE_START[7], 30.0, scene_outro),                # 08 品牌净版定格
]


def render(t):
    global CUR_START
    img = BASE.copy()
    for i, (a, b, fn) in enumerate(SCENES):
        if a <= t < b or (i == len(SCENES) - 1 and t >= b - 0.001):
            CUR_START = SCENE_START[i]
            fn(img, t - a)
            break
    else:
        CUR_START = SCENE_START[-1]
        SCENES[-1][2](img, t - SCENE_START[-1])
    return img


# ---------- 中文配音 ----------
def load_voiceover_clips(tmpdir):
    """温柔女声旁白：优先读脚本同目录 voiceover/ 的音频缓存，
    缺失时用 Edge TTS 合成并写回缓存；离线且无缓存时回退 macOS say。"""
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), VOICE_CACHE)
    os.makedirs(cache, exist_ok=True)
    clips = []
    for i, (start, text) in enumerate(VOICEOVER):
        src = os.path.join(cache, f"vo{i:02d}.mp3")
        if not os.path.exists(src):
            try:
                subprocess.run([sys.executable, "-m", "edge_tts",
                                "--voice", VOICE_NAME, "--rate", VOICE_RATE,
                                "--text", text, "--write-media", src],
                               check=True, capture_output=True, timeout=60)
                print(f"  配音 {i + 1} 缓存缺失，已联网合成", flush=True)
            except Exception:
                if os.path.exists(src):
                    os.remove(src)
                src = os.path.join(tmpdir, f"fallback{i:02d}.aiff")
                subprocess.run(["say", "-v", FALLBACK_VOICE, "-r", str(FALLBACK_RATE),
                                "-o", src, text], check=True)
                print(f"  配音 {i + 1} 使用离线兜底语音 {FALLBACK_VOICE}", flush=True)
        wavp = os.path.join(tmpdir, f"vo{i:02d}.wav")
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", src,
                        "-ar", str(SR), "-ac", "1", "-c:a", "pcm_s16le", wavp],
                       check=True)
        with wave.open(wavp, "rb") as w:
            assert w.getframerate() == SR and w.getnchannels() == 1
            raw = w.readframes(w.getnframes())
        samples = [v / 32768.0 for v in struct.unpack("<" + "h" * (len(raw) // 2), raw)]
        clips.append((start, samples))
        print(f"  配音 {i + 1}/{len(VOICEOVER)}  {start:5.2f}s 起 "
              f"{len(samples) / SR:4.2f}s  {text}", flush=True)
    return clips


# ---------- 音效 + 配音混音 ----------
def make_audio(path, clips=()):
    sr = SR
    n = sr * DUR
    buf = [0.0] * n
    rnd = random.Random(20261108)

    def add(t0, dur, fn, amp):
        s = int(t0 * sr)
        e = min(n, s + int(dur * sr))
        for i in range(max(0, s), e):
            buf[i] += amp * fn((i - s) / sr, (i - s) / sr / max(dur, 1e-6))

    def click(t0, amp=0.35):
        add(t0, 0.06, lambda x, u: math.sin(2 * math.pi * 1500 * x) * math.exp(-x * 70), amp)
        add(t0, 0.03, lambda x, u: (rnd.random() * 2 - 1) * math.exp(-x * 160), amp * 0.35)

    def whoosh(t0, amp=0.10):
        add(t0, 0.32, lambda x, u: (rnd.random() * 2 - 1) * math.sin(math.pi * u) ** 2, amp)

    def ding(t0, amp=0.20):
        add(t0, 0.55, lambda x, u: (math.sin(2 * math.pi * 880 * x) * 0.7 +
                                    math.sin(2 * math.pi * 1320 * x) * 0.3) *
                                   math.exp(-x * 7), amp)

    def kick(t0, amp=0.13):
        add(t0, 0.16, lambda x, u: math.sin(2 * math.pi * (62 - 24 * u) * x) * math.exp(-x * 22), amp)

    def hat(t0, amp=0.022):
        add(t0, 0.035, lambda x, u: (rnd.random() * 2 - 1) * math.exp(-x * 110), amp)

    # 轻量节拍（0.75 秒一拍），片尾留白给人声
    k = 0
    t0 = 0.0
    while t0 < 23.0:
        kick(t0, 0.11 if k % 4 == 0 else 0.07)
        hat(t0 + 0.375)
        t0 += 0.75
        k += 1
    # 关键音效按 v3 时间轴（SCENE_START = 0/2.25/5.60/9.10/12.15/16.00/19.10/22.75）
    for x in [0.55, 1.05, 2.45, 5.85, 7.35, 9.35, 10.55, 12.40,
              14.90, 16.25, 18.35, 19.35, 22.95, 23.70, 24.40]:
        click(x)
    for x in SCENE_START[1:]:
        whoosh(x)
    for x in [2.05, 5.20, 8.60, 11.80, 15.70, 18.85, 22.35,
              23.25, 23.95, 24.65]:
        ding(x)
    ding(26.60, 0.16)
    # 音效尾段淡出（配音随后混入，不受影响）
    fade_start = int(23.0 * sr)
    for i in range(fade_start, n):
        buf[i] *= max(0.0, 1 - (i - fade_start) / (2.0 * sr))

    # 人声区对音效做 ducking，保证旁白清晰
    duck = [1.0] * n
    ramp = int(0.12 * sr)
    for start, samples in clips:
        s = int(start * sr)
        e = min(n, s + len(samples))
        for i in range(max(0, s - ramp), min(n, e + ramp)):
            if i < s:
                f = 1.0 - 0.6 * (i - (s - ramp)) / ramp
            elif i >= e:
                f = 0.4 + 0.6 * (i - e) / ramp
            else:
                f = 0.4
            if f < duck[i]:
                duck[i] = f
    for i in range(n):
        buf[i] *= 0.5 * duck[i]
    for start, samples in clips:
        s = int(start * sr)
        L = len(samples)
        for j, v in enumerate(samples):
            idx = s + j
            if idx >= n:
                break
            env = min(1.0, j / (0.02 * sr), (L - j) / (0.03 * sr))
            buf[idx] += v * 0.95 * env

    peak = max(1e-6, max(abs(v) for v in buf))
    scale = min(1.0, 0.89 / peak)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * scale)) * 32767))
                               for v in buf))
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--audio", default="/tmp/wr_douyin_audio_v3.wav")
    ap.add_argument("--no-voice", action="store_true", help="跳过中文配音，仅保留音效")
    args = ap.parse_args()
    tmpdir = tempfile.mkdtemp(prefix="wr_voiceover_")
    clips = [] if args.no_voice else load_voiceover_clips(tmpdir)
    make_audio(args.audio, clips)
    cmd = [
        "ffmpeg", "-y", "-loglevel", "warning",
        "-f", "rawvideo", "-pixel_format", "rgb24",
        "-video_size", f"{W}x{H}", "-framerate", str(FPS), "-i", "pipe:0",
        "-i", args.audio,
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-shortest", "-movflags", "+faststart",
        "-metadata", "title=窗口复位器 · 30 秒宣传片 v3（四组八镜 · 合规净版）",
        args.output,
    ]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    for i in range(FRAMES):
        t = i / FPS
        p.stdin.write(render(t).tobytes())
        if i % 150 == 0:
            print(f"  frame {i}/{FRAMES} ({t:.1f}s)", flush=True)
    p.stdin.close()
    err = p.stderr.read().decode("utf-8", "replace")
    rc = p.wait()
    if rc != 0:
        raise SystemExit(f"ffmpeg 失败 ({rc}):\n{err}")
    print(f"完成：{args.output}  {os.path.getsize(args.output) / 1024 / 1024:.2f} MB")


if __name__ == "__main__":
    main()
