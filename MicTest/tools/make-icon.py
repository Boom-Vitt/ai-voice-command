#!/usr/bin/env python3
"""Regenerates MicTest's app icon (Sources/MicTest/MicTest.icns) from code.

NOT part of build.sh -- build.sh consumes the committed .icns. This script
exists so the artwork stays editable: there is no .sketch or .psd behind the
icon, this file IS the icon. Run it only when the design changes:

    python3 tools/make-icon.py Sources/MicTest/MicTest.icns

WHY THE 16px GLYPH IS A DIFFERENT DRAWING:
An .iconset is ten independent images, not one image scaled ten ways, and the
16x16 slot needs to be drawn differently or it lies about what the app is. At
16px the squircle is ~13px across, and the first draft -- SF `mic`'s capsule +
yoke arc + stem, downsampled -- collapsed into a recognisable *download arrow*:
the yoke arms merged into the capsule to form an arrowhead and the stem became
its shaft. A wrong-and-specific reading is worse than a vague one, especially in
the Force Quit list. The stem is the culprit, so DRAW_STEM_ABOVE drops it at
16px, leaving capsule + cradle, which reads as a microphone with nothing else to
mistake it for. Every size from 32px up keeps the full silhouette. Both were
checked by rasterising the finished .icns through NSImage and looking at the
result magnified on light and dark; re-check that way before changing anything
here.

OTHER DECISIONS, because they are decisions and not taste:
  * The glyph mirrors the SF Symbol `mic` silhouette so the bundle icon and the
    NSStatusItem glyph read as one product. The status item keeps its own SF
    Symbols and its state colours; this only echoes their shape.
  * Record-red, not the usual blue/violet. The icon's job is recognition in
    System Settings > Privacy > Microphone, a list dominated by blue and purple
    (Zoom, Discord, Teams, Slack); red is both the odd one out there and the
    universal "capturing audio" colour. An opaque saturated fill also keeps its
    silhouette against a light Finder row and a dark one.
  * No Thai lettering. A Thai character inside the shape lands well under 2px of
    stroke at 16px and smears to grey. A cue nobody can resolve is not a cue.
  * Strokes are specified as a target width in FINAL pixels at small sizes, not
    as a fraction of the shape. Rounding a fraction up at supersample scale is
    how the 16px and 32px weights drifted apart by ~20% in the first draft.
"""
import math
import os
import shutil
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter

# Apple's icon grid: an 824x824 rounded shape centred on a 1024x1024 canvas.
SHAPE_FRACTION = 824.0 / 1024.0
SQUIRCLE_N = 5.0                    # superellipse exponent; ~5 ≈ Apple's squircle
GRADIENT_TOP = (0xFF, 0x5A, 0x5F)
GRADIENT_BOTTOM = (0xB3, 0x0F, 0x33)
GLYPH = (255, 255, 255, 255)

DRAW_STEM_ABOVE = 16                # sizes <= this get the simplified glyph
ARC_STROKE = 0.058                  # fraction of glyph box, sizes with no override
TARGET_STROKE_PX = {16: 1.6, 32: 2.2}   # final-pixel stroke widths for small slots
GLYPH_SCALE = {16: 1.20, 32: 1.14}      # small slots carry a slightly larger glyph
GLYPH_SCALE_DEFAULT = 1.05

ICONSET_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                 (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def superellipse(cx, cy, half, n, steps=1024):
    """Points of |x/half|^n + |y/half|^n = 1, centred on (cx, cy)."""
    pts = []
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(ct) ** (2.0 / n), ct),
                    cy + half * math.copysign(abs(st) ** (2.0 / n), st)))
    return pts


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        f = y / max(size - 1, 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * f) for i in range(3))
    return grad.resize((size, size), Image.NEAREST)


def draw_shape(ss):
    """The gradient-filled squircle, with a top-weighted inner rim."""
    L = ss * SHAPE_FRACTION
    cx = cy = ss / 2.0
    mask = Image.new("L", (ss, ss), 0)
    ImageDraw.Draw(mask).polygon(superellipse(cx, cy, L / 2, SQUIRCLE_N), fill=255)

    icon = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    icon.paste(vertical_gradient(ss, GRADIENT_TOP, GRADIENT_BOTTOM), (0, 0))
    icon.putalpha(mask)

    # Inner rim, brightest at the top and gone by the bottom. Without it the dark
    # end of the gradient dissolves into a dark Finder row or a dark desktop.
    rim_w = max(int(round(ss * 0.0045)), 1)
    eroded = mask.filter(ImageFilter.MinFilter(rim_w * 2 + 1))
    rim = Image.composite(Image.new("L", (ss, ss), 0), mask, eroded)
    rim = Image.composite(vertical_gradient(ss, (110,) * 3, (0,) * 3).convert("L"),
                          Image.new("L", (ss, ss), 0), rim)
    icon.alpha_composite(Image.merge("RGBA", (Image.new("L", (ss, ss), 255),) * 3 + (rim,)))
    return icon, L, cx, cy


def draw_glyph(ss, L, cx, cy, scale, stroke, with_stem):
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    g = L * scale
    if with_stem:
        hw, hh, top = g * 0.215, g * 0.40, cy - g * 0.30
        ar, ay, a0, a1 = g * 0.225, cy - g * 0.030, 15, 165
    else:
        # No stem: see DRAW_STEM_ABOVE. The cradle is widened and its arms
        # shortened so they cannot fuse with the capsule into an arrowhead.
        hw, hh, top = g * 0.200, g * 0.40, cy - g * 0.32
        ar, ay, a0, a1 = g * 0.270, cy - g * 0.045, 20, 160
    d.rounded_rectangle([cx - hw / 2, top, cx + hw / 2, top + hh], radius=hw / 2, fill=GLYPH)
    d.arc([cx - ar, ay - ar, cx + ar, ay + ar], start=a0, end=a1, fill=GLYPH, width=stroke)
    # Round the cradle's ends. PIL strokes an arc with butt caps; SF Symbols uses
    # round ones, and the flat ends read as chipped next to the capsule. PIL's
    # arc grows INWARD from the bounding box, so the centreline sits at ar - w/2.
    rc = ar - stroke / 2.0
    for ang in (a0, a1):
        ex = cx + rc * math.cos(math.radians(ang))
        ey = ay + rc * math.sin(math.radians(ang))
        d.ellipse([ex - stroke / 2.0, ey - stroke / 2.0,
                   ex + stroke / 2.0, ey + stroke / 2.0], fill=GLYPH)
    if with_stem:
        d.rounded_rectangle([cx - stroke / 2, ay + ar - stroke / 2,
                             cx + stroke / 2, cy + g * 0.31], radius=stroke / 2, fill=GLYPH)
    return im


def render(size):
    # Cap the working buffer at 2048^2: supersampling a 1024px icon 8x would
    # allocate ~270MB, and this machine has run out of disk before.
    ss = max(min(size * 8, 2048), size)
    ssf = ss / size
    icon, L, cx, cy = draw_shape(ss)
    scale = GLYPH_SCALE.get(size, GLYPH_SCALE_DEFAULT)
    if size in TARGET_STROKE_PX:
        stroke = max(int(round(TARGET_STROKE_PX[size] * ssf)), 1)
    else:
        stroke = max(int(round(L * scale * ARC_STROKE)), 1)
    icon.alpha_composite(draw_glyph(ss, L, cx, cy, scale, stroke, size > DRAW_STEM_ABOVE))
    return icon.resize((size, size), Image.LANCZOS) if ss != size else icon


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "MicTest.icns")
    workdir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.dirname(out)
    iconset = os.path.join(workdir, "MicTest.iconset")
    # iconutil rejects an .iconset holding anything but the ten exact filenames,
    # and one stray .DS_Store is enough to fail it. Rebuild the directory clean.
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for basesz, scale in ICONSET_SIZES:
        suffix = "" if scale == 1 else "@2x"
        render(basesz * scale).save(os.path.join(iconset, f"icon_{basesz}x{basesz}{suffix}.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    main()
