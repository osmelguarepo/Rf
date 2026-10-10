import type { GameInput } from './game/types';

/**
 * Keyboard and gamepad → GameInput snapshot. Uses plain DOM events and the Gamepad API,
 * so it does not depend on Phaser and works unchanged in an Electron wrapper.
 *
 * Held actions (up/down/left/right) are read as state. Edge actions (gears, confirm, pause)
 * are true only on the frame they were pressed; read() clears them.
 */

type Action = 'up' | 'down' | 'left' | 'right' | 'high' | 'low' | 'confirm' | 'pause';
const EDGE_ACTIONS: ReadonlySet<Action> = new Set(['high', 'low', 'confirm', 'pause']);

const KEY_ACTIONS: Readonly<Record<string, Action>> = {
  ArrowUp: 'up',
  KeyW: 'up',
  ArrowDown: 'down',
  KeyS: 'down',
  ArrowLeft: 'left',
  KeyA: 'left',
  ArrowRight: 'right',
  KeyD: 'right',
  KeyX: 'high',
  KeyZ: 'low',
  Enter: 'confirm',
  Space: 'confirm',
  Escape: 'pause',
  KeyP: 'pause',
};

/** Standard Gamepad mapping. */
const PAD_BUTTONS: ReadonlyArray<readonly [number, Action]> = [
  [12, 'up'],
  [13, 'down'],
  [14, 'left'],
  [15, 'right'],
  [0, 'high'], // A: high gear, and also confirms menus
  [1, 'low'], // B: low gear
  [9, 'pause'], // Start: pause, and also confirms menus
];
const PAD_STICK_THRESHOLD = 0.5;

export class InputController {
  private readonly held = new Set<Action>();
  private readonly edges = new Set<Action>();
  private readonly padPrev = new Map<Action, boolean>();

  constructor(target: Window = window) {
    target.addEventListener('keydown', this.onKeyDown);
    target.addEventListener('keyup', this.onKeyUp);
    // Losing focus mid-hold must not leave keys stuck down.
    target.addEventListener('blur', this.clearHeld);
  }

  private readonly onKeyDown = (event: KeyboardEvent): void => {
    const action = KEY_ACTIONS[event.code];
    if (!action) return;
    if (event.code.startsWith('Arrow') || event.code === 'Space') event.preventDefault();
    if (EDGE_ACTIONS.has(action) && !event.repeat) this.edges.add(action);
    this.held.add(action);
  };

  private readonly onKeyUp = (event: KeyboardEvent): void => {
    const action = KEY_ACTIONS[event.code];
    if (action) this.held.delete(action);
  };

  private readonly clearHeld = (): void => {
    this.held.clear();
  };

  /** Builds this frame's input. Edge actions are consumed, so each press is seen once. */
  read(): GameInput {
    const padHeld = new Set<Action>();
    const padEdges = new Set<Action>();
    this.readGamepads(padHeld, padEdges);

    const has = (action: Action): boolean => this.held.has(action) || padHeld.has(action);
    const edge = (action: Action): boolean => this.edges.has(action) || padEdges.has(action);

    const left = has('left');
    const right = has('right');
    const input: GameInput = {
      accel: has('up'),
      brake: has('down'),
      steer: left === right ? 0 : right ? 1 : -1,
      highGearPressed: edge('high'),
      lowGearPressed: edge('low'),
      pausePressed: edge('pause'),
      confirmPressed: edge('confirm'),
    };

    this.edges.clear();
    return input;
  }

  private readGamepads(padHeld: Set<Action>, padEdges: Set<Action>): void {
    if (typeof navigator === 'undefined' || typeof navigator.getGamepads !== 'function') return;

    const pads = Array.from(navigator.getGamepads()).filter((p): p is Gamepad => p !== null);
    const nowPressed = new Map<Action, boolean>();

    for (const pad of pads) {
      for (const [index, action] of PAD_BUTTONS) {
        if (pad.buttons[index]?.pressed) nowPressed.set(action, true);
      }
      const x = pad.axes[0] ?? 0;
      const y = pad.axes[1] ?? 0;
      if (x < -PAD_STICK_THRESHOLD) nowPressed.set('left', true);
      if (x > PAD_STICK_THRESHOLD) nowPressed.set('right', true);
      if (y < -PAD_STICK_THRESHOLD) nowPressed.set('up', true);
      if (y > PAD_STICK_THRESHOLD) nowPressed.set('down', true);
    }

    for (const action of new Set(PAD_BUTTONS.map(([, a]) => a))) {
      const pressed = nowPressed.get(action) === true;
      if (pressed) padHeld.add(action);
      if (pressed && !this.padPrev.get(action) && EDGE_ACTIONS.has(action)) padEdges.add(action);
      this.padPrev.set(action, pressed);
    }
  }

  dispose(target: Window = window): void {
    target.removeEventListener('keydown', this.onKeyDown);
    target.removeEventListener('keyup', this.onKeyUp);
    target.removeEventListener('blur', this.clearHeld);
  }
}

let shared: InputController | null = null;

/** One shared controller for the whole page, so edge presses are consumed exactly once. */
export function getInput(): InputController {
  if (!shared) shared = new InputController();
  return shared;
}
