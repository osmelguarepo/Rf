import Phaser from 'phaser';
import { SIM_STEP, SPRITE, VIEW } from '../config';
import { latchEdges, NO_EDGES, type EdgeFields } from '../game/edges';
import { advance } from '../game/loop';
import { createGame, step, type GameEvent, type GameState } from '../game/state';
import { getInput } from '../input';
import { drawBackdrop, drawGauge, drawPanel, drawPlayer, drawTraffic, PALETTE } from '../render/draw';
import { createWorldTarget, type SpriteLayer } from '../render/sprites';
import { INK, pixelText, shadowedText } from '../render/text';
import { session } from '../session';

const MESSAGE_SECONDS = 1;
/** Fuel below this many units shows the gauge in red. */
const LOW_FUEL = 20;

/** HUD layout. Text sits at whole pixels and in 8 or 16 px type, so the pixel font stays sharp. */
const HUD = {
  barHeight: 36,
  labelY: 6,
  valueY: 16,
  scoreX: 8,
  hiX: 132,
  rightX: VIEW.width - 8,
  panelY: 96,
  panelW: 60,
  panelH: 110,
  gauge: { y: 200, w: 16, h: 276, inset: 22 },
} as const;

/** Pause, stage-clear and game-over panels. Body lines are 8 px with 8 px between them. */
const PANEL = { padding: 24, titleGap: 40, lineSpacing: 8, lineStep: 16 } as const;

function newSeed(): number {
  return Math.floor(Math.random() * 0xffffffff) >>> 0;
}

export class GameScene extends Phaser.Scene {
  private state!: GameState;
  private accumulator = 0;
  private queued: EdgeFields = NO_EDGES;

  private world!: SpriteLayer | Phaser.GameObjects.Graphics;
  private hud!: Phaser.GameObjects.Graphics;
  private panel!: Phaser.GameObjects.Graphics;

  private scoreText!: Phaser.GameObjects.Text;
  private hiText!: Phaser.GameObjects.Text;
  private stageText!: Phaser.GameObjects.Text;
  private speedText!: Phaser.GameObjects.Text;
  private gearText!: Phaser.GameObjects.Text;
  private fuelText!: Phaser.GameObjects.Text;
  private messageText!: Phaser.GameObjects.Text;
  private panelTitle!: Phaser.GameObjects.Text;
  private panelBody!: Phaser.GameObjects.Text;

  private message = '';
  private messageTimer = 0;

  constructor() {
    super('Game');
  }

  create(): void {
    this.world = createWorldTarget(this, SPRITE.atlas);
    this.hud = this.add.graphics();
    this.panel = this.add.graphics();

    // Top bar: small labels over large values.
    this.add.text(HUD.scoreX, HUD.labelY, 'SCORE', pixelText(8, INK.yellow));
    this.add.text(HUD.hiX, HUD.labelY, 'HI', pixelText(8, INK.yellow));
    this.add.text(HUD.rightX, HUD.labelY, 'STAGE', pixelText(8, INK.yellow)).setOrigin(1, 0);
    this.scoreText = this.add.text(HUD.scoreX, HUD.valueY, '', pixelText(16));
    this.hiText = this.add.text(HUD.hiX, HUD.valueY, '', pixelText(16));
    this.stageText = this.add.text(HUD.rightX, HUD.valueY, '', pixelText(16)).setOrigin(1, 0);

    // Left panel: speed, gear and the goal gauge's label.
    this.speedText = this.add.text(6, 102, '', pixelText(16));
    this.add.text(6, 122, 'km/h', pixelText(8, INK.grey));
    this.add.text(6, 140, 'GEAR', pixelText(8, INK.yellow));
    this.gearText = this.add.text(6, 152, '', pixelText(16, INK.yellow));
    this.add.text(6, 186, 'GOAL', pixelText(8, INK.yellow));

    // Right panel: fuel.
    this.add.text(VIEW.width - 6, 102, 'FUEL', pixelText(8, INK.yellow)).setOrigin(1, 0);
    this.fuelText = this.add.text(VIEW.width - 6, 114, '', pixelText(16)).setOrigin(1, 0);

    this.messageText = this.add
      .text(
        VIEW.width / 2,
        300,
        '',
        shadowedText(16, INK.yellow, { align: 'center', lineSpacing: 8, wordWrap: { width: VIEW.width - 40 } }),
      )
      .setOrigin(0.5);

    // showPanel() sets their y.
    this.panelTitle = this.add.text(VIEW.width / 2, 0, '', shadowedText(16, INK.yellow)).setOrigin(0.5, 0);
    this.panelBody = this.add
      .text(VIEW.width / 2, 0, '', pixelText(8, INK.white, { align: 'center', lineSpacing: PANEL.lineSpacing }))
      .setOrigin(0.5, 0);

    this.state = createGame(newSeed(), session.highScore);
    this.accumulator = 0;
    this.queued = NO_EDGES;
    this.message = '';
    this.messageTimer = 0;
    this.render();

    // Losing focus, or hiding the tab, pauses the run so a player who alt-tabs does not crash while away.
    const pauseWhileAway = (): void => {
      if (this.state.phase === 'running') this.queued = latchEdges(this.queued, { ...NO_EDGES, pausePressed: true });
    };
    const onVisibility = (): void => {
      if (document.hidden) pauseWhileAway();
    };
    window.addEventListener('blur', pauseWhileAway);
    document.addEventListener('visibilitychange', onVisibility);
    this.events.once(Phaser.Scenes.Events.SHUTDOWN, () => {
      window.removeEventListener('blur', pauseWhileAway);
      document.removeEventListener('visibilitychange', onVisibility);
    });

    // Dev-only read hook so the Playwright smoke test can check real game state, not just pixels.
    if (import.meta.env.DEV) {
      (window as unknown as { __roadFighter?: { snapshot: () => unknown } }).__roadFighter = {
        snapshot: () => ({
          phase: this.state.phase,
          stage: this.state.stage,
          distance: this.state.distance,
          score: this.state.score,
          fuel: this.state.fuel.amount,
          speed: this.state.car.speed,
          carX: this.state.car.x,
          gear: this.state.car.gear,
          traffic: this.state.traffic.length,
        }),
      };
    }
  }

  update(_time: number, deltaMs: number): void {
    const held = getInput().read();
    // Presses wait here until a simulation step consumes them, so a frame with zero steps does not lose them.
    let pending = latchEdges(this.queued, held);

    if (this.state.phase === 'gameOver') {
      // Gear and pause presses from the death frame must not leak into the next run.
      this.queued = NO_EDGES;
      if (pending.pausePressed) {
        this.scene.start('Title');
        return;
      }
      if (pending.confirmPressed) {
        this.state = createGame(newSeed(), session.highScore);
        this.accumulator = 0;
      }
      this.render();
      return;
    }

    const frame = advance(this.accumulator, deltaMs / 1000, SIM_STEP);
    this.accumulator = frame.accumulator;
    for (let i = 0; i < frame.steps; i++) {
      this.state = step(this.state, { ...held, ...pending }, SIM_STEP);
      pending = NO_EDGES;
      this.handleEvents(this.state.events);
      session.highScore = Math.max(session.highScore, this.state.highScore);
      if (this.state.phase === 'stageClear' || this.state.phase === 'gameOver') break;
    }
    this.queued = pending;

    if (this.messageTimer > 0) this.messageTimer = Math.max(0, this.messageTimer - deltaMs / 1000);
    this.render();
  }

  private handleEvents(events: readonly GameEvent[]): void {
    // Game over has its own panel, so it gets no HUD message.
    if (events.includes('gameOver')) return;
    if (events.includes('spin')) this.setMessage('SPIN OUT!');
    else if (events.includes('crash')) this.setMessage('CRASH!');
    else if (events.includes('skid')) this.setMessage('OIL! STEER INTO THE SLIDE');
    else if (events.includes('pickup')) this.setMessage('FUEL!');
    else if (events.includes('pass')) this.setMessage('PASS +50');
  }

  private setMessage(text: string): void {
    this.message = text;
    this.messageTimer = MESSAGE_SECONDS;
  }

  private render(): void {
    const s = this.state;
    const time = s.time;

    this.world.clear();
    drawBackdrop(this.world, s.distance);
    drawTraffic(this.world, s.traffic, time);
    drawPlayer(this.world, s.car, time);

    this.hud.clear();
    this.hud.fillStyle(0x000000, 0.85).fillRect(0, 0, VIEW.width, HUD.barHeight);
    // Dark enough that the roadside bushes scrolling underneath do not break up the small text.
    this.hud.fillStyle(0x000000, 0.75).fillRect(0, HUD.panelY, HUD.panelW, HUD.panelH);
    this.hud.fillStyle(0x000000, 0.75).fillRect(VIEW.width - HUD.panelW, HUD.panelY, HUD.panelW, HUD.panelH);

    const { gauge } = HUD;
    const progress = Math.min(s.distance / s.goal, 1);
    drawGauge(this.hud, gauge.inset, gauge.y, gauge.w, gauge.h, progress, PALETTE.white);
    drawGauge(
      this.hud,
      VIEW.width - gauge.inset - gauge.w,
      gauge.y,
      gauge.w,
      gauge.h,
      s.fuel.amount / 100,
      s.fuel.amount < LOW_FUEL ? PALETTE.lightRed : PALETTE.grass,
    );

    this.scoreText.setText(String(s.score).padStart(6, '0'));
    this.hiText.setText(String(s.highScore).padStart(6, '0'));
    this.stageText.setText(String(s.stage));
    this.speedText.setText(String(Math.round(s.car.speed)));
    this.gearText.setText(s.car.gear === 'high' ? 'H' : 'L');
    this.fuelText.setText(String(Math.round(s.fuel.amount)));

    this.messageText.setText(this.messageTimer > 0 ? this.message : '');

    this.panel.clear();
    this.panelTitle.setText('');
    this.panelBody.setText('');
    if (s.phase === 'paused') {
      this.showPanel(260, 'PAUSED', ['ESC / P / START to resume']);
    } else if (s.phase === 'stageClear') {
      this.showPanel(280, `STAGE ${s.stage} CLEAR`, [
        `Score ${s.score}`,
        `Next: stage ${s.stage + 1}, busier road`,
        '',
        'ENTER / A to continue',
      ]);
    } else if (s.phase === 'gameOver') {
      this.showPanel(280, 'GAME OVER', [`Score ${s.score}`, `Best ${session.highScore}`, '', 'ENTER / A  retry', 'ESC / START  title']);
    }
  }

  /** Dims the screen and shows a centred panel sized to its text: a 16 px title over 8 px lines. */
  private showPanel(width: number, title: string, lines: readonly string[]): void {
    const height = PANEL.padding * 2 + PANEL.titleGap + lines.length * PANEL.lineStep - PANEL.lineSpacing;
    const top = Math.round((VIEW.height - height) / 2);
    drawPanel(this.panel, width, height);
    this.panelTitle.setText(title).setY(top + PANEL.padding);
    this.panelBody.setText(lines.join('\n')).setY(top + PANEL.padding + PANEL.titleGap);
  }
}
