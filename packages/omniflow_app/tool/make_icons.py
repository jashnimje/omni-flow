"""Builds OmniFlow's launcher, adaptive, themed and notification icons from
the logo source: the mark is cut out of its dark tile with a soft alpha, then
every size is a high-quality downscale of that one cut-out.

Run from the repository root with Pillow and numpy installed:

    python3 packages/omniflow_app/tool/make_icons.py \
        docs/brand/omniflow-logo-source.png packages/omniflow_app docs/brand
"""

import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw

source = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
brand = pathlib.Path(sys.argv[3])
res = app / "android/app/src/main/res"

BG = (13, 15, 18)  # OmniColors.background, 0xFF0D0F12
TILE_BG = np.array([5, 8, 11], dtype=float)  # the source's tile

rgb = np.asarray(Image.open(source).convert("RGB")).astype(float)
# Coverage from how far green rises above the tile: the mark's darkest
# shading is far above 60, so it stays opaque, and the antialiased rim
# fades smoothly.
alpha = np.clip((rgb[:, :, 1] - 14.0) / 56.0, 0, 1)
# Outside the tile (the black margin) is never the mark.
outside = rgb.sum(axis=2) < 8
alpha[outside] = 0
# Undo the blend with the tile so the rim keeps the mark's colour.
safe = np.maximum(alpha, 1e-3)[..., None]
colour = np.clip((rgb - (1 - alpha[..., None]) * TILE_BG) / safe, 0, 255)
rgba = np.dstack([colour, alpha * 255]).astype(np.uint8)
mark = Image.fromarray(rgba)

ys, xs = np.where(alpha > 0.05)
box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
mark = mark.crop(box)
cx = (box[2] - box[0]) / 2
cy = (box[3] - box[1]) / 2
a = np.asarray(mark)[:, :, 3] > 5
yy, xx = np.nonzero(a)
radius = float(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2).max())
print("mark", mark.size, "radius", round(radius, 1))


def mark_on(size, mark_radius, background=None, tint=None):
    """The mark centred on a size x size canvas, scaled so its farthest
    pixel is mark_radius from the centre. Supersampled 4x for clean edges."""
    big = size * 4
    scale = mark_radius * 4 / radius
    m = mark.resize((round(mark.width * scale), round(mark.height * scale)), Image.LANCZOS)
    if tint is not None:
        solid = Image.new("RGBA", m.size, tint + (255,))
        solid.putalpha(m.getchannel("A"))
        m = solid
    canvas = Image.new(
        "RGBA", (big, big), (0, 0, 0, 0) if background is None else background + (255,)
    )
    canvas.alpha_composite(m, ((big - m.width) // 2, (big - m.height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def rounded_tile(size, mark_radius):
    """The legacy launcher icon: the mark on a rounded dark square."""
    big = size * 4
    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    inset = round(big * 0.04)
    ImageDraw.Draw(tile).rounded_rectangle(
        (inset, inset, big - inset, big - inset), radius=round(big * 0.22), fill=BG + (255,)
    )
    m = mark_on(size, mark_radius).resize((big, big), Image.LANCZOS)
    tile.alpha_composite(m)
    return tile.resize((size, size), Image.LANCZOS)


densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
for name, f in densities.items():
    folder = res / f"mipmap-{name}"
    folder.mkdir(parents=True, exist_ok=True)
    launcher = round(48 * f)
    rounded_tile(launcher, launcher * 0.33).save(folder / "ic_launcher.png", optimize=True)
    # Adaptive layers are 108dp; launchers keep a 66dp circle, so the mark's
    # farthest point sits at 30dp from the centre.
    layer = round(108 * f)
    mark_on(layer, 30 * f).save(folder / "ic_launcher_foreground.png", optimize=True)
    mark_on(layer, 30 * f, tint=(255, 255, 255)).save(
        folder / "ic_launcher_monochrome.png", optimize=True
    )
    # Status bar icons are 24dp, white on transparent, drawn to 22dp.
    note = round(24 * f)
    folder_d = res / f"drawable-{name}"
    folder_d.mkdir(parents=True, exist_ok=True)
    mark_on(note, 11 * f, tint=(255, 255, 255)).save(
        folder_d / "ic_notification.png", optimize=True
    )

brand.mkdir(parents=True, exist_ok=True)
rounded_tile(512, 512 * 0.33).save(brand / "play-store-icon-512.png", optimize=True)
mark_on(1024, 470).save(brand / "omniflow-mark-1024.png", optimize=True)
assets = app / "assets/brand"
assets.mkdir(parents=True, exist_ok=True)
mark_on(512, 235).save(assets / "omniflow_mark.png", optimize=True)
print("done")
