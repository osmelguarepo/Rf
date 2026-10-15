extends RefCounted
## Axis-aligned rectangle overlap, as src/game/collision.ts. (x, y) is the top-left corner with y growing down.
## Touching edges do not count. No Rect2: it stores 32-bit floats.
##
## World y grows forward (up the screen), so world.gd passes -y_world as the "top": a car whose front edge is at
## y_world spans the down-axis interval [-y_world, -y_world + h]. Negation is exact.


static func overlaps(ax: float, ay: float, aw: float, ah: float, bx: float, by: float, bw: float, bh: float) -> bool:
	return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
