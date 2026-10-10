import Phaser from 'phaser';
import { GAME_TITLE, PLAYER, VIEW } from '../config';
import { getInput } from '../input';
import { COLOURS, drawBackdrop } from '../render/draw';
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

const TEXT_STYLE = {
  fontFamily: 'monospace',
  fontSize: '13px',
  color: '#ffffff',
};

export class TitleScene extends Phaser.Scene {
  private prompt?: Phaser.GameObjects.Text;
  private starting = false;

  constructor() {
    super('Title');
  }

  create(): void {
    this.starting = false;
    const bg = this.add.graphics();
    drawBackdrop(bg, 0);

    // Decorative player car, drawn as a rectangle like in the game.
    const car = this.add.graphics();
    car.fillStyle(COLOURS.playerBody, 1).fillRect(VIEW.width / 2 - 13, 150, PLAYER.width, PLAYER.height);
    car.fillStyle(COLOURS.playerWindow, 1).fillRect(VIEW.width / 2 - 9, 156, PLAYER.width - 8, 10);

    this.add
      .text(VIEW.width / 2, 90, GAME_TITLE, {
        fontFamily: 'monospace',
        fontSize: '30px',
        fontStyle: 'bold',
        color: '#ffd23f',
        stroke: '#000000',
        strokeThickness: 4,
      })
      .setOrigin(0.5);

    const panel = this.add.graphics();
    panel.fillStyle(0x000000, 0.7).fillRect(20, 220, VIEW.width - 40, 250);
    panel.lineStyle(2, 0xffd23f, 1).strokeRect(20, 220, VIEW.width - 40, 250);

    this.add.text(36, 236, 'CONTROLS', { ...TEXT_STYLE, color: '#ffd23f', fontStyle: 'bold' });
    this.add.text(36, 262, CONTROLS.join('\n'), { ...TEXT_STYLE, lineSpacing: 4 });

    const button = this.add.rectangle(VIEW.width / 2, 500, 180, 46, COLOURS.playerBody).setInteractive({ useHandCursor: true });
    this.add
      .text(VIEW.width / 2, 500, 'START', { ...TEXT_STYLE, fontSize: '20px', fontStyle: 'bold' })
      .setOrigin(0.5);
    button.on('pointerdown', () => this.startGame());

    this.prompt = this.add
      .text(VIEW.width / 2, 548, 'PRESS ENTER / SPACE / GAMEPAD START', { ...TEXT_STYLE, fontSize: '11px' })
      .setOrigin(0.5);

    this.add
      .text(VIEW.width / 2, 610, `BEST THIS SESSION: ${session.highScore}`, { ...TEXT_STYLE, color: '#bbbbbb' })
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
