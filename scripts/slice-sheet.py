#!/usr/bin/env python3
"""Slice GrafxKid's "TD racing assets" sheet (CC0) into the game's sprite atlas.

    node scripts/fetch-assets.mjs      # downloads the sheet into assets/source/ and checks its SHA-256
    python3 scripts/slice-sheet.py     # writes public/assets/sprites.png and public/assets/sprites.json

The script measures the sheet before it cuts anything (background colour, palette, connected sprites, tile grid)
and prints what it finds. Every named frame in the tables below is then checked against those measurements, and
the run stops on any mismatch instead of guessing. Everything on the sheet that is not packed is listed with the
reason, and sprites that could not be identified are reported by position, not given a made-up name.

sprites.png is a packed RGBA atlas at 1:1 (no scaling) with the sheet background made transparent.
sprites.json maps each frame name to {x, y, w, h} in atlas pixels. Each frame has a 1 px border in the atlas.
Frames with opaque edges (tiles) have their edge pixels copied into that border, so tiling never samples a
neighbouring frame. Requires Python 3.10+ and Pillow.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SHEET = ROOT / "assets" / "source" / "grafxkid-td-racing-assets.png"
OUT_PNG = ROOT / "public" / "assets" / "sprites.png"
OUT_JSON = ROOT / "public" / "assets" / "sprites.json"

# The tables below were measured on exactly this file. Same value as scripts/fetch-assets.mjs.
SHEET_SHA256 = "cc07bc95ed84d60f74c5fda36d7477fde478f4e0b67dd78de38346cbc5852c66"
SHEET_SIZE = (832, 352)

TILE = 8  # tile grid of the road, ground and HUD blocks (printed by report_grid)
CAR_CELL = 16  # upright car bodies are centred in 16 x 16 cells (checked by check_cars)
SHADOW = (0x14, 0x14, 0x14)  # drop shadow under the cars
WHITE = (0xF0, 0xEE, 0xEC)
ATLAS_WIDTH = 256
BORDER = 1  # px of border around each frame in the atlas

Rect = tuple[int, int, int, int]  # x, y, w, h in sheet pixels
RGB = tuple[int, int, int]


@dataclass(frozen=True)
class Sprite:
    """A whole sprite. The rect must be exactly the bounding box of the sheet components inside it."""

    name: str
    rect: Rect


@dataclass(frozen=True)
class Cut:
    """A rectangle cut out of one opaque block of the sheet (road and ground tiles, HUD parts)."""

    name: str
    rect: Rect
    block: Rect
    on_grid: bool = True  # must sit on the TILE grid
    repeats_down: bool = False  # the block continues below with identical pixels, so the tile repeats seamlessly
    outline: RGB | None = None  # every border pixel of the cut must be this colour


@dataclass(frozen=True)
class Skip:
    """Something on the sheet that is deliberately not packed."""

    rect: Rect
    kind: str  # "excluded", "unidentified" or "duplicate"
    what: str
    same_as: str = ""  # duplicates: the packed frame whose sheet pixels are identical


GRASS_STRIP: Rect = (176, 144, 64, 16)
SNOW_STRIP: Rect = (432, 144, 48, 16)
GRASS_ROAD: Rect = (176, 224, 64, 64)  # straight two-lane road, repeats every 8 rows
SNOW_ROAD: Rect = (432, 224, 64, 64)
HUD_PANEL: Rect = (656, 32, 32, 176)  # HUD mock-up; only the fuel gauge is cut out
HUD_DIGITS: Rect = (584, 208, 40, 16)  # digits 0-4 on the top row, 5-9 below, 8 x 8 cells
HUD_PIPS: Rect = (568, 208, 8, 16)

# Cars face up (front at the top) unless named _down. Each car frame is the body plus a 1 px drop shadow (#141414)
# on its right and bottom: big cars are 8 x 12 bodies in 9 x 13 frames, small cars 6 x 10 bodies in 7 x 11 frames.
# _cw45 and _ccw45 are the same car drawn turned 45 degrees clockwise and counter-clockwise. The direction was
# checked by rotating each upright car both ways and comparing it with the drawn frames.
SPRITES = [
    Sprite("car_small_yellow", (565, 35, 7, 11)),
    Sprite("car_green", (580, 34, 9, 13)),
    Sprite("car_blue", (596, 34, 9, 13)),
    Sprite("car_red", (612, 34, 9, 13)),
    Sprite("car_small_yellow_cw45", (563, 52, 11, 11)),
    Sprite("car_green_cw45", (578, 50, 14, 14)),
    Sprite("car_blue_cw45", (594, 50, 14, 14)),
    Sprite("car_red_cw45", (610, 50, 14, 14)),
    Sprite("car_small_yellow_ccw45", (563, 68, 11, 11)),
    Sprite("car_green_ccw45", (577, 66, 14, 14)),
    Sprite("car_blue_ccw45", (593, 66, 14, 14)),
    Sprite("car_red_ccw45", (609, 66, 14, 14)),
    # White car with a red and blue light bar on the roof ("escape the police!" in the author's description).
    Sprite("car_police", (564, 98, 9, 13)),
    Sprite("car_police_ccw45", (577, 98, 14, 14)),
    Sprite("car_police_cw45", (594, 98, 14, 14)),
    Sprite("car_small_teal", (565, 147, 7, 11)),
    Sprite("car_navy", (580, 146, 9, 13)),
    Sprite("car_small_pink", (597, 147, 7, 11)),
    Sprite("car_salmon", (612, 146, 9, 13)),
    Sprite("car_small_teal_down", (565, 163, 7, 11)),
    Sprite("car_navy_down", (580, 162, 9, 13)),
    Sprite("car_small_pink_down", (597, 163, 7, 11)),
    Sprite("car_salmon_down", (612, 162, 9, 13)),
    # Props column. Oil: glossy black puddle with a white highlight and one droplet, identified by its look.
    Sprite("oil_spill", (533, 37, 6, 6)),
    Sprite("cone", (533, 53, 6, 7)),
    Sprite("barricade", (531, 70, 10, 6)),
    Sprite("finish_line", (528, 118, 16, 4)),  # checkered strip, repeats every 4 px across
    # Road furniture. Street lamp: a raised white head with a cyan light and a long shadow, placed at the roadside
    # in the sheet's own example track. Pit-lane roof: a raised roof (2 px shadow) that spans the pit lane in the
    # example track, above the painted fuel pump.
    Sprite("street_lamp", (172, 55, 12, 6)),
    Sprite("pit_lane_roof", (202, 50, 44, 14)),
    Sprite("snow_street_lamp", (428, 55, 12, 6)),
    Sprite("snow_pit_lane_roof", (458, 50, 44, 14)),
    # White road markings, painted on the asphalt in the example track.
    Sprite("decal_fuel_pump", (181, 83, 9, 10)),
    Sprite("snow_decal_fuel_pump", (437, 83, 9, 10)),
    Sprite("decal_turn_right", (183, 116, 6, 9)),
    Sprite("decal_60", (209, 81, 14, 14)),
    Sprite("decal_30", (209, 113, 14, 14)),
    # Yellow up-chevrons on asphalt, repeats every 4 rows.
    Sprite("road_chevrons", (260, 224, 8, 16)),
    Sprite("snow_road_chevrons", (516, 224, 8, 16)),
]


def road_tiles(prefix: str, block: Rect) -> list[Cut]:
    """The straight road, left to right: verge (grass and dirt edge), white edge line, asphalt, double yellow
    centre line (split over two tiles), asphalt, white edge line, verge. Every tile repeats down the road."""
    x, y = block[0], block[1]
    names = ["verge_left", "edge_left", "asphalt", "centre_line_left", "centre_line_right", None, "edge_right", "verge_right"]
    return [
        Cut(f"{prefix}{name}_tile", (x + i * TILE, y, TILE, TILE), block, repeats_down=True)
        for i, name in enumerate(names)
        if name  # the sixth tile is plain asphalt again
    ]


CUTS = [
    *road_tiles("road_", GRASS_ROAD),
    *road_tiles("snow_road_", SNOW_ROAD),
    # Ground strips: plain, tufts and flowers, and an outlined round bush on a grass background.
    Cut("grass_tile", (176, 144, 8, 8), GRASS_STRIP),
    Cut("grass_tufts_tile", (200, 144, 8, 8), GRASS_STRIP),
    Cut("grass_flowers_tile", (216, 144, 8, 8), GRASS_STRIP),
    Cut("grass_bush", (224, 144, 16, 16), GRASS_STRIP),
    Cut("snow_tile", (432, 144, 8, 8), SNOW_STRIP),
    Cut("snow_drifts_tile", (456, 144, 8, 8), SNOW_STRIP),
    Cut("snow_bush", (464, 144, 16, 16), SNOW_STRIP),
    # HUD. The fuel gauge has a 50 % green fill drawn into it; see the report for its inner area.
    Cut("hud_fuel_gauge", (676, 149, 8, 46), HUD_PANEL, on_grid=False, outline=WHITE),
    *[Cut(f"hud_digit_{d}", (584 + TILE * (d % 5), 208 + TILE * (d // 5), TILE, TILE), HUD_DIGITS) for d in range(10)],
    Cut("hud_pip_full", (568, 208, 8, 8), HUD_PIPS),
    Cut("hud_pip_empty", (568, 216, 8, 8), HUD_PIPS),
]

SKIPS = [
    Skip((32, 16, 65, 7), "excluded", "sheet label 'ROAD ASSETS'"),
    Skip((528, 16, 100, 8), "excluded", "sheet label 'CARS, PROPS AND UI'"),
    Skip((32, 32, 128, 304), "excluded", "example track layout (grass): built from the pieces above plus curves"),
    Skip((288, 32, 128, 304), "excluded", "example track layout (snow): built from the pieces above plus curves"),
    Skip((708, 44, 90, 150), "excluded", "player avatars (author's description), 5 x 3 frames: the game has no avatars"),
    Skip((439, 116, 6, 9), "duplicate", "snow copy of the turn arrow", "decal_turn_right"),
    Skip((465, 81, 14, 14), "duplicate", "snow copy of the 60 marking", "decal_60"),
    Skip((465, 113, 14, 14), "duplicate", "snow copy of the 30 marking", "decal_30"),
    Skip((532, 84, 8, 8), "unidentified", "black rounded square with a dark-grey top edge (pothole, tyre or drum?)"),
    Skip((261, 261, 7, 6), "unidentified", "scattered dark pixels; colours follow the asphalt (crack or debris?)"),
    Skip((517, 261, 7, 6), "unidentified", "snow-colour copy of the scattered dark pixels"),
    Skip((484, 149, 8, 8), "unidentified", "round cyan and white object next to the snow strip (ice patch or snowball?)"),
]


# ---------------------------------------------------------------------------------------------------------------
# Geometry helpers


def inside(inner: Rect, outer: Rect) -> bool:
    return (
        inner[0] >= outer[0]
        and inner[1] >= outer[1]
        and inner[0] + inner[2] <= outer[0] + outer[2]
        and inner[1] + inner[3] <= outer[1] + outer[3]
    )


def overlaps(a: Rect, b: Rect) -> bool:
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def union(rects: list[Rect]) -> Rect:
    x0 = min(r[0] for r in rects)
    y0 = min(r[1] for r in rects)
    x1 = max(r[0] + r[2] for r in rects)
    y1 = max(r[1] + r[3] for r in rects)
    return (x0, y0, x1 - x0, y1 - y0)


def box(r: Rect) -> tuple[int, int, int, int]:
    """Rect to a Pillow crop box."""
    return (r[0], r[1], r[0] + r[2], r[1] + r[3])


def fmt(r: Rect) -> str:
    return f"({r[0]},{r[1]}) {r[2]}x{r[3]}"


def hexcol(c: RGB) -> str:
    return "#%02x%02x%02x" % c


def pixels(im: Image.Image) -> tuple:
    """All pixel values in reading order. Pillow 12 renamed getdata to get_flattened_data."""
    getter = getattr(im, "get_flattened_data", None) or im.getdata
    return tuple(getter())


# ---------------------------------------------------------------------------------------------------------------
# Measurement


@dataclass(frozen=True)
class Component:
    rect: Rect
    pixels: int

    @property
    def opaque(self) -> bool:
        return self.pixels == self.rect[2] * self.rect[3]


def components(img: Image.Image, bg: RGB) -> list[Component]:
    """8-connected groups of non-background pixels, in reading order of their top-left corner."""
    w, h = img.size
    filled = [c != bg for c in pixels(img)]
    seen = [False] * (w * h)
    found: list[Component] = []
    for start in range(w * h):
        if not filled[start] or seen[start]:
            continue
        seen[start] = True
        stack = [start]
        x0, y0, x1, y1, n = w, h, -1, -1, 0
        while stack:
            i = stack.pop()
            x, y = i % w, i // w
            n += 1
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if filled[j] and not seen[j]:
                            seen[j] = True
                            stack.append(j)
        found.append(Component((x0, y0, x1 - x0 + 1, y1 - y0 + 1), n))
    return sorted(found, key=lambda c: (c.rect[1], c.rect[0]))


class Checker:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, ok: bool, message: str) -> bool:
        if not ok:
            self.errors.append(message)
        return ok


def report_grid(comps: list[Component]) -> None:
    blocks = [c for c in comps if c.opaque and c.rect[2] >= TILE and c.rect[3] >= TILE]
    print(f"\nGrid: opaque rectangular blocks of at least {TILE} x {TILE} px, and whether they sit on the {TILE} px grid")
    for c in blocks:
        on = all(v % TILE == 0 for v in c.rect)
        print(f"  {fmt(c.rect):<22} {'on grid' if on else 'off grid'}")
    on_grid = sum(all(v % TILE == 0 for v in c.rect) for c in blocks)
    print(f"  {on_grid} of {len(blocks)} blocks are on the {TILE} px grid. Tiles are cut on that grid.")


def check_cars(img: Image.Image, bg: RGB, check: Checker) -> None:
    """Upright and down-facing cars: the body is centred in a 16 px cell and the last column and row are shadow."""
    cars = [s for s in SPRITES if s.name.startswith("car_") and not s.name.endswith("45")]
    px = img.load()
    for s in cars:
        x, y, w, h = s.rect
        body_cx2, body_cy2 = 2 * x + (w - 1), 2 * y + (h - 1)  # twice the body centre, to stay in integers
        check.require(
            body_cx2 % (2 * CAR_CELL) == CAR_CELL and body_cy2 % (2 * CAR_CELL) == CAR_CELL,
            f"{s.name}: body is not centred in a {CAR_CELL} px cell",
        )
        edge = [px[x + w - 1, y + j] for j in range(h)] + [px[x + i, y + h - 1] for i in range(w)]
        check.require(
            all(c in (SHADOW, bg) for c in edge) and SHADOW in edge,
            f"{s.name}: right column and bottom row are not only shadow",
        )
    print(
        f"\nCars: {len(cars)} upright or down-facing car frames checked. Bodies are centred in {CAR_CELL} x {CAR_CELL} "
        f"cells, and each frame's right column and bottom row hold only the {hexcol(SHADOW)} drop shadow."
    )


# ---------------------------------------------------------------------------------------------------------------
# Main


def fail(lines: list[str]) -> None:
    print("\nFAILED. Nothing was written.", file=sys.stderr)
    for line in lines:
        print(f"  - {line}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if not SHEET.exists():
        fail([f"{SHEET.relative_to(ROOT)} is missing. Run: node scripts/fetch-assets.mjs"])
    digest = hashlib.sha256(SHEET.read_bytes()).hexdigest()
    if digest != SHEET_SHA256:
        fail([f"SHA-256 of {SHEET.name} is {digest}, expected {SHEET_SHA256}. The tables were measured on another file."])

    src = Image.open(SHEET)
    print(f"Sheet: {SHEET.relative_to(ROOT)}")
    print(f"  sha256 {digest} (matches the pinned value)")
    print(f"  {src.size[0]} x {src.size[1]} px, mode {src.mode}")
    if src.size != SHEET_SIZE:
        fail([f"sheet is {src.size}, expected {SHEET_SIZE}"])
    img = src.convert("RGB")
    w, h = img.size
    counts = Counter(pixels(img))
    bg, bg_count = counts.most_common(1)[0]
    px = img.load()
    corners = {px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]}
    print(f"  {len(counts)} colours. Background {hexcol(bg)}: most common colour ({bg_count} px) and all four corners.")
    if corners != {bg}:
        fail([f"corner colours {sorted(map(hexcol, corners))} do not all match the most common colour {hexcol(bg)}"])

    comps = components(img, bg)
    print(f"\nComponents: {len(comps)} groups of 8-connected non-background pixels")
    check = Checker()

    # Frame names must be unique and safe as JSON keys and Phaser frame names.
    names = [s.name for s in SPRITES] + [c.name for c in CUTS]
    dupes = sorted(n for n, k in Counter(names).items() if k > 1)
    check.require(not dupes, f"duplicate frame names: {dupes}")
    for n in names:
        check.require(re.fullmatch(r"[a-z0-9_]+", n) is not None, f"frame name {n!r} is not lower_snake_case")

    # Whole sprites: the rect is exactly the bounding box of the components it contains, and no component crosses it.
    for s in SPRITES:
        inner = [c.rect for c in comps if inside(c.rect, s.rect)]
        crossing = [c.rect for c in comps if overlaps(c.rect, s.rect) and not inside(c.rect, s.rect)]
        check.require(not crossing, f"{s.name}: components {[fmt(r) for r in crossing]} cross its rect {fmt(s.rect)}")
        if check.require(bool(inner), f"{s.name}: no sprite inside {fmt(s.rect)}"):
            check.require(union(inner) == s.rect, f"{s.name}: rect {fmt(s.rect)} but measured bounds {fmt(union(inner))}")
    for i, a in enumerate(SPRITES):
        for b in SPRITES[i + 1 :]:
            check.require(not overlaps(a.rect, b.rect), f"{a.name} and {b.name} overlap on the sheet")

    # Cuts: from a measured, fully opaque block; on the grid; seamless downwards where claimed; outline where claimed.
    blocks = {c.rect: c for c in comps}
    for cut in CUTS:
        block = blocks.get(cut.block)
        if not check.require(block is not None and block.opaque, f"{cut.name}: {fmt(cut.block)} is not a measured opaque block"):
            continue
        check.require(inside(cut.rect, cut.block), f"{cut.name}: {fmt(cut.rect)} is outside its block {fmt(cut.block)}")
        if cut.on_grid:
            check.require(all(v % TILE == 0 for v in cut.rect), f"{cut.name}: {fmt(cut.rect)} is off the {TILE} px grid")
        if cut.repeats_down:
            below = (cut.rect[0], cut.rect[1] + cut.rect[3], cut.rect[2], cut.rect[3])
            check.require(
                inside(below, cut.block) and img.crop(box(below)).tobytes() == img.crop(box(cut.rect)).tobytes(),
                f"{cut.name}: the block below it is not identical, so it does not repeat seamlessly",
            )
        if cut.outline is not None:
            x, y, cw, ch = cut.rect
            ring = [px[x + i, y] for i in range(cw)] + [px[x + i, y + ch - 1] for i in range(cw)]
            ring += [px[x, y + j] for j in range(ch)] + [px[x + cw - 1, y + j] for j in range(ch)]
            check.require(set(ring) == {cut.outline}, f"{cut.name}: border is not all {hexcol(cut.outline)}")

    # Skips: duplicates must be pixel-identical; the others must hold whole components.
    sheet_rect = {s.name: s.rect for s in SPRITES} | {c.name: c.rect for c in CUTS}
    for skip in SKIPS:
        crossing = [c.rect for c in comps if overlaps(c.rect, skip.rect) and not inside(c.rect, skip.rect)]
        check.require(not crossing, f"skip {fmt(skip.rect)}: components {[fmt(r) for r in crossing]} cross it")
        check.require(any(inside(c.rect, skip.rect) for c in comps), f"skip {fmt(skip.rect)}: nothing inside")
        if skip.kind == "duplicate":
            original = sheet_rect.get(skip.same_as)
            check.require(
                original is not None
                and original[2:] == skip.rect[2:]
                and img.crop(box(original)).tobytes() == img.crop(box(skip.rect)).tobytes(),
                f"skip {fmt(skip.rect)}: not pixel-identical to {skip.same_as}",
            )

    # Every component must be accounted for: packed, cut from, or listed as not packed. Nothing passes silently.
    for c in comps:
        packed = [s.name for s in SPRITES if inside(c.rect, s.rect)]
        cut_from = [cut.name for cut in CUTS if cut.block == c.rect]
        skipped = [skip for skip in SKIPS if inside(c.rect, skip.rect)]
        if packed:
            where = f"frame {packed[0]}"
        elif cut_from:
            where = f"cut into: {', '.join(cut_from)}"
        elif skipped:
            where = f"{skipped[0].kind}: {skipped[0].what}"
        else:
            where = "UNACCOUNTED"
            check.require(False, f"component {fmt(c.rect)} is not covered by any frame, cut or skip")
        print(f"  {fmt(c.rect):<22} {c.pixels:>6} px  {where}")

    report_grid(comps)
    check_cars(img, bg, check)
    if check.errors:
        fail(check.errors)

    # Build the frames: whole sprites get a transparent background, cuts are opaque.
    frames: dict[str, Image.Image] = {}
    for s in SPRITES:
        im = img.crop(box(s.rect)).convert("RGBA")
        im.putdata([(0, 0, 0, 0) if p[:3] == bg else p for p in pixels(im)])
        frames[s.name] = im
    for cut in CUTS:
        frames[cut.name] = img.crop(box(cut.rect)).convert("RGBA")

    placed, atlas_h = pack({n: f.size for n, f in frames.items()})
    atlas = Image.new("RGBA", (ATLAS_WIDTH, atlas_h), (0, 0, 0, 0))
    for name, (x, y, _, _) in placed.items():
        paste_with_border(atlas, frames[name], x, y)

    OUT_PNG.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT_PNG, optimize=True)
    lines = [f'  "{n}": {{ "x": {x}, "y": {y}, "w": {fw}, "h": {fh} }}' for n, (x, y, fw, fh) in sorted(placed.items())]
    text = "{\n" + ",\n".join(lines) + "\n}\n"
    json.loads(text)  # the hand-written layout must still be valid JSON
    OUT_JSON.write_text(text, encoding="utf-8")

    print(f"\nFrames: {len(placed)} (sheet rect -> atlas rect)")
    for n in sorted(placed):
        print(f"  {n:<33} {fmt(sheet_rect[n]):<20} -> {fmt(placed[n])}")
    print("\nNot packed:")
    for skip in SKIPS:
        if skip.kind != "unidentified":
            print(f"  {fmt(skip.rect):<22} {skip.kind}: {skip.what}")
    print(f"  {fmt(HUD_PANEL):<22} HUD mock-up: labels and sample values not packed; hud_fuel_gauge is cut from it")
    print("\nUNIDENTIFIED (reported, not packed):")
    for skip in SKIPS:
        if skip.kind == "unidentified":
            print(f"  {fmt(skip.rect):<22} {skip.what}")
    print(f"\nWrote {OUT_PNG.relative_to(ROOT)} ({ATLAS_WIDTH} x {atlas_h} px) and {OUT_JSON.relative_to(ROOT)}.")


def pack(sizes: dict[str, tuple[int, int]]) -> tuple[dict[str, Rect], int]:
    """Shelf packing, tallest first, with BORDER px around every frame. Same table in, same layout out."""
    order = sorted(sizes, key=lambda n: (-sizes[n][1], -sizes[n][0], n))
    placed: dict[str, Rect] = {}
    x = y = shelf = 0
    for name in order:
        w, h = sizes[name]
        cell_w, cell_h = w + 2 * BORDER, h + 2 * BORDER
        if cell_w > ATLAS_WIDTH:
            fail([f"{name} is wider than the atlas"])
        if x + cell_w > ATLAS_WIDTH:
            x, y, shelf = 0, y + shelf, 0
        placed[name] = (x + BORDER, y + BORDER, w, h)
        x += cell_w
        shelf = max(shelf, cell_h)
    return placed, y + shelf


def paste_with_border(atlas: Image.Image, im: Image.Image, x: int, y: int) -> None:
    """Paste a frame. If its edges are fully opaque (a tile), copy the edge pixels into the border around it."""
    atlas.paste(im, (x, y))
    w, h = im.size
    alpha = im.getchannel("A").load()
    edges = [alpha[i, 0] for i in range(w)] + [alpha[i, h - 1] for i in range(w)]
    edges += [alpha[0, j] for j in range(h)] + [alpha[w - 1, j] for j in range(h)]
    if min(edges) < 255:
        return
    atlas.paste(im.crop((0, 0, w, 1)), (x, y - 1))
    atlas.paste(im.crop((0, h - 1, w, h)), (x, y + h))
    atlas.paste(im.crop((0, 0, 1, h)), (x - 1, y))
    atlas.paste(im.crop((w - 1, 0, w, h)), (x + w, y))
    for (cx, cy), (ax, ay) in {(0, 0): (-1, -1), (w - 1, 0): (w, -1), (0, h - 1): (-1, h), (w - 1, h - 1): (w, h)}.items():
        atlas.putpixel((x + ax, y + ay), im.getpixel((cx, cy)))


if __name__ == "__main__":
    main()
