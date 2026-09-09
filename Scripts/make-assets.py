#!/usr/bin/env python3
"""Generate the app icon, the in-app mark, and the disk image background from Art/tunaboat.png.

    python3 Scripts/make-assets.py

Run this only when the source artwork changes; the outputs are committed, so an ordinary build
needs neither this script nor Pillow.

The source is black line art on a flat warm-grey field (#EEEEEC), not on transparency. Rather
than threshold it — which would leave a hard, jagged edge on artwork that is almost entirely
hairlines — every pixel's darkness becomes its alpha and the colour becomes flat black. That
keeps the anti-aliasing intact, and gives a mask that can be tinted, so one asset serves both
light and dark appearances.

Outputs:
    Resources/Tunaboat.icns                     app icon, wired in by bundle-app.sh
    Resources/dmg-background.png (+@2x)          disk image backdrop, used by make-dmg.sh
    Sources/TunaboatApp/Resources/TunaboatMark.png   template mark for the editor empty state
"""
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("needs Pillow:  python3 -m pip install --user Pillow")

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Art" / "tunaboat.png"

# Measured from the source's row-ink profile. The wordmark is a separate band with a clear gap
# above it, so the mark can be lifted out without the lettering.
MARK_BAND = (250, 755)
WORDMARK_BAND = (756, 840)
# The lowest fish sit at the same height as the lettering, out at the edges; without a column
# limit they get cropped in alongside it and appear as debris beside the word.
WORDMARK_COLUMNS = (250, 780)

# The Finder window make-dmg.sh opens: {200,160,840,560} — 640x400 points, with the two 96pt
# icons centred at y=200. Vertical placement is in window points rather than fractions, because
# that is the unit the composition is judged in and the unit corrections arrive in.
WINDOW = (640, 400)
MARK_CENTRE_Y = 53       # was 68; the mark sat ~15pt low against the icon row
# Raising the mark and keeping its old width are incompatible: at 0.42 it stands 155pt tall, so
# centring it at 53 pushes the bow off the top edge (it was already losing 9pt at y=68). Narrowed
# until the whole boat clears the window, which is what "higher" has to mean here.
MARK_WIDTH = 0.28
WORDMARK_CENTRE_Y = 308  # was 348; the wordmark sat ~40pt low, crowding the window's bottom edge
BACKGROUND = 0xEE  # the flat field the art sits on
FIELD_FLOOR = 26   # below this, it is paper texture rather than ink


def alpha_from_darkness(image: Image.Image) -> Image.Image:
    """Flat black, with each pixel's darkness as its alpha.

    The field is not perfectly flat — it runs about #EE at the edges and #F3 in the middle,
    which a straight linear map turns into a faintly opaque rectangle exactly where the art
    sits. That showed up in the icon as a ghost box behind the boat. Anything fainter than
    FLOOR is field, not ink, and is dropped outright.
    """
    grey = image.convert("L")
    # 0 (black ink) -> 255 alpha, FIELD (paper) -> 0 alpha, linear between, then de-noised.
    def to_alpha(v: int) -> int:
        a = round((BACKGROUND - v) * 255 / BACKGROUND)
        a = max(0, min(255, a))
        return 0 if a < FIELD_FLOOR else a

    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.putalpha(grey.point(to_alpha))
    return out


def ink_bbox(rgba: Image.Image, band, columns=None):
    """Tight bounds of the visible ink within a horizontal band."""
    region = rgba.crop((columns[0] if columns else 0, band[0],
                        columns[1] if columns else rgba.width, band[1]))
    box = region.getbbox()
    if box is None:
        sys.exit(f"no ink found in band {band}")
    dx = columns[0] if columns else 0
    return (box[0] + dx, box[1] + band[0], box[2] + dx, box[3] + band[0])


def prepare(mark: Image.Image, box: int, thicken: float) -> Image.Image:
    """Scale a mark to fit inside a `box`-sided square without losing its hairlines.

    Fit both dimensions, not just the width: the boat crop is much taller than it is wide, and
    scaling it by width alone drove it straight off the plate at every small size.

    Downsampling line art this fine also simply deletes it — a one-pixel stroke reduced
    eightfold averages away to nothing, which is why the first attempt at this icon came out as
    a ghost. Dilating the alpha *before* the resize, by roughly the reduction factor, keeps the
    strokes present at the smaller size; the gamma afterwards restores the density that
    averaging costs.
    """
    scale = min(box / mark.width, box / mark.height)
    target_w = max(1, round(mark.width * scale))
    target_h = max(1, round(mark.height * scale))

    reduction = mark.width / target_w
    alpha = mark.getchannel("A")
    grow = max(0, round(reduction * thicken))
    if grow:
        # MaxFilter needs an odd window.
        alpha = alpha.filter(ImageFilter.MaxFilter(grow * 2 + 1))
    grown = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    grown.putalpha(alpha)

    small = grown.resize((target_w, target_h), Image.LANCZOS)
    # Averaging a thin stroke against transparency halves its opacity; pull it back.
    a = small.getchannel("A").point(lambda v: min(255, round(255 * (v / 255) ** 0.62)))
    small.putalpha(a)
    return small


def tinted(mark: Image.Image, colour) -> Image.Image:
    out = Image.new("RGBA", mark.size, colour + (0,))
    out.putalpha(mark.getchannel("A"))
    return out


def icon_image(size: int, mark: Image.Image) -> Image.Image:
    """One icon size: a deep-water plate with the mark in white on top.

    The plate is dark because black-on-near-white line art vanished at every size below 256 —
    white strokes on deep water survive the reduction and look like a deliberate choice.

    The same mark is used at every size. Cropping to the boat alone for the small sizes was
    tried first, on the theory that ten fish on hairline trolling lines become noise; rendered
    and compared side by side, the boat alone collapsed into a featureless vertical bar at 16pt
    while the full mark kept a silhouette you can actually tell from another icon. The small
    sizes instead get more dilation and a larger share of the plate.
    """
    scale = size / 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Apple's macOS grid: an 824pt plate inside a 1024pt canvas, radius 185.
    inset, radius = round(100 * scale), 185 * scale
    plate_size = size - 2 * inset

    # A vertical gradient, deep at the bottom like water.
    plate = Image.new("RGBA", (plate_size, plate_size))
    top, bottom = (30, 74, 110), (12, 32, 54)
    pd = plate.load()
    for y in range(plate_size):
        t = y / max(1, plate_size - 1)
        row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(plate_size):
            pd[x, y] = row

    mask = Image.new("L", (plate_size, plate_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, plate_size - 1, plate_size - 1), radius=radius, fill=255
    )
    plate.putalpha(mask)

    coverage = 0.86 if size < 128 else 0.78
    thicken = 0.35 if size < 128 else 0.5
    art = prepare(mark, max(1, round(plate_size * coverage)), thicken)
    art = tinted(art, (247, 250, 252))
    plate.paste(art, ((plate_size - art.width) // 2, (plate_size - art.height) // 2), art)

    canvas.paste(plate, (inset, inset), plate)
    return canvas


def main() -> None:
    if not SOURCE.exists():
        sys.exit(f"missing source artwork: {SOURCE}")

    source = Image.open(SOURCE)
    rgba = alpha_from_darkness(source)

    mark = rgba.crop(ink_bbox(rgba, MARK_BAND))
    full_art = rgba.crop(ink_bbox(rgba, (MARK_BAND[0], WORDMARK_BAND[1])))
    print(f"  mark {mark.size}   full {full_art.size}")

    resources = ROOT / "Resources"
    resources.mkdir(exist_ok=True)

    # --- app icon -------------------------------------------------------------------------
    iconset = resources / "Tunaboat.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    iconset.mkdir(exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for factor, suffix in ((1, ""), (2, "@2x")):
            icon_image(base * factor, mark).save(
                iconset / f"icon_{base}x{base}{suffix}.png"
            )
    icns = resources / "Tunaboat.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    print(f"  wrote {icns.relative_to(ROOT)} ({icns.stat().st_size} bytes)")

    # --- in-app mark ----------------------------------------------------------------------
    # Used as a *template* image, so SwiftUI tints it and it works in both appearances. Only
    # the alpha matters; the black is discarded at render time.
    app_resources = ROOT / "Sources" / "TunaboatApp" / "Resources"
    app_resources.mkdir(parents=True, exist_ok=True)
    mark_png = app_resources / "TunaboatMark.png"
    scale = 512 / mark.width
    mark.resize((512, max(1, round(mark.height * scale))), Image.LANCZOS).save(mark_png)
    print(f"  wrote {mark_png.relative_to(ROOT)}")

    # --- disk image background ------------------------------------------------------------
    # Matches the Finder window make-dmg.sh opens: {200,160,840,560} — 640x400 points, with the
    # two 96pt icons centred at y=200. Composing the whole artwork as one block put the fish
    # directly behind those icons; the mark and the wordmark are therefore placed separately,
    # above and below, leaving the middle band clear for what the user actually has to drag.
    wordmark = rgba.crop(ink_bbox(rgba, WORDMARK_BAND, WORDMARK_COLUMNS))
    for factor, suffix in ((1, ""), (2, "@2x")):
        w, h = WINDOW[0] * factor, WINDOW[1] * factor
        bg = Image.new("RGBA", (w, h), (250, 250, 248, 255))

        def place(art: Image.Image, width_fraction: float, centre_y: int, opacity: float):
            """Centre `art` horizontally, with its middle at `centre_y` *window points*."""
            target = round(w * width_fraction)
            scaled = art.resize(
                (target, max(1, round(art.height * target / art.width))), Image.LANCZOS
            )
            faded = scaled.copy()
            faded.putalpha(scaled.getchannel("A").point(lambda v: round(v * opacity)))
            bg.paste(faded,
                     ((w - faded.width) // 2, centre_y * factor - faded.height // 2),
                     faded)

        place(mark, MARK_WIDTH, MARK_CENTRE_Y, 0.30)      # above the icon row
        place(wordmark, 0.30, WORDMARK_CENTRE_Y, 0.45)  # below it
        out = resources / f"dmg-background{suffix}.png"
        bg.convert("RGB").save(out)
        print(f"  wrote {out.relative_to(ROOT)} ({w}x{h})")


if __name__ == "__main__":
    main()
