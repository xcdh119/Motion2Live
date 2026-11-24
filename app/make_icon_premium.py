#!/usr/bin/env python3
"""First-version photo-card icon, recolored in silver / graphite."""
import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(OUT, "Resources")
ICONSET = os.path.join(RES, "AppIcon.iconset")


def gradient(size, c1, c2, diagonal=0.7):
    x = np.linspace(0, 1, size)
    X, Y = np.meshgrid(x, x)
    t = np.clip(X * diagonal + Y * (1 - diagonal), 0, 1)
    a = np.array(c1, dtype=float)
    b = np.array(c2, dtype=float)
    rgb = (a[None, None, :] * (1 - t[..., None]) + b[None, None, :] * t[..., None]).astype(np.uint8)
    return Image.fromarray(rgb, "RGB").convert("RGBA")


def rounded_mask(box, radius):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def render(bg1, bg2, card1, card2, sky1, sky2, hill1, hill2, sun, fg, border, path):
    body = gradient(S, bg1, bg2, 0.7)
    body.putalpha(rounded_mask([100, 100, 924, 924], 186))
    img = body

    # soft top-left light, like the first version
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([40, 10, 680, 600], fill=(255, 255, 255, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (S, S), 0),
                                  rounded_mask([100, 100, 924, 924], 186)))
    img = Image.alpha_composite(img, glow)

    # card shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([258, 316, 766, 704], radius=52, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    img = Image.alpha_composite(img, shadow)

    # card
    card_mask = rounded_mask([252, 300, 772, 700], 48)
    card = gradient(S, card1, card2, 0.5)
    card.putalpha(card_mask)
    img = Image.alpha_composite(img, card)

    # sky inside card
    sky = gradient(S, sky1, sky2, 0.2)
    sky_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sky_mask).rounded_rectangle([252, 300, 772, 700], radius=48, fill=255)
    content = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    content.paste(sky, (0, 0), sky_mask)

    cd = ImageDraw.Draw(content)
    # sun, with a soft halo
    cd.ellipse([600, 352, 692, 444], fill=sun + (70,))
    cd.ellipse([608, 360, 684, 436], fill=sun + (255,))

    # hills in graphite
    cd.polygon([(252, 642), (392, 486), (500, 590), (612, 468), (772, 610),
                (772, 700), (252, 700)], fill=hill1 + (255,))
    cd.polygon([(252, 690), (430, 566), (560, 662), (690, 566), (772, 640),
                (772, 700), (252, 700)], fill=hill2 + (255,))
    content.putalpha(card_mask)
    img = Image.alpha_composite(img, content)

    # card rim
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([252, 300, 772, 700], radius=48, outline=(255, 255, 255, 190), width=2)

    # play badge shadow
    badge_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(badge_shadow).ellipse([638, 582, 770, 714], fill=(0, 0, 0, 120))
    badge_shadow = badge_shadow.filter(ImageFilter.GaussianBlur(16))
    img = Image.alpha_composite(img, badge_shadow)

    # play badge
    d = ImageDraw.Draw(img)
    d.ellipse([644, 588, 764, 708], fill=(255, 255, 255, 255))
    d.ellipse([644, 588, 764, 708], outline=(28, 28, 30, 28), width=2)
    d.polygon([(698, 620), (698, 676), (746, 648)], fill=fg + (255,))

    # live ring
    d.arc([632, 576, 776, 720], start=-58, end=58,
          fill=(255, 255, 255, 190), width=6)

    # outer rim
    d.rounded_rectangle([100, 100, 924, 924], radius=186, outline=border + (255,), width=2)

    img.save(path)


def main():
    os.makedirs(RES, exist_ok=True)
    os.makedirs(ICONSET, exist_ok=True)

    # light: silver body, porcelain card
    render((246, 246, 249), (211, 211, 218),
           (255, 255, 255), (236, 236, 242),
           (252, 252, 254), (228, 228, 234),
           (186, 186, 192), (142, 142, 148),
           (214, 214, 219), (28, 28, 30), (199, 199, 206),
           os.path.join(RES, "AppIconLight.png"))

    # dark: graphite body, porcelain card
    render((78, 78, 82), (28, 28, 30),
           (250, 250, 252), (220, 220, 226),
           (247, 247, 250), (216, 216, 222),
           (176, 176, 181), (126, 126, 131),
           (245, 245, 247), (28, 28, 30), (92, 92, 96),
           os.path.join(RES, "AppIconDark.png"))

    light = Image.open(os.path.join(RES, "AppIconLight.png"))
    sizes = [
        (16, "16x16"), (32, "16x16@2x"),
        (32, "32x32"), (64, "32x32@2x"),
        (128, "128x128"), (256, "128x128@2x"),
        (256, "256x256"), (512, "256x256@2x"),
        (512, "512x512"), (1024, "512x512@2x"),
    ]
    for px, name in sizes:
        light.resize((px, px), Image.LANCZOS).save(
            os.path.join(ICONSET, "icon_%s.png" % name))

    subprocess.check_call(["iconutil", "-c", "icns", ICONSET,
                           "-o", os.path.join(RES, "AppIcon.icns")])
    print("wrote silver/graphite first-version icon")


if __name__ == "__main__":
    main()
