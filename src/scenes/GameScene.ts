import Phaser from 'phaser';
import { SIM_STEP, VIEW } from '../config';
import { latchEdges, NO_EDGES, type EdgeFields } from '../game/edges';
import { advance } from '../game/loop';
import { createGame, step, type GameEvent, type GameState } from '../game/state';
import { getInput } from '../input';
import { COLOURS, drawBackdrop, drawGauge, drawPanel, drawPlayer, drawTraffic } from '../render/draw';
import { session } from '../session';

const HUD_STYLE = { fontFamily: 'monospace', fontSize: '12px', color: '#ffffff' };
const MESSAGE_SECONDS = 1;

function newSeed(): number {
  return Math.floor(Math.random() * 0xffffffff) >>> 0;
}

export class GameScene extends Phaser.Scene {
  private state!: GameState;
  private accumulator = 0;
  private queued: EdgeFields = NO_EDGES;

  private world!: Phaser.GameObjects.Graphics;
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
    this.world = this.add.graphics();
    this.hud = this.add.graphics();
    this.panel = this.add.graphics();

    this.scoreText = this.add.text(8, 8, '', HUD_STYLE);
    this.hiText = this.add.text(150, 8, '', HUD_STYLE);
    this.stageText = this.add.text(VIEW.width - 8, 8, '', HUD_STYLE).setOrigin(1, 0);

    this.speedText = this.add.text(6, 104, '', { ...HUD_STYLE, fontSize: '16px', fontStyle: 'bold' });
    this.gearText = this.add.text(6, 150, '', { ...HUD_STYLE, fontSize: '20px', fontStyle: 'bold', color: '#ffd23f' });
    this.add.text(6, 182, 'GOAL', { ...HUD_STYLE, fontSize: '10px' });
    this.fuelText = this.add.text(VIEW.width - 6, 104, '', HUD_STYLE).setOrigin(1, 0);

    this.messageText = this.add
      .text(VIEW.width / 2, 300, '', { ...HUD_STYLE, fontSize: '18px', fontStyle: 'bold', color: '#ffd23f' })
      .setOrigin(0.5);

    this.panelTitle = this.add
      .text(VIEW.width / 2, VIEW.height / 2 - 50, '', { ...HUD_STYLE, fontSize: '22px', fontStyle: 'bold', color: '#ffd23f' })
      .setOrigin(0.5);
    this.panelBody = this.add
      .text(VIEW.width / 2, VIEW.height / 2 - 10, '', { ...HUD_STYLE, fontSize: '13px', align: 'center', lineSpacing: 6 })
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
    if (events.includes('gameOver')) this.setMessage('GAME OVER');
    else if (events.includes('spin')) this.setMessage('SPIN OUT!');
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
    this.hud.fillStyle(0x000000, 0.85).fillRect(0, 0, VIEW.width, 36);
    this.hud.fillStyle(0x000000, 0.5).fillRect(0, 96, 60, 110);
    this.hud.fillStyle(0x000000, 0.5).fillRect(VIEW.width - 60, 96, 60, 110);

    const progress = Math.min(s.distance / s.goal, 1);
    drawGauge(this.hud, 22, 200, 18, 276, progress, COLOURS.laneDash);
    drawGauge(this.hud, VIEW.width - 40, 200, 18, 276, s.fuel.amount / 100, s.fuel.amount < 20 ? COLOURS.playerBody : 0x2ecc71);

    this.scoreText.setText(`SCORE ${String(s.score).padStart(6, '0')}`);
    this.hiText.setText(`HI ${String(s.highScore).padStart(6, '0')}`);
    this.stageText.setText(`STAGE ${s.stage}`);
    this.speedText.setText(`${Math.round(s.car.speed)}\nkm/h`);
    this.gearText.setText(s.car.gear === 'high' ? 'H' : 'L');
    this.fuelText.setText(`FUEL\n${Math.round(s.fuel.amount)}`);

    this.messageText.setText(this.messageTimer > 0 ? this.message : '');

    this.panel.clear();
    this.panelTitle.setText('');
    this.panelBody.setText('');
    if (s.phase === 'paused') {
      drawPanel(this.panel, 260, 150);
      this.panelTitle.setText('PAUSED');
      this.panelBody.setText('ESC / P / START to resume');
    } else if (s.phase === 'stageClear') {
      drawPanel(this.panel, 280, 170);
      this.panelTitle.setText(`STAGE ${s.stage} CLEAR`);
      this.panelBody.setText(`Score ${s.score}\nNext: stage ${s.stage + 1}, busier road\n\nENTER / A to continue`);
    } else if (s.phase === 'gameOver') {
      drawPanel(this.panel, 280, 190);
      this.panelTitle.setText('GAME OVER');
      this.panelBody.setText(`Score ${s.score}\nBest ${session.highScore}\n\nENTER / A  retry\nESC / START  title`);
    }
  }
}
