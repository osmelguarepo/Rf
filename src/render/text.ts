import type { Types } from 'phaser';
import { cssColour, PALETTE } from './draw';

/**
 * Press Start 2P (public/assets/font, OFL-1.1), loaded by BootScene before any text is made.
 * The font is drawn on an 8 px grid, so it stays sharp only at multiples of 8 px and at whole-pixel positions.
 * Bold would smear it, so no style here uses bold.
 */
export const FONT_FAMILY = 'Press Start 2P';
const FONT_STACK = `"${FONT_FAMILY}", monospace`;

export type FontSize = 8 | 16 | 24;

type TextStyle = Types.GameObjects.Text.TextStyle;

/** Text colours, from the sprite sheet's palette. */
export const INK = {
  white: cssColour(PALETTE.white),
  yellow: cssColour(PALETTE.yellow),
  grey: cssColour(PALETTE.grey),
  black: cssColour(PALETTE.black),
} as const;

/** A text style in the pixel font. */
export function pixelText(size: FontSize, color: string = INK.white, extra: TextStyle = {}): TextStyle {
  return { fontFamily: FONT_STACK, fontSize: `${size}px`, color, ...extra };
}

/**
 * The pixel font with a hard drop shadow one font pixel down and to the right.
 * Phaser does not grow the text canvas for a shadow, so padding makes room for it.
 */
export function shadowedText(size: FontSize, color: string, extra: TextStyle = {}): TextStyle {
  const offset = size / 8;
  return pixelText(size, color, {
    shadow: { offsetX: offset, offsetY: offset, color: INK.black, blur: 0, stroke: false, fill: true },
    padding: { right: offset, bottom: offset },
    ...extra,
  });
}
