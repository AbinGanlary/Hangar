"""Hangar app icon: an arched hangar with an app tile parked inside.

Writes the three 1024 px variants the asset catalog expects (light, dark, tinted)
plus a 256 px preview. Run: python -I branding/make_icon.py <out_dir>
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersampling for smooth edges


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(top, bottom):
    img = Image.new("RGB", (S * SS, S * SS))
    d = ImageDraw.Draw(img)
    for y in range(S * SS):
        d.line([(0, y), (S * SS, y)], fill=lerp(top, bottom, y / (S * SS)))
    return img


def hangar_layers(scale=SS):
    """Return (shell, opening, tile, floor) masks at supersampled size."""
    W = S * scale

    def box(x0, y0, x1, y1):
        return [x0 * scale, y0 * scale, x1 * scale, y1 * scale]

    shell = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(shell)
    # arched roof: half ellipse sitting on a short wall
    d.ellipse(box(152, 250, 872, 970), fill=255)
    d.rectangle(box(152, 610, 872, 800), fill=255)
    # cut the ground line flat
    d.rectangle(box(0, 800, 1024, 1024), fill=0)

    opening = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(opening)
    d.rounded_rectangle(box(300, 470, 724, 800), radius=46 * scale, fill=255)
    d.rectangle(box(300, 700, 724, 800), fill=255)

    tile = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(tile)
    d.rounded_rectangle(box(402, 556, 622, 776), radius=56 * scale, fill=255)

    ribs = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(ribs)
    for x in (226, 798):
        d.rounded_rectangle(box(x - 9, 520, x + 9, 790), radius=9 * scale, fill=255)

    floor = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(floor)
    d.rounded_rectangle(box(112, 806, 912, 838), radius=16 * scale, fill=255)
    return shell, opening, tile, ribs, floor


def compose(bg_top, bg_bottom, shell_rgb, inside_rgb, tile_top, tile_bottom, rib_rgb, floor_rgb, glow_rgb=None):
    base = gradient(bg_top, bg_bottom).convert("RGBA")
    shell, opening, tile, ribs, floor = hangar_layers()
    W = S * SS

    if glow_rgb:
        glow = Image.new("RGBA", (W, W), glow_rgb + (0,))
        gm = tile.filter(ImageFilter.GaussianBlur(70 * SS)).point(lambda v: min(255, int(v * 1.4)))
        glow.putalpha(gm)
        base.alpha_composite(glow)

    base.paste(Image.new("RGBA", (W, W), shell_rgb + (255,)), (0, 0), shell)
    base.paste(Image.new("RGBA", (W, W), rib_rgb + (255,)), (0, 0), Image.composite(ribs, Image.new("L", (W, W), 0), shell))
    base.paste(Image.new("RGBA", (W, W), inside_rgb + (255,)), (0, 0), opening)

    tile_fill = gradient(tile_top, tile_bottom).convert("RGBA")
    base.paste(tile_fill, (0, 0), tile)
    base.paste(Image.new("RGBA", (W, W), floor_rgb + (255,)), (0, 0), floor)
    return base.resize((S, S), Image.LANCZOS).convert("RGB")


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)

    light = compose(
        bg_top=(38, 64, 126), bg_bottom=(17, 26, 58),
        shell_rgb=(236, 241, 250), inside_rgb=(20, 30, 62),
        tile_top=(255, 186, 74), tile_bottom=(255, 118, 66),
        rib_rgb=(198, 208, 228), floor_rgb=(236, 241, 250),
        glow_rgb=(255, 150, 70),
    )
    dark = compose(
        bg_top=(18, 22, 34), bg_bottom=(6, 8, 14),
        shell_rgb=(196, 206, 228), inside_rgb=(8, 10, 18),
        tile_top=(255, 186, 74), tile_bottom=(255, 118, 66),
        rib_rgb=(150, 162, 190), floor_rgb=(196, 206, 228),
        glow_rgb=(255, 150, 70),
    )
    # tinted: iOS recolours a grayscale image on a dark background
    tinted = compose(
        bg_top=(0, 0, 0), bg_bottom=(0, 0, 0),
        shell_rgb=(150, 150, 150), inside_rgb=(10, 10, 10),
        tile_top=(255, 255, 255), tile_bottom=(235, 235, 235),
        rib_rgb=(110, 110, 110), floor_rgb=(150, 150, 150),
    )
    light.save(out / "AppIcon1024.png")
    dark.save(out / "AppIconDark1024.png")
    tinted.save(out / "AppIconDark1024 1.png")

    preview = Image.new("RGB", (3 * 276, 276), (128, 128, 128))
    for i, im in enumerate((light, dark, tinted)):
        small = im.resize((256, 256), Image.LANCZOS)
        mask = Image.new("L", (256, 256), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, 255, 255], radius=58, fill=255)
        preview.paste(small, (10 + i * 276, 10), mask)
    preview.save(out / "preview.png")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "branding/out")
