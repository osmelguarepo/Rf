import Phaser from 'phaser';
import { GAME_TITLE, PLAYER, SPRITE, VIEW } from '../config';
import { createCar } from '../game/car';
import { laneX } from '../game/traffic';
import { getInput } from '../input';
import { drawBackdrop, drawBox, drawPlayer, PALETTE } from '../render/draw';
import { createWorldTarget } from '../render/sprites';
import { INK, pixelText, shadowedText } from '../render/text';
import { session } from '../session';

const CONTROLS = [
  'UP / W / Z (B)  Accelerate',
  'DOWN / S        Brake',
  'LEFT / RIGHT    Steer (or A / D)',
  'X (A), held     High gear: 400 km/h,',
  '                slow to start',
  'ESC / P         Pause',
  '',
  'Gamepad: stick / D-pad, B throttle,',
  'A high gear, Start pause / confirm',
];

const PANEL = { x: 20, y: 220, w: VIEW.width - 40, h: 250 } as const;
const BUTTON = { y: 500, w: 180, h: 46 } as const;
/** The two footer lines, each on a dark band so the lane dashes behind do not cut through the text. */
const FOOTER = { promptY: 548, bestY: 610, band: 24 } as const;

export class TitleScene extends Phaser.Scene {
  private prompt?: Phaser.GameObjects.Text;
  private starting = false;

  constructor() {
    super('Title');
  }

  create(): void {
    this.starting = false;

    // The road, still, with the player's car in the middle lane, as in the game.
    const road = createWorldTarget(this, SPRITE.atlas);
    drawBackdrop(road, 0);
    drawPlayer(road, { ...createCar(laneX(1, PLAYER.width)), y: 150 }, 0);

    this.add
      .text(VIEW.width / 2, 90, GAME_TITLE, shadowedText(24, INK.yellow, { align: 'center', wordWrap: { width: VIEW.width - 20 } }))
      .setOrigin(0.5);

    const panel = this.add.graphics();
    drawBox(panel, PANEL.x, PANEL.y, PANEL.w, PANEL.h, PALETTE.yellow, 0.8);

    this.add.text(PANEL.x + 16, PANEL.y + 16, 'CONTROLS', pixelText(16, INK.yellow));
    this.add.text(PANEL.x + 16, PANEL.y + 48, CONTROLS.join('\n'), pixelText(8, INK.white, { lineSpacing: 8 }));

    const button = this.add
      .rectangle(VIEW.width / 2, BUTTON.y, BUTTON.w, BUTTON.h, PALETTE.red)
      .setStrokeStyle(2, PALETTE.lightRed)
      .setInteractive({ useHandCursor: true });
    this.add.text(VIEW.width / 2, BUTTON.y, 'START', shadowedText(16, INK.white)).setOrigin(0.5);
    button.on('pointerdown', () => this.startGame());

    const footer = this.add.graphics().fillStyle(0x000000, 0.7);
    for (const y of [FOOTER.promptY, FOOTER.bestY]) footer.fillRect(0, y - FOOTER.band / 2, VIEW.width, FOOTER.band);

    this.prompt = this.add
      .text(VIEW.width / 2, FOOTER.promptY, 'PRESS ENTER / SPACE / GAMEPAD START', pixelText(8, INK.white))
      .setOrigin(0.5);

    this.add
      .text(VIEW.width / 2, FOOTER.bestY, `BEST THIS SESSION: ${session.highScore}`, pixelText(8, INK.grey))
      .setOrigin(0.5);
  }

  update(time: number): void {
    if (this.prompt) this.prompt.setAlpha(Math.floor(time / 500) % 2 === 0 ? 1 : 0.35);
    if (getInput().read().confirmPressed) this.startGame();
  }

  private startGame(): void {
    if (this.starting) return;
    this.starting = true;
    this.scene.start('Game');
  }
}
