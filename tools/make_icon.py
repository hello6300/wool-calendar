"""羊毛日历 App 图标 / 品牌素材生成器。

只依赖 Pillow。所有几何都在 1024x1024 的逻辑坐标系里写，超采样 4 倍后缩小，
保证 48px 这种小尺寸也不出锯齿；同一套坐标同时导出 SVG，方便以后改色/放大。

用法：
    python tools/make_icon.py            # 生成全部资源（android res + design/branding）
    python tools/make_icon.py --preview  # 额外出小尺寸对照图（.tmp/logo）
"""

from __future__ import annotations

import argparse
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4  # 超采样倍数
BASE = 1024  # 逻辑坐标系边长
CANVAS = BASE * S

# 配色：暖橙渐变（羊毛/优惠的语感，且在深浅桌面上都够亮）+ 米白羊毛
AMBER = (255, 176, 74)
ORANGE = (244, 90, 32)
CREAM = (255, 250, 240)
WOOL = (255, 255, 255)
FACE = (242, 222, 186)
EAR = (226, 183, 130)
INK = (58, 42, 31)

# 羊头几何（scale=1 时羊毛团外径约 700px）
FLUFF_R = 250.0
BUMP_R = 96.0
BUMP_N = 11
EAR_DX, EAR_DY, EAR_RX, EAR_RY = 300.0, -70.0, 92.0, 62.0
FACE_DY, FACE_W, FACE_H, FACE_R = 30.0, 176.0, 232.0, 86.0
EYE_DX, EYE_DY, EYE_RX, EYE_RY = 54.0, 6.0, 24.0, 27.0
MOUTH_DY, MOUTH_RX, MOUTH_RY, MOUTH_W = 86.0, 48.0, 36.0, 13.0

# 品牌图（分享 / 商店）用大一点的羊头，构图更饱满。
ICON_SCALE = 0.96
# 桌面图标必须小一圈：自适应图标是 108dp 画布，桌面只保证显示中间 72dp，
# 换算到 1024 画布可见区只有 683px；羊头（含耳朵）要压在这个范围内留出余量，
# 否则小米那种圆角遮罩会把耳朵切掉。0.68 时含耳朵约 533px，占可见区 78%。
LAUNCHER_SCALE = 0.68


def hexstr(c: tuple) -> str:
    return "#%02X%02X%02X" % c[:3]


def px(v: float) -> float:
    return v * S


# ------------------------------------------------------------------ 基础绘制


def gradient(size: int, top: tuple, bottom: tuple, diagonal: bool = True) -> Image.Image:
    """线性渐变：先在 64x64 小图上按 (x+y) 算插值，再双三次放大。

    直接旋转一张竖直渐变会露出黑角；小图放大既平滑又便宜。
    """
    grid = 64
    small = Image.new("RGB", (grid, grid))
    d = ImageDraw.Draw(small)
    for y in range(grid):
        for x in range(grid):
            t = (x + y) / (2 * (grid - 1)) if diagonal else y / (grid - 1)
            d.point((x, y), fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return small.resize((size, size), Image.BICUBIC)


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def circle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    return mask


def sheep(size: int, cx: float, cy: float, scale: float, shadow: bool = True) -> Image.Image:
    """正面羊头：耳朵 → 羊毛团 → 脸 → 五官，依次叠上去。"""
    base_r, bump_r = FLUFF_R * scale, BUMP_R * scale

    ears = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    de = ImageDraw.Draw(ears)
    for sign in (-1, 1):
        ex, ey = cx + sign * EAR_DX * scale, cy + EAR_DY * scale
        de.ellipse(
            (
                px(ex - EAR_RX * scale),
                px(ey - EAR_RY * scale),
                px(ex + EAR_RX * scale),
                px(ey + EAR_RY * scale),
            ),
            fill=EAR,
        )

    fluff = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    df = ImageDraw.Draw(fluff)
    df.ellipse(
        (px(cx - base_r), px(cy - base_r), px(cx + base_r), px(cy + base_r)),
        fill=WOOL,
    )
    # 一圈小圆做出扇形波浪边，这就是“羊毛”的形。
    for i in range(BUMP_N):
        a = 2 * math.pi * i / BUMP_N - math.pi / 2
        bx = cx + base_r * math.cos(a) * 0.97
        by = cy + base_r * math.sin(a) * 0.97
        df.ellipse(
            (px(bx - bump_r), px(by - bump_r), px(bx + bump_r), px(by + bump_r)),
            fill=WOOL,
        )

    layer = Image.alpha_composite(Image.new("RGBA", (size, size), (0, 0, 0, 0)), ears)
    if shadow:
        # 淡淡的暖色投影，让白羊从暖橙背景上“浮”起来，不至于糊成一片白。
        sh = fluff.split()[3].filter(ImageFilter.GaussianBlur(px(18)))
        tint = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        tint.paste((150, 60, 15, 110), (0, int(px(14 * scale))), sh)
        layer = Image.alpha_composite(layer, tint)
    layer = Image.alpha_composite(layer, fluff)

    face = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fx, fy = cx, cy + FACE_DY * scale
    ImageDraw.Draw(face).rounded_rectangle(
        (
            px(fx - FACE_W * scale / 2),
            px(fy - FACE_H * scale / 2),
            px(fx + FACE_W * scale / 2),
            px(fy + FACE_H * scale / 2),
        ),
        radius=px(FACE_R * scale),
        fill=FACE,
    )
    layer = Image.alpha_composite(layer, face)

    feats = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dt = ImageDraw.Draw(feats)
    for sign in (-1, 1):
        ex, ey = cx + sign * EYE_DX * scale, cy + EYE_DY * scale
        dt.ellipse(
            (
                px(ex - EYE_RX * scale),
                px(ey - EYE_RY * scale),
                px(ex + EYE_RX * scale),
                px(ey + EYE_RY * scale),
            ),
            fill=INK,
        )
    my = cy + MOUTH_DY * scale
    dt.arc(
        (
            px(cx - MOUTH_RX * scale),
            px(my - MOUTH_RY * scale),
            px(cx + MOUTH_RX * scale),
            px(my + MOUTH_RY * scale),
        ),
        start=20,
        end=160,
        fill=INK,
        width=int(px(MOUTH_W * scale)),
    )
    return Image.alpha_composite(layer, feats)


# ------------------------------------------------------------------ 成品


def icon_square() -> Image.Image:
    """满幅方形底稿（用于预 26 的老图标、以及裁圆角后的分享图）。"""
    bg = gradient(CANVAS, AMBER, ORANGE).convert("RGBA")
    return Image.alpha_composite(bg, sheep(CANVAS, 512, 548, ICON_SCALE))


def icon_foreground() -> Image.Image:
    """自适应图标前景：透明底，羊头只占画布中间一小块。

    边界说明见 LAUNCHER_SCALE：桌面只会显示中间 72/108，主体必须按可见区而不是
    画布来量，否则圆形/圆角遮罩一裁就掉耳朵。
    """
    return sheep(CANVAS, 512, 540, LAUNCHER_SCALE, shadow=False)


def icon_launcher() -> Image.Image:
    """桌面用满幅图（预 26 的老图标）。主体比品牌图小，给桌面的放大/裁切留余量。"""
    bg = gradient(CANVAS, AMBER, ORANGE).convert("RGBA")
    return Image.alpha_composite(bg, sheep(CANVAS, 512, 540, LAUNCHER_SCALE))


def downscale(img: Image.Image, size: int) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


# ------------------------------------------------------------------ SVG（与位图同坐标）


def svg_mark() -> str:
    """按同一套几何导出矢量图标：渐变底 + 羊头。"""
    cx, cy, scale = 512.0, 548.0, ICON_SCALE
    base_r, bump_r = FLUFF_R * scale, BUMP_R * scale
    parts: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{BASE}" height="{BASE}" '
        f'viewBox="0 0 {BASE} {BASE}" role="img" aria-label="羊毛日历">',
        "  <defs>",
        '    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">',
        f'      <stop offset="0" stop-color="{hexstr(AMBER)}"/>',
        f'      <stop offset="1" stop-color="{hexstr(ORANGE)}"/>',
        "    </linearGradient>",
        "  </defs>",
        f'  <rect width="{BASE}" height="{BASE}" rx="230" fill="url(#bg)"/>',
        "  <g>",
    ]
    for sign in (-1, 1):
        parts.append(
            f'    <ellipse cx="{cx + sign * EAR_DX * scale:.1f}" cy="{cy + EAR_DY * scale:.1f}" '
            f'rx="{EAR_RX * scale:.1f}" ry="{EAR_RY * scale:.1f}" fill="{hexstr(EAR)}"/>'
        )
    parts.append(f'    <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{base_r:.1f}" fill="{hexstr(WOOL)}"/>')
    for i in range(BUMP_N):
        a = 2 * math.pi * i / BUMP_N - math.pi / 2
        parts.append(
            f'    <circle cx="{cx + base_r * math.cos(a) * 0.97:.1f}" '
            f'cy="{cy + base_r * math.sin(a) * 0.97:.1f}" r="{bump_r:.1f}" fill="{hexstr(WOOL)}"/>'
        )
    fy = cy + FACE_DY * scale
    parts.append(
        f'    <rect x="{cx - FACE_W * scale / 2:.1f}" y="{fy - FACE_H * scale / 2:.1f}" '
        f'width="{FACE_W * scale:.1f}" height="{FACE_H * scale:.1f}" '
        f'rx="{FACE_R * scale:.1f}" fill="{hexstr(FACE)}"/>'
    )
    for sign in (-1, 1):
        parts.append(
            f'    <ellipse cx="{cx + sign * EYE_DX * scale:.1f}" cy="{cy + EYE_DY * scale:.1f}" '
            f'rx="{EYE_RX * scale:.1f}" ry="{EYE_RY * scale:.1f}" fill="{hexstr(INK)}"/>'
        )
    # 微笑：与 PIL 的 arc(20°,160°) 同一条弧
    my = cy + MOUTH_DY * scale
    rx, ry = MOUTH_RX * scale, MOUTH_RY * scale
    x1 = cx + rx * math.cos(math.radians(20))
    y1 = my + ry * math.sin(math.radians(20))
    x2 = cx + rx * math.cos(math.radians(160))
    y2 = my + ry * math.sin(math.radians(160))
    parts.append(
        f'    <path d="M {x1:.1f} {y1:.1f} A {rx:.1f} {ry:.1f} 0 0 1 {x2:.1f} {y2:.1f}" '
        f'fill="none" stroke="{hexstr(INK)}" stroke-width="{MOUTH_W * scale:.1f}" '
        f'stroke-linecap="round"/>'
    )
    parts.append("  </g>")
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


# ------------------------------------------------------------------ 落地到工程


def write_android(res: str) -> None:
    square = icon_launcher()
    fg = icon_foreground()
    round_img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    round_img.paste(square, (0, 0), circle_mask(CANVAS))

    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for dpi, size in legacy.items():
        out = os.path.join(res, f"mipmap-{dpi}")
        os.makedirs(out, exist_ok=True)
        downscale(square, size).save(os.path.join(out, "ic_launcher.png"), optimize=True)
        # 圆形图标：给声明了 android:roundIcon 的桌面用
        downscale(round_img, size).save(os.path.join(out, "ic_launcher_round.png"), optimize=True)
        # 自适应图标前景：108dp 画布
        fg_size = int(round(size * 108 / 48))
        downscale(fg, fg_size).save(
            os.path.join(out, "ic_launcher_foreground.png"), optimize=True
        )
        print(f"   mipmap-{dpi}: 图标 {size}px / 前景 {fg_size}px")

    # 自适应图标（API 26+）
    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n"
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(adaptive)
        print("  ", os.path.join(anydpi, name))

    # 自适应背景：暖橙对角渐变（angle=315 → 左上到右下，和位图一致）
    drawable = os.path.join(res, "drawable", "ic_launcher_background.xml")
    os.makedirs(os.path.dirname(drawable), exist_ok=True)
    with open(drawable, "w", encoding="utf-8", newline="\n") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<shape xmlns:android="http://schemas.android.com/apk/res/android" '
            'android:shape="rectangle">\n'
            f'    <gradient android:angle="315" android:type="linear"\n'
            f'        android:startColor="{hexstr(AMBER)}"\n'
            f'        android:endColor="{hexstr(ORANGE)}"/>\n'
            "</shape>\n"
        )
    print("  ", drawable)


def write_lockup(out_dir: str) -> None:
    """横版组合标志：左侧圆角图标，右侧「羊毛日历」+ 一句话定位。"""
    w, h = 1600, 640
    icon_px = 448
    icon = downscale(icon_square(), icon_px)
    mask = rounded_mask(icon_px, icon_px * 0.225)
    bold = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 176)
    light = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 62)

    for name, bg, title, sub in (
        ("logo-lockup.png", None, (38, 32, 28), (140, 120, 104)),
        ("logo-lockup-dark.png", (26, 20, 17, 255), (255, 248, 240), (198, 176, 158)),
    ):
        img = Image.new("RGBA", (w, h), bg if bg else (0, 0, 0, 0))
        img.paste(icon, (72, (h - icon_px) // 2), mask)
        d = ImageDraw.Draw(img)
        d.text((592, 158), "羊毛日历", font=bold, fill=title)
        d.text((600, 402), "每台设备各领一次，不漏不丢", font=light, fill=sub)
        img.save(os.path.join(out_dir, name), optimize=True)


def write_branding(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    square = icon_square()

    # 1) 圆角方图：分享 / 应用商店
    rounded = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    rounded.paste(square, (0, 0), rounded_mask(CANVAS, px(230)))
    downscale(rounded, 1024).save(os.path.join(out_dir, "icon-1024.png"), optimize=True)

    # 2) 满幅方图：有些平台自己裁形状
    downscale(square, 1024).save(os.path.join(out_dir, "icon-square-1024.png"), optimize=True)

    # 3) 透明前景：自适应图标 / 二次排版
    downscale(icon_foreground(), 1024).save(
        os.path.join(out_dir, "icon-foreground-1024.png"), optimize=True
    )

    write_lockup(out_dir)

    with open(os.path.join(out_dir, "logo.svg"), "w", encoding="utf-8", newline="\n") as f:
        f.write(svg_mark())
    print("  ", out_dir, "(icon / lockup / svg)")


def preview(out_dir: str) -> None:
    """把成品按真实小尺寸排一张对照图，确认 48px 下还认得出。"""
    os.makedirs(out_dir, exist_ok=True)
    sizes = (48, 72, 96, 144)
    pad = 40
    sheet = Image.new("RGB", (sum(s * 2 + pad for s in sizes) + pad, 300), (245, 245, 245))
    x = pad
    for s in sizes:
        small = downscale(icon_square(), s)
        sheet.paste(small.resize((s * 2, s * 2), Image.NEAREST), (x, 80))
        x += s * 2 + pad
    sheet.save(os.path.join(out_dir, "preview-sizes.png"))
    print("预览：", os.path.join(out_dir, "preview-sizes.png"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--res", default="android/app/src/main/res")
    ap.add_argument("--branding", default="design/branding")
    args = ap.parse_args()

    print("Android 图标：")
    write_android(args.res)
    print("品牌素材：")
    write_branding(args.branding)
    if args.preview:
        preview(os.path.join(".tmp", "logo"))
