#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""窗口复位器 · 抖音 30 秒竖屏宣传片逐帧渲染器（1080x1920 / 30fps）。

画面为按项目真实功能绘制的「仿录屏」动效，非真实屏幕录制。
叙事主线：窗口自动居中（主角） > 点击复位与宽窄切换（可选操作） > 隐私与开源。
全片不出现多显示器 / 跨屏相关表述。
中文配音为温柔女声（Edge TTS zh-CN-XiaoxiaoNeural，官方标签 Warm），
音频缓存在脚本同目录 voiceover/，离线也能重渲染。
用法：python3 render_douyin_video.py --output <path.mp4>
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
# 各场景起点（秒）。场景函数内部一律使用「相对本场景起点」的局部时间，
# 需要全局时间（进度条等）时用 G() 换算，方便随配音调整分镜长度。
# 0–13s 讲窗口自动居中；13–19.4s 点击复位（可选操作）；19.4s 后信任卡与片尾。
SCENE_START = [0.0, 4.8, 9.4, 13.0, 14.6, 17.0, 19.4, 23.8]
CUR_START = 0.0


def G(local_t):
    """局部时间 → 全局时间。"""
    return local_t + CUR_START


# 温柔女声：Edge TTS 晓晓（Warm），语速 +10%；缓存缺失时才联网合成。
VOICE_NAME = "zh-CN-XiaoxiaoNeural"
VOICE_RATE = "+10%"
FALLBACK_VOICE = "Tingting"     # 无缓存且离线时的兜底
FALLBACK_RATE = 200
# 旁白：(起点秒, 文案)。7 段合计约 26s，段间留呼吸。
VOICEOVER = [
    (0.25, "窗口不用你摆，窗口复位器，让它自动居中。"),
    (4.95, "拖歪了，松手就吸回来；靠边放，就不打扰。"),
    (9.55, "磁吸范围自己调，新窗口自动落位。"),
    (13.15, "想更规整？菜单栏顺手点一下。"),
    (16.95, "再点一下，切换宽窄。"),
    (19.55, "不联网，不收集数据，代码开源。"),
    (23.95, "窗口复位器，macOS 小工具，让窗口自己回中间。"),
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


# ---------- 各镜头 ----------
WIDE = (120, 400, 960, 1300)
NARROW = (330, 400, 750, 1300)
LEFT = (80, 400, 500, 1300)
OFFCENTER = (70, 430, 490, 1230)   # 开场：明显偏离中心，便于展示自动归位
MESSY = [(120, 470, 610, 930), (450, 540, 950, 1030),
         (170, 780, 690, 1250), (560, 880, 970, 1300)]
MESSY_TITLES = ["浏览器", "编辑器", "终端", "备忘录"]


def scene_auto(img, t):
    """开场主角：窗口自动居中（默认开启）。
    新窗口自动落位 → 手动拖开 → 松手自己回中间。

    字幕节奏与配音对齐：这段只有一句旁白（0.25s 起），所以主字幕整段
    4.8 秒保持不变，只在开头柔和淡入一次；辅助说明也只用一条稳定胶囊。
    三个动作交给画面动效表达，文字不再跟着闪切。
    """
    draw_desktop(img)
    dashed_box(img, (300, 400, 780, 1300), color=ACCENT2,
               alpha=int(110 + 75 * seg(t, 0.2, 0.9)))
    if t < 1.9:
        u = ease_out(seg(t, 0.30, 1.55))
        box = lerp_rect(OFFCENTER, NARROW, u)
    elif t < 3.35:
        u = ease_inout(seg(t, 2.05, 3.05))
        box = lerp_rect(NARROW, OFFCENTER, u)
        draw_cursor(img, lerp(540, 250, u), lerp(760, 900, u))
    else:
        u = ease_out(seg(t, 3.40, 4.35))
        box = lerp_rect(OFFCENTER, NARROW, u)
        if t > 3.9:
            q = seg(t, 3.9, 4.55)
            ring(img, 540, 850, int(lerp(60, 320, ease_out(q))), color=WHITE, width=7,
                 alpha=int(210 * (1 - q)))
    draw_window(img, box, "浏览器", narrow=True, active=True)
    # 开场卖点徽标（面板上方，避开桌面区）
    badge_a = int(255 * seg(t, 0.05, 0.45))
    rrect(img, (270, 248, 810, 318), (43, 92, 156), radius=35, alpha=badge_a)
    txt(img, (540, 283), "窗口自动居中 · 默认开启", 32, WHITE, bold=True,
        shadow=False, alpha=badge_a)
    # 一条稳定辅助说明，覆盖「拖开 / 松手回中间」两个动作，不做三段轮播
    hint_pill(img, "拖开也没关系 · 松手自己回中间", ACCENT2,
              int(255 * seg(t, 1.25, 1.85)))
    chrome(img, G(t), 1, "自动居中", ["窗口，自己会居中", "不用点 · 默认开启"],
           "macOS 菜单栏小工具 · 常驻后台，默认开启", fade_t=t, fade_dur=0.5)


def scene_click(img, t):
    draw_desktop(img, 0.72)
    cx, cy = 540, 830
    pulse = 1 + 0.06 * math.sin(t * 6)
    draw_icon(img, cx, cy, int(210 * pulse), bg=(43, 92, 156))
    # 脉冲圈
    for k in range(2):
        u = ((t - 0.1) / 0.9 + k * 0.5) % 1.0
        ring(img, cx, cy, int(lerp(130, 260, u)), color=ACCENT, width=5,
             alpha=int(170 * (1 - u)))
    # 点击波纹
    u = seg(t, 0.75, 1.25)
    if 0 < u < 1:
        ring(img, cx, cy, int(lerp(60, 300, ease_out(u))), color=WHITE, width=8,
             alpha=int(230 * (1 - u)))
    draw_cursor(img, cx + 40, cy + 46)
    txt(img, (540, 1090), "macOS 菜单栏图标 · 左键", 34, MUTED, shadow=False)
    chrome(img, G(t), 4, "顺手一按", ["想更规整？顺手点一下"],
           "可选操作 · 自动居中才是主角", tag="可选操作")


def scene_snap(img, t):
    draw_desktop(img)
    u = ease_out(seg(t, 0.15, 1.25))
    box = lerp_rect(MESSY[0], WIDE, u)
    draw_window(img, box, "浏览器", narrow=False, active=True)
    if t < 0.55:
        q = seg(t, 0.05, 0.55)
        ring(img, 946, 361, int(lerp(24, 90, ease_out(q))), color=WHITE, width=6,
             alpha=int(220 * (1 - q)))
    if u > 0.9:
        a = int(255 * seg(t, 1.20, 1.55))
        d = ImageDraw.Draw(img)
        d.line((540, DESK_TOP, 540, DESK_BOT), fill=(46, 74, 116), width=2)
        hint_pill(img, "已摆正 · 顺手规整", ACCENT2, a)
    chrome(img, G(t), 5, "一键摆正", ["点一下，摆正"], "上下铺满可见区 · 水平居中",
           tag="可选操作")


def scene_mode(img, t):
    draw_desktop(img)
    u = ease_inout(seg(t, 0.35, 1.35))
    box = lerp_rect(WIDE, NARROW, u)
    draw_window(img, box, "浏览器", narrow=(u > 0.5), active=True)
    if t < 0.6:
        q = seg(t, 0.2, 0.6)
        ring(img, 946, 361, int(lerp(24, 90, ease_out(q))), color=WHITE, width=6,
             alpha=int(220 * (1 - q)))
    # 每个 App 记住自己的模式
    a = int(255 * seg(t, 1.6, 2.2))
    tags = [("浏览器 · 窄", ACCENT), ("编辑器 · 宽", ACCENT2), ("终端 · 窄", WARN)]
    for i, (s, c) in enumerate(tags):
        x0 = 120 + i * 300
        rrect(img, (x0, 1392, x0 + 270, 1442), (30, 48, 76), radius=22, alpha=a)
        txt(img, (x0 + 135, 1417), s, 26, c, bold=True, shadow=False, alpha=a)
    chrome(img, G(t), 6, "宽窄切换", ["再点一下，宽窄切换"], "每个 App，各记各的模式",
           tag="可选操作")


def scene_adaptive(img, t):
    draw_desktop(img)
    if t < 2.0:
        u = ease_out(seg(t, 0.15, 1.25))
        box = lerp_rect(NARROW, LEFT, u)
        draw_window(img, box, "浏览器", narrow=True, active=True)
        if u > 0.85:
            a = int(255 * seg(t, 1.2, 1.6))
            rrect(img, (620, 430, 950, 500), (40, 60, 88), radius=20, alpha=a)
            txt(img, (785, 465), "已固定 · 不打扰", 26, ACCENT2, bold=True, shadow=False, alpha=a)
        chrome(img, G(t), 2, "靠边不打扰", ["靠边放，就不打扰"], "手动放到哪，就留在哪 · 自动居中默认开启",
               fade_t=t)
    else:
        u = ease_inout(seg(t, 2.25, 3.45))
        box = lerp_rect(LEFT, NARROW, u)
        # 中心磁吸范围
        a = int(190 * seg(t, 2.05, 2.5))
        dashed_box(img, (300, 400, 780, 1300), color=ACCENT2, alpha=a)
        hint_pill(img, "中心磁吸范围 8%（可调 1~20）", ACCENT2, a)
        draw_window(img, box, "浏览器", narrow=True, active=True)
        if t > 3.3:
            q = seg(t, 3.3, 3.95)
            ring(img, 540, 850, int(lerp(50, 330, ease_out(q))), color=WHITE, width=7,
                 alpha=int(210 * (1 - q)))
        chrome(img, G(t), 2, "自动吸回", ["松手，自己回中间"], "松开鼠标后吸附到中心 · 磁吸范围 8% 可调",
               fade_t=t - 2.0)


DETAIL_CARDS = [
    ("01", "新窗口自动落位", "打开就居中，不用手动摆"),
    ("02", "中心磁吸 8% 可调", "拖回中心自动吸住，范围 1~20%"),
    ("03", "拉伸也锁住中心", "改窗口大小，中心不跑"),
]


def scene_details(img, t):
    """自动居中的三个细节。按口径要求，不出现多显示器 / 跨屏内容。"""
    draw_desktop(img, 0.55)
    for i, (num, title, desc) in enumerate(DETAIL_CARDS):
        appear = 0.15 + i * 0.55
        u = ease_out(seg(t, appear, appear + 0.35))
        if u <= 0:
            continue
        y = 470 + i * 270
        col = ACCENT if i != 1 else ACCENT2
        shifted = (120, y + (1 - u) * 45, 960, y + 230 + (1 - u) * 45)
        rrect(img, shifted, (30, 47, 74), radius=24, alpha=int(245 * u), outline=col, width=2)
        txt(img, (215, y + 115), num, 62, col, bold=True, shadow=False, alpha=int(255 * u))
        txt(img, (340, y + 82), title, 38, WHITE, bold=True, shadow=False,
            anchor="lm", alpha=int(255 * u))
        txt(img, (340, y + 158), desc, 26, MUTED, shadow=False,
            anchor="lm", alpha=int(255 * u))
    hint_pill(img, "常驻后台 · 默认开启 · 不用点", ACCENT2,
              int(255 * seg(t, 1.7, 2.1)))
    chrome(img, G(t), 3, "一直都在", ["自动居中，一直在", "不用点，自己回中间"],
           "macOS 菜单栏小工具 · 常驻服务，独立于点击复位")


TRUST = [
    ("不联网", "运行期无网络请求"),
    ("不收集数据", "偏好只存本机"),
    ("纯 Swift 无依赖", "AppKit / SwiftUI"),
    ("MIT 开源", "源码可自行审计"),
]


def draw_trust_icon(img, cx, cy, kind, color, alpha=255):
    """用线条绘制四种信任状图标，避免特殊字形缺字。"""
    r = 76
    def fn(d, w, h):
        c = color + (255,)
        if kind == 0:  # 信号关闭
            for k in range(3):
                p = 16 + k * 21
                d.arc((p, p, w - p, h - p), start=200, end=340, fill=c, width=7)
            d.line((12, h - 14, w - 12, 14), fill=c, width=8)
        elif kind == 1:  # 盾牌 + 勾
            pts = [(w / 2, 8), (w - 14, 30), (w - 14, h - 44),
                   (w / 2, h - 10), (14, h - 44), (14, 30)]
            d.line(pts + [pts[0]], fill=c, width=7, joint="curve")
            d.line((w / 2 - 24, h / 2 - 2, w / 2 - 6, h / 2 + 18, w / 2 + 28, h / 2 - 20),
                   fill=c, width=7)
        elif kind == 2:  # 尖括号
            d.line((w / 2 - 6, 20, w / 2 - 46, h / 2, w / 2 - 6, h - 20), fill=c, width=8)
            d.line((w / 2 + 6, 20, w / 2 + 46, h / 2, w / 2 + 6, h - 20), fill=c, width=8)
        else:  # 打开的书
            d.rounded_rectangle((14, 20, w - 14, h - 20), radius=10, outline=c, width=7)
            d.line((w / 2, 20, w / 2, h - 20), fill=c, width=7)
            d.line((28, 46, w / 2 - 14, 46), fill=c, width=6)
            d.line((w / 2 + 14, 46, w - 28, 46), fill=c, width=6)
    alpha_shape(img, (cx - r, cy - r, cx + r, cy + r), fn, alpha)


def scene_trust(img, t):
    draw_desktop(img, 0.62)
    cards = [(120, 470, 520, 830), (560, 470, 960, 830),
             (120, 860, 520, 1220), (560, 860, 960, 1220)]
    for i, (b, (title, desc)) in enumerate(zip(cards, TRUST)):
        appear = 0.2 + i * 1.0
        u = ease_out(seg(t, appear, appear + 0.4))
        if u <= 0:
            continue
        col = ACCENT if i % 2 == 0 else ACCENT2
        shifted = (b[0], b[1] + (1 - u) * 60, b[2], b[3] + (1 - u) * 60)
        rrect(img, shifted, (30, 47, 74), radius=24, alpha=int(245 * u), outline=col, width=2)
        draw_trust_icon(img, b[0] + 200, b[1] + 110, i, col, int(255 * u))
        txt(img, (b[0] + 200, b[1] + 218), title, 38, WHITE, bold=True, shadow=False,
            alpha=int(255 * u))
        txt(img, (b[0] + 200, b[1] + 278), desc, 26, MUTED, shadow=False, alpha=int(255 * u))
    chrome(img, G(t), 7, "信任", ["不联网 · 不收集数据", "纯 Swift 无依赖 · MIT 开源"],
           "PRIVACY.md 与仓库源码均可自行核对")


def scene_end(img, t):
    u = ease_out(seg(t, 0.05, 0.7))
    draw_icon(img, 540, 700, int(230 * (0.7 + 0.3 * u)), bg=(43, 92, 156))
    if t > 0.3:
        q = seg(t, 0.3, 1.1)
        ring(img, 540, 700, int(lerp(140, 340, ease_out(q))), color=ACCENT, width=6,
             alpha=int(160 * (1 - q)))
    a = int(255 * seg(t, 0.4, 1.0))
    txt(img, (540, 960), "窗口复位器", 86, WHITE, bold=True, alpha=a)
    # 主 Slogan：自动居中；点击复位降为次要小字
    txt(img, (540, 1075), "窗口，自己会回中间", 54, ACCENT2, bold=True,
        alpha=int(255 * seg(t, 0.7, 1.3)))
    txt(img, (540, 1160), "点一下，就正了（可选）", 30, MUTED, shadow=False,
        alpha=int(255 * seg(t, 0.9, 1.5)))
    b = int(255 * seg(t, 1.2, 1.8))
    rrect(img, (270, 1230, 810, 1320), (43, 92, 156), radius=44, alpha=b)
    txt(img, (540, 1275), "下载与源码见简介", 38, WHITE, bold=True, shadow=False, alpha=b)
    txt(img, (540, 1400), "仅支持 macOS 13.0 及以上 · 需辅助功能权限", 28, MUTED,
        shadow=False, alpha=b)
    txt(img, (540, 1460), "Gitee / GitHub：window-resetter", 26, MUTED,
        shadow=False, alpha=b)
    b2 = int(255 * seg(t, 0.1, 0.5))
    rrect(img, (70, 84, 330, 146), (43, 92, 156), radius=31, alpha=b2)
    txt(img, (200, 115), "macOS 专属", 29, WHITE, bold=True, shadow=False, alpha=b2)
    # 进度条
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((70, 1896, 1010, 1902), radius=3, fill=(46, 66, 96))
    d.rounded_rectangle((70, 1896, int(lerp(70, 1010, G(t) / DUR)), 1902), radius=3, fill=ACCENT)


SCENES = [
    (SCENE_START[0], SCENE_START[1], scene_auto),       # 窗口自动居中（开场主角）
    (SCENE_START[1], SCENE_START[2], scene_adaptive),   # 靠边不打扰 / 松手吸回
    (SCENE_START[2], SCENE_START[3], scene_details),    # 自动居中三细节
    (SCENE_START[3], SCENE_START[4], scene_click),      # 可选：菜单栏顺手一点
    (SCENE_START[4], SCENE_START[5], scene_snap),       # 可选：一键摆正
    (SCENE_START[5], SCENE_START[6], scene_mode),       # 可选：宽窄切换
    (SCENE_START[6], SCENE_START[7], scene_trust),      # 信任卡
    (SCENE_START[7], 30.0, scene_end),                  # 片尾
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
        scene_end(img, t - SCENE_START[-1])
    return img


# ---------- 中文配音 ----------
def load_voiceover_clips(tmpdir):
    """温柔女声旁白：优先读脚本同目录 voiceover/ 的音频缓存，
    缺失时用 Edge TTS 合成并写回缓存；离线且无缓存时回退 macOS say。"""
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voiceover")
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
    while t0 < 23.8:
        kick(t0, 0.11 if k % 4 == 0 else 0.07)
        hat(t0 + 0.375)
        t0 += 0.75
        k += 1
    # 关键音效按新时间轴
    for x in [1.55, 4.35, 6.20, 8.60, 9.60, 13.40, 14.80, 17.20, 18.20]:
        click(x)
    for x in SCENE_START[1:]:
        whoosh(x)
    for x in [19.6, 20.6, 21.6, 22.6]:
        ding(x)
    ding(24.2, 0.16)
    # 音效尾段淡出（配音随后混入，不受影响）
    fade_start = int(23.8 * sr)
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
    ap.add_argument("--audio", default="/tmp/wr_douyin_audio.wav")
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
        "-metadata", "title=窗口复位器 · 30 秒宣传片（窗口自动居中 · 温柔女声）",
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
