extends RefCounted
## How the game looks: files, frame names, scales, colours, text sizes and screen layout (docs/GODOT_PLAN.md §4-5;
## the SPRITE section of src/config.ts and the HUD layout of src/scenes/ in the Phaser version, commit 0a0841f).
## The geometry the rules use (road, lanes, hitboxes, anchor) lives in scripts/sim/config.gd; this file only says
## how to draw it.
##
## Pixel rules. The viewport is 640x360 and the window shows it at a whole-number scale with Nearest filtering
## (project.godot, checked by tools/scalecheck.gd). The view draws sprites and tiles at whole-number scales on whole
## pixels, and text in Press Start 2P at multiples of 8 px, the font's grid. tests/test_assets.gd checks the scales
## and that every frame named here exists; tests/test_view.gd checks the layout.

const VIEW_W := 640
const VIEW_H := 360

# --- Files. The atlas is load()ed; its frame map is read with FileAccess and JSON (plan §2).
const ATLAS_PNG := "res://assets/sprites.png"
const ATLAS_JSON := "res://assets/sprites.json"
## Imported with antialiasing, hinting and subpixel positioning off (its .import file, plan §2).
const FONT_FILE := "res://assets/font/press-start-2p-latin-400-normal.woff2"

# --- Scales.
## Sprites are drawn at 2x: cars 16x24, the small car 12x20, the truck 20x40, oil 20x12 (plan §4). Each sprite is
## 2 px wider than its hitbox, 1 px on each side.
const SPRITE_SCALE := 2
## Road, verge and grass tiles are 8 px, drawn at 2x (16 px). A tile pixel is then as wide as a barrier (2 px).
const TILE_SIZE := 8
const TILE_SCALE := 2
const TILE := TILE_SIZE * TILE_SCALE
## Bushes are 16 px tiles, drawn at 2x.
const BUSH_SCALE := 2

# --- Text sizes, all multiples of 8.
const TEXT_SMALL := 8
const TEXT_MEDIUM := 16
const TEXT_LARGE := 24
const TEXT_HUGE := 32
const TEXT_SIZES := [TEXT_SMALL, TEXT_MEDIUM, TEXT_LARGE, TEXT_HUGE]

# --- Colours picked from the sprite sheet (PALETTE in src/render/draw.ts).
const BLACK := Color("#141414")
const WHITE := Color("#f0eeec")
const GREY := Color("#a69f96")
const ASPHALT := Color("#67615f")
const GRASS := Color("#42ad37")
const YELLOW := Color("#f1bb3b")
const RED := Color("#ae2633")
const LIGHT_RED := Color("#f26864")

# --- Road tiles. The edge tiles carry the barrier: a white line one tile pixel wide, in column 1 of the left tile
# and column 6 of the right one. road.gd places the tiles so that those lines are the 2 px barriers just outside the
# road (x 186-188 and 452-454), and the verge tiles are grass for their first (left) or last (right) 5 columns.
const ROAD_ASPHALT := "road_asphalt_tile"
const ROAD_EDGE_LEFT := "road_edge_left_tile"
const ROAD_EDGE_RIGHT := "road_edge_right_tile"
const ROAD_VERGE_LEFT := "road_verge_left_tile"
const ROAD_VERGE_RIGHT := "road_verge_right_tile"
const EDGE_LINE_LEFT := 1
const EDGE_LINE_RIGHT := 6
const VERGE_GRASS_COLUMNS := 5
## Grass rows cycle through these, so the roadside visibly scrolls. The right side is 3 rows out of step.
const GRASS_ROWS := [
	"grass_tile", "grass_tufts_tile", "grass_tile", "grass_tile", "grass_flowers_tile", "grass_tile", "grass_tufts_tile"
]
const GRASS_RIGHT_SHIFT := 3
## The barrier width (one tile pixel at TILE_SCALE).
const BARRIER_W := 2
## Lane dashes between the six lanes, drawn in code: the sheet only has a two-lane centre line.
## Phaser: 40 px period, 24 px dashes, 4 px wide; here about x K, on whole pixels.
const DASH_PERIOD := 24
const DASH_LENGTH := 14
const DASH_W := 2
## Roadside bushes, in the grass between each HUD panel and the verge. The right side trails the left by
## BUSH_STAGGER so the two sides do not line up (Phaser: 120 and 60 px; here about x K, on whole pixels).
const BUSH := "grass_bush"
const BUSH_PERIOD := 72
const BUSH_STAGGER := 36

# --- Sprites: a frame, and the width of its shadow in texture pixels. The shadow (1 px on the right and bottom of
# the sheet's cars) is left out when a sprite is centred on its hitbox. All sprites are drawn at SPRITE_SCALE.
## The player. Phase B recolours it for six seats (B2).
const PLAYER := {"frame": "car_red", "shadow": 1}
## Turned 45 degrees towards the slide while skidding.
const PLAYER_SKID_LEFT := {"frame": "car_red_ccw45", "shadow": 1}
const PLAYER_SKID_RIGHT := {"frame": "car_red_cw45", "shadow": 1}
## Traffic, indexed by Config.KIND_*: yellow (the small car), red (the salmon car, since car_red is the player), blue,
## truck (drawn in code), fuel car (the white police car, tinted with the rainbow) and oil (drawn in code).
const TRAFFIC := [
	{"frame": "car_small_yellow", "shadow": 1},
	{"frame": "car_salmon", "shadow": 1},
	{"frame": "car_blue", "shadow": 1},
	{"frame": "truck", "shadow": 1},
	{"frame": "car_police", "shadow": 1},
	{"frame": "oil_puddle", "shadow": 0},
]
## Flat colours drawn on the hitbox if a frame is missing (Phaser's rectangle look).
const TRAFFIC_FALLBACK := [
	Color("#f4d03f"), Color("#c0392b"), Color("#2e86de"), Color("#7f8c8d"), Color("#ffffff"), Color("#222222")
]
const PLAYER_FALLBACK := Color("#e74c3c")

# --- Animation, in simulation ticks (60 per second) so it is the same at any frame rate and freezes with a pause.
## While invulnerable the player is hidden on every other 6 ticks (10 Hz, INVULNERABLE_BLINK_HZ in Phaser).
const BLINK_TICKS := 6
## Nitro flames behind a car: shortest length and extra flicker (px), ticks per flicker step, outer and inner colour.
const FLAME_MIN := 4
const FLAME_FLICKER := 4
const FLAME_STEP_TICKS := 2
const FLAME_OUTER := Color("#ae2633")
const FLAME_INNER := Color("#f1bb3b")
## A race's finish line: its height in px.
const FINISH_H := 8
## The fuel car's hue turns 4 degrees a tick: a full circle every 1.5 s (Phaser: time x 240).
const RAINBOW_DEGREES_PER_TICK := 4

# --- HUD on the game screen: two side panels, outside the road and its verges (x 168-472).
const PANEL_LEFT := Rect2i(8, 8, 112, 344)
const PANEL_RIGHT := Rect2i(520, 8, 112, 344)
## Dark enough that the grass scrolling underneath does not break up the small text.
const PANEL_ALPHA := 0.85
## Rows of the full-height panels, as screen y: a TEXT_SMALL label at the row's y, its TEXT_MEDIUM value
## HUD_VALUE_DY px lower. Text is centred in its panel.
const HUD_ROW_Y := [20, 60, 100]
const HUD_VALUE_DY := 12
## The goal (stage progress) gauge in the left panel and the fuel gauge in the right one.
const GAUGE_LABEL_Y := 140
const GAUGE_W := 16
const GAUGE_TOP := 152
const GAUGE_BOTTOM := 340
## Fuel below this shows the gauge and its number in light red.
const LOW_FUEL := 20.0
## Event messages: centred on the road, for 1 s.
const MESSAGE_CENTRE_Y := 160
const MESSAGE_SECONDS := 1.0
const MESSAGE_LINE_GAP := 8

# --- Pause, stage-clear and game-over panels: a TEXT_MEDIUM title over TEXT_SMALL lines, 8 px between lines.
const OVERLAY_DIM := 0.55
const OVERLAY_PADDING := 24
const OVERLAY_TITLE_GAP := 40
const OVERLAY_LINE_STEP := 16
const OVERLAY_LINE_GAP := 8
const PAUSE_PANEL_W := 260
const RESULT_PANEL_W := 300

# --- Title screen.
const TITLE := "FUEL RIVALS"
const TITLE_TOP := 20
## Key and pad controls, in boxes on the grass either side of the road: a medium heading, then small lines.
const CONTROLS_LEFT := Rect2i(8, 64, 160, 188)
const CONTROLS_RIGHT := Rect2i(472, 64, 160, 188)
const CONTROLS_PADDING := 8
const CONTROLS_LINES_DY := 40
const CONTROLS_LINE_STEP := 16
const CONTROLS_KEYBOARD := [
	"UP W Z  throttle",
	"X       nitro",
	"        2x accel,",
	"        6 s tank",
	"DOWN S  brake",
	"LEFT A  steer",
	"RIGHT D steer",
	"ESC P   pause",
	"ENTER   start",
]
const CONTROLS_PAD := [
	"B       throttle",
	"A       nitro",
	"        2x accel,",
	"        6 s tank",
	"DOWN    brake",
	"STICK   steer",
	"D-PAD   steer",
	"START   pause",
	"A START start",
]
## The choices, top to bottom: LOCAL (the join screen: people on this machine, bots in the empty seats) and ONLINE (the
## login and the queue, or the private rooms without an API) and RANKING (the leaderboard). Up and Down move between them; the one shown is
## drawn lit. A click or tap on a button picks it too.
const TITLE_CHOICES := ["LOCAL", "ONLINE", "RANKING"]
## The LOCAL button (the name it had when it was the only one, START).
const START_BUTTON := Rect2i(240, 68, 160, 28)
const VERSUS_BUTTON := Rect2i(240, 102, 160, 28)
## The RANKING button: the leaderboard of the session (docs/SPEC_RANKING.md).
const RANKING_BUTTON := Rect2i(240, 136, 160, 28)
## The player's car, still, in its start lane.
const TITLE_CAR_TOP := 208
## Footer lines, each on a dark band so the lane dashes behind do not cut through the text: y of the band's top.
const PROMPT_BAND_Y := 264
const BEST_BAND_Y := 312
const BAND_H := 24
const BAND_ALPHA := 0.7
const PROMPT := "UP / DOWN CHOOSE    ENTER / SPACE / A / START GO"
## On the best score's band: the best on the left half, the fullscreen keys on the right half.
const FULLSCREEN_HINT := "F11 / ALT+ENTER  FULLSCREEN"
## The same in the browser, which keeps F11 and Alt+Enter for itself.
const FULLSCREEN_HINT_WEB := "F  FULLSCREEN"
## The web title waits for a key or a click before any sound (browsers block audio until then).
const PROMPT_WEB := "PRESS ANY KEY"
## The same, and the footer, on a touch device.
const PROMPT_WEB_TOUCH := "TAP TO START"
const PROMPT_TOUCH := "TAP A BUTTON OR USE THE PAD"
const FULLSCREEN_HINT_TOUCH := ""
## The prompt blinks between full and this alpha every half second.
const PROMPT_DIM_ALPHA := 0.35
const PROMPT_BLINK_SECONDS := 0.5
