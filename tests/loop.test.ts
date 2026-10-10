import { describe, expect, it } from 'vitest';
import { SIM_STEP } from '../src/config';
import { advance, MAX_STEPS_PER_FRAME } from '../src/game/loop';
import { latchEdges, NO_EDGES } from '../src/game/edges';

describe('advance (fixed timestep)', () => {
  it('runs one step per 1/60 s of frame time', () => {
    const r = advance(0, SIM_STEP * 2 + 0.001);
    expect(r.steps).toBe(2);
    expect(r.accumulator).toBeCloseTo(0.001, 9);
  });

  it('a frame shorter than one step runs zero steps and carries the time over', () => {
    const r = advance(0, SIM_STEP / 2);
    expect(r.steps).toBe(0);
    expect(r.accumulator).toBeCloseTo(SIM_STEP / 2, 9);
  });

  it('a 240 Hz display still averages exactly one step per 1/60 s', () => {
    let acc = 0;
    let steps = 0;
    for (let i = 0; i < 240; i++) {
      const r = advance(acc, 1 / 240);
      acc = r.accumulator;
      steps += r.steps;
    }
    expect(steps).toBe(60);
  });

  it('a huge frame (tab switch) is clamped and never runs more than the per-frame cap', () => {
    const r = advance(0, 5);
    expect(r.steps).toBeLessThanOrEqual(MAX_STEPS_PER_FRAME);
    expect(r.accumulator).toBe(0);
  });

  it('negative or NaN-like inputs do not run steps', () => {
    expect(advance(0, -1).steps).toBe(0);
  });
});

describe('latchEdges', () => {
  it('keeps a press that has not been consumed yet', () => {
    const pending = latchEdges(NO_EDGES, { ...NO_EDGES, confirmPressed: true });
    const next = latchEdges(pending, NO_EDGES);
    expect(next.confirmPressed).toBe(true);
  });

  it('combines simultaneous presses of different actions', () => {
    const out = latchEdges({ ...NO_EDGES, highGearPressed: true }, { ...NO_EDGES, pausePressed: true });
    expect(out).toEqual({ ...NO_EDGES, highGearPressed: true, pausePressed: true });
  });
});
