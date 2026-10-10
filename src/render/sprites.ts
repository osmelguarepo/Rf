import type { GameObjects, Scene, Textures } from 'phaser';
import type { FrameStyle, SpriteTarget } from './draw';

/** Phaser's built-in 4×4 white texture. Tinted and stretched, it draws flat rectangles. */
const WHITE = '__WHITE';
/** Frame name of a whole texture, for textures that are not atlases (the code-drawn sprites). */
const WHOLE = '__BASE';

interface FrameRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

function isFrameRect(value: unknown): value is FrameRect {
  if (typeof value !== 'object' || value === null) return false;
  const rect = value as Record<string, unknown>;
  return ['x', 'y', 'w', 'h'].every((field) => Number.isInteger(rect[field]));
}

/**
 * Adds the frames listed in sprites.json to the loaded atlas texture. The file is a plain map of
 * frame name → {x, y, w, h}, not Phaser's atlas format. Returns the number of frames added.
 * Malformed entries are skipped with a warning.
 */
export function addAtlasFrames(texture: Textures.Texture, map: unknown): number {
  if (typeof map !== 'object' || map === null) {
    console.warn('Sprite atlas: the frame map is missing or not an object');
    return 0;
  }
  let added = 0;
  for (const [name, rect] of Object.entries(map)) {
    if (!isFrameRect(rect)) {
      console.warn(`Sprite atlas: frame "${name}" is malformed and was skipped`);
      continue;
    }
    if (texture.add(name, 0, rect.x, rect.y, rect.w, rect.h)) added += 1;
  }
  return added;
}

interface FrameSource {
  key: string;
  frame: string;
  w: number;
  h: number;
}

/**
 * The target a scene draws its world on: a SpriteLayer when the atlas loaded, otherwise a Graphics object, which the
 * draw functions fill with the rectangle look. Either way, call clear() before each redraw.
 */
export function createWorldTarget(scene: Scene, atlas: string): SpriteLayer | GameObjects.Graphics {
  return scene.textures.exists(atlas) ? new SpriteLayer(scene, atlas) : scene.add.graphics();
}

/**
 * Draws sprite frames and flat rectangles in call order, like a Graphics object draws shapes.
 *
 * Frame names are looked up in the atlas first, then as texture keys (the sprites drawn in code). Images are pooled:
 * clear() hides them all, and the next drawing reuses them in the same order. They live in one Phaser Layer, made
 * when the SpriteLayer is made, so they keep that place in the scene's display list however many are added later.
 * Positions are rounded to whole pixels, so scaled sprites stay on the pixel grid.
 */
export class SpriteLayer implements SpriteTarget {
  private readonly scene: Scene;
  private readonly atlas: string;
  private readonly layer: GameObjects.Layer;
  private readonly pool: GameObjects.Image[] = [];
  private readonly sources = new Map<string, FrameSource | null>();
  private used = 0;

  constructor(scene: Scene, atlas: string) {
    this.scene = scene;
    this.atlas = atlas;
    this.layer = scene.add.layer();
  }

  /** Starts a new drawing: everything drawn since the last clear is hidden. */
  clear(): this {
    for (let i = 0; i < this.used; i++) this.pool[i]?.setVisible(false);
    this.used = 0;
    return this;
  }

  frameSize(name: string): { w: number; h: number } | undefined {
    const source = this.source(name);
    return source ? { w: source.w, h: source.h } : undefined;
  }

  drawFrame(name: string, x: number, y: number, scale: number, style: FrameStyle = {}): void {
    const source = this.source(name);
    if (!source) return;
    const image = this.next();
    if (image.texture.key !== source.key || image.frame.name !== source.frame) image.setTexture(source.key, source.frame);
    image
      .setPosition(Math.round(x), Math.round(y))
      .setScale(scale)
      .setFlipX(style.flipX ?? false)
      .setAlpha(style.alpha ?? 1);
    if (style.tint === undefined) image.clearTint();
    else image.setTint(style.tint);
  }

  drawRect(x: number, y: number, w: number, h: number, colour: number, alpha = 1): void {
    const image = this.next();
    if (image.texture.key !== WHITE) image.setTexture(WHITE);
    image
      .setPosition(Math.round(x), Math.round(y))
      .setDisplaySize(Math.round(w), Math.round(h))
      .setFlipX(false)
      .setAlpha(alpha)
      .setTint(colour);
  }

  private source(name: string): FrameSource | null {
    let source = this.sources.get(name);
    if (source === undefined) {
      source = this.lookUp(name);
      this.sources.set(name, source);
    }
    return source;
  }

  private lookUp(name: string): FrameSource | null {
    const textures = this.scene.textures;
    if (textures.exists(this.atlas) && textures.get(this.atlas).has(name)) {
      const frame = textures.getFrame(this.atlas, name);
      return { key: this.atlas, frame: name, w: frame.width, h: frame.height };
    }
    if (textures.exists(name)) {
      const frame = textures.getFrame(name, WHOLE);
      return { key: name, frame: WHOLE, w: frame.width, h: frame.height };
    }
    return null;
  }

  private next(): GameObjects.Image {
    let image = this.pool[this.used];
    if (!image) {
      image = this.scene.add.image(0, 0, WHITE).setOrigin(0, 0);
      this.layer.add(image);
      this.pool.push(image);
    }
    this.used += 1;
    return image.setVisible(true);
  }
}
