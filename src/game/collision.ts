/** Axis-aligned rectangle. (x, y) is the top-left corner in logical pixels. */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** True when the two rectangles overlap. Touching edges do not count as overlap. */
export function overlaps(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}
