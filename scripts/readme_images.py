#!/usr/bin/env python3
"""Draws the README's indicator and settings cards. Needs Pillow.

readme_images.py indicators <frames dir> <output dir>
    Lays the recorded indicator frames out on the card, one PNG per frame,
    ANIMATION_WIDTH wide. <frames dir> holds Waves/, Dots/, Particles/ and
    Aurora/ from `--record-indicator`; the tiles take the background they
    were recorded over, from recording.json. The Bars pill is drawn by
    SwiftUI, which the recorder can't record, so its row is a still picture
    (BARS_SOURCE). See record_indicators.sh.

readme_images.py settings <back window> <front window> <output>
    Lays two settings window screenshots over each other on the card. See
    capture_settings.sh.
"""

import json
import sys
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH = 2560
# The animation is scaled down to the README column at 2x, which keeps the
# WebP to a few megabytes.
ANIMATION_WIDTH = 1600
MARGIN = 96
CORNER = 55

EYEBROW = (127, 180, 255)
TEXT = (238, 242, 250)
MUTED = (142, 152, 171)
DIM = (84, 94, 114)
TILE_BORDER = (33, 40, 57)
CURRENT_STATE = (31, 50, 84)

FONT = "/System/Library/Fonts/SFNS.ttf"
BARS_SOURCE = Path(__file__).resolve().parent.parent / "Docs/images/source/indicator-bars.png"

STYLES = [
    ("Waves", "glowing waves out of an orb, in five colours"),
    ("Dots", "a spectrum of glowing dots, in five colours"),
    ("Particles", "a mountain for each band of your voice"),
    ("Aurora", "smoke in a glass bubble, in four palettes"),
]
STATES = ["Listening", "Processing", "Pasted"]
BARS_STATES = ["Recording", "Transcribing", "Model loading", "Pasted"]


@lru_cache
def font(size, weight="Regular"):
    loaded = ImageFont.truetype(FONT, size)
    loaded.set_variation_by_name(weight)
    return loaded


def spaced(draw, xy, text, fnt, fill, spacing):
    x, y = xy
    for char in text:
        draw.text((x, y), char, font=fnt, fill=fill)
        x += draw.textlength(char, font=fnt) + spacing


def background(height):
    """The card: dark navy, lighter blue at the top right, teal at the bottom left."""
    small_w, small_h = 64, 48
    small = Image.new("RGB", (small_w, small_h))
    for y in range(small_h):
        for x in range(small_w):
            u, v = x / (small_w - 1), y / (small_h - 1)
            base = [10 + (8 - 10) * v, 15 + (12 - 15) * v, 27 + (22 - 27) * v]
            glow = max(0.0, 1 - ((1 - u) ** 2 * 1.2 + v ** 2 * 3.2)) ** 1.5
            teal = max(0.0, 1 - (u ** 2 * 6 + (1 - v) ** 2 * 5)) ** 1.5
            color = [
                base[0] + 12 * glow + 4 * teal,
                base[1] + 24 * glow + 22 * teal,
                base[2] + 44 * glow + 22 * teal,
            ]
            small.putpixel((x, y), tuple(round(c) for c in color))
    card = small.resize((WIDTH, height), Image.BICUBIC).convert("RGBA")
    ImageDraw.Draw(card).rounded_rectangle(
        (0, 0, WIDTH - 1, height - 1), CORNER, outline=(29, 35, 48, 255), width=2
    )
    return round_corners(card)


def round_corners(card):
    """Cuts the card, and anything drawn over its edge, to its rounded shape."""
    mask = Image.new("L", card.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, card.width - 1, card.height - 1), CORNER, fill=255)
    card.putalpha(mask)
    return card


def heading(card, eyebrow, title, subtitle):
    draw = ImageDraw.Draw(card)
    spaced(draw, (MARGIN, 84), eyebrow, font(27, "Semibold"), EYEBROW, 5)
    draw.text((MARGIN, 124), title, font=font(58, "Bold"), fill=TEXT)
    draw.text((MARGIN, 210), subtitle, font=font(31), fill=MUTED)


def tile_boxes():
    gap = 40
    width = (WIDTH - 2 * MARGIN - gap) // 2
    height = 480
    boxes = []
    for row in range(2):
        top = 380 + row * (height + 110)
        for column in range(2):
            left = MARGIN + column * (width + gap)
            boxes.append((left, top, left + width, top + height))
    return boxes


def indicators_layer(tile_color):
    card = background(1960)
    heading(
        card, "FLOATING INDICATOR", "Five indicator styles",
        "It appears above the Dock while you hold Fn and changes at each step until the text is pasted.",
    )
    draw = ImageDraw.Draw(card)

    label, caption = font(33, "Semibold"), font(31)
    for (name, description), box in zip(STYLES, tile_boxes()):
        draw.rounded_rectangle(box, 28, fill=tile_color, outline=TILE_BORDER, width=2)
        x, y = box[0] + 4, box[3] + 26
        draw.text((x, y), name, font=label, fill=TEXT)
        x += draw.textlength(name, font=label)
        draw.text((x, y + 2), f" · {description}", font=caption, fill=MUTED)

    top = 1560
    spaced(draw, (MARGIN, top), "BARS", font(27, "Semibold"), EYEBROW, 5)
    draw.text((MARGIN + 110, top - 4), "a small black pill, shown here at 2×", font=font(31), fill=MUTED)
    bars = Image.open(BARS_SOURCE).convert("RGBA")
    card.alpha_composite(bars, (MARGIN, top + 60))
    tile_width, tile_step = 574, 598
    for index, state in enumerate(BARS_STATES):
        center = MARGIN + index * tile_step + tile_width / 2
        width = draw.textlength(state, font=caption)
        draw.text((center - width / 2, top + 60 + bars.height + 22), state, font=caption, fill=MUTED)
    return card


def draw_states(card, time, timeline):
    """The dictation's steps, the current one lit."""
    current = 0 if time < timeline["processingStart"] else 1 if time < timeline["pasteTime"] else 2
    draw = ImageDraw.Draw(card)
    fnt = font(29, "Semibold")
    x, y = MARGIN, 290
    for index, state in enumerate(STATES):
        width = draw.textlength(state, font=fnt)
        if index == current:
            draw.rounded_rectangle((x, y, x + width + 44, y + 50), 25, fill=CURRENT_STATE)
        draw.text((x + 22, y + 9), state, font=fnt, fill=TEXT if index == current else DIM)
        x += width + 44
        if index < len(STATES) - 1:
            draw.text((x + 14, y + 7), "→", font=fnt, fill=DIM)
            x += 60


def indicators(frames_dir, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    frames = {name: sorted((frames_dir / name).glob("frame-*.png")) for name, _ in STYLES}
    count = max(len(paths) for paths in frames.values())
    # Every style is recorded with the same timeline.
    timeline = json.loads((frames_dir / STYLES[0][0] / "recording.json").read_text())
    base = indicators_layer(tuple(timeline["background"]))

    for index in range(count):
        card = base.copy()
        draw_states(card, index / timeline["framesPerSecond"], timeline)
        for (name, _), box in zip(STYLES, tile_boxes()):
            paths = frames[name]
            # A style that ends sooner holds its last, empty frame.
            frame = Image.open(paths[min(index, len(paths) - 1)]).convert("RGBA")
            left = box[0] + (box[2] - box[0] - frame.width) // 2
            top = box[1] + (box[3] - box[1] - frame.height) // 2
            card.alpha_composite(frame, (left, top))
        height = round(card.height * ANIMATION_WIDTH / card.width)
        card = card.resize((ANIMATION_WIDTH, height), Image.LANCZOS)
        # Read straight back by img2webp, so quick to write beats small.
        card.save(output_dir / f"card-{index:04d}.png", compress_level=1)


def window(path, width):
    """A window screenshot at `width`, on a soft shadow."""
    image = Image.open(path).convert("RGBA")
    image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
    pad = 80
    shadow = Image.new("RGBA", (image.width + 2 * pad, image.height + 2 * pad), (0, 0, 0, 0))
    alpha = Image.new("L", shadow.size, 0)
    alpha.paste(image.getchannel("A").point(lambda a: a * 0.7), (pad, pad + 24))
    shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(36)))
    shadow.alpha_composite(image, (pad, pad))
    return shadow, pad


def settings(back_path, front_path, output):
    card = background(1400)
    heading(
        card, "SETTINGS", "One window for every setting",
        "General · Permissions · Models · Transcription · Text Rules · Snippets · Indicator · Sounds",
    )
    for path, (left, top) in [(back_path, (110, 300)), (front_path, (1130, 400))]:
        image, pad = window(path, 1320)
        card.alpha_composite(image, (left - pad, top - pad))
    # Windows running off the bottom are cut at the card's rounded edge.
    round_corners(card).save(output)


if __name__ == "__main__":
    command, *paths = sys.argv[1:]
    if command == "indicators":
        indicators(*map(Path, paths))
    elif command == "settings":
        settings(*map(Path, paths))
    else:
        sys.exit(__doc__)
