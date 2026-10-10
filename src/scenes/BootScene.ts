import Phaser from 'phaser';
import { SPRITE } from '../config';
import { getInput } from '../input';
import { addPixelArtTextures } from '../render/pixelArt';
import { addAtlasFrames } from '../render/sprites';
import { FONT_FAMILY } from '../render/text';

/** Files under public/. The URLs are relative, so they also resolve from dist/ (Vite base './'). */
const FILES = {
  atlasImage: 'assets/sprites.png',
  atlasFrames: 'assets/sprites.json',
  font: 'assets/font/press-start-2p-latin-400-normal.woff2',
} as const;

/**
 * Loads the sprite atlas, its frame map and the pixel font, builds the sprite frames, then starts the title screen.
 * No text exists before this finishes, so text never appears in a fallback font first.
 * If a file fails to load, the game still runs: without the atlas the scenes draw rectangles, and without the font
 * Phaser logs a warning and text uses monospace.
 */
export class BootScene extends Phaser.Scene {
  constructor() {
    super('Boot');
  }

  preload(): void {
    // Listen for keys from the start, so a press made while the assets load still reaches the title screen.
    getInput();

    this.load.image(SPRITE.atlas, FILES.atlasImage);
    this.load.json(SPRITE.atlas, FILES.atlasFrames);
    // The loader loads the font through the FontFace API and adds it to document.fonts before create() runs.
    this.load.font(FONT_FAMILY, FILES.font, 'woff2');
  }

  create(): void {
    if (this.textures.exists(SPRITE.atlas)) {
      addAtlasFrames(this.textures.get(SPRITE.atlas), this.cache.json.get(SPRITE.atlas));
    }
    addPixelArtTextures(this.textures);
    this.scene.start('Title');
  }
}
