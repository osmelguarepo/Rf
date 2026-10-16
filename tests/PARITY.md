# Parity with the Phaser rule tests

The Phaser version (commit `0a0841f`, local tag `phaser-reference`) had 60 rule tests (`it()` blocks) in
`tests/{car,fuel,loop,state,traffic}.test.ts`: car 20, fuel 6, loop 7, state 16, traffic 11. Read them with
`git show 0a0841f:tests/car.test.ts`. Each row below maps one of them to the GDScript test that keeps its intent, or
says why it was dropped. `tests/test_parity.gd` checks this table: 60 rows, the right count per file, and every
`file::test` reference names a test method that exists.

The last column gives the expected values in the six-lane game (the `standard` profile of `scripts/sim/config.gd`)
where they differ from Phaser's. What changes, and why:

- **K = 360/640 = 0.5625.** Every px and px/s value is Phaser's × K. km/h, fuel, points and durations are unchanged
  (docs/GODOT_PLAN.md §4).
- **Six lanes of 44 px** from x = 188 to 452. The single player starts in lane 2 at x = 291 (centre 298), with its top
  edge on y = 292 (520 × K, rounded down).
- **Hitboxes:** player and cars 14 × 24, the small yellow car 10 × 20, truck 18 × 40, oil 18 × 12 (Phaser: 26 × 44,
  24 × 40, 30 × 60, 40 × 24).
- **Density:** car and oil gaps are also × 3/6, so six lanes keep Phaser's traffic per lane: car gap 98.4375 px
  (floor 56.25), oil 1125 ± 281.25 px. Fuel cars keep 4500 ± 1125 px (× K only).
- **Fixed step.** The port always steps 1/60 s. Phaser tests that called a rule with `dt = 1` or `dt = 0.1` are
  checked per tick, or over 60 ticks for one second.
- **World coordinates.** Phaser moved traffic in screen y. The port keeps world y for every car and object and
  derives the screen y from a monotonic camera, so these tests read positions through `World.screen_y()`.
- **Per-seat flags.** Phaser's `passed`, `struck` and `consumed` booleans are per-seat bit masks (`passed_mask`,
  `struck_mask`, `consumed_mask`); seat 0 is bit 1.

Besides these 60, `tests/test_golden.gd` replays the Phaser rules end to end: the RNG (1 000 000 outputs), 2000 steps
of the speed rule, 60 s without traffic, and three minutes of whole games in the `phaser` profile, exact to the bit.

## Rule tests

| ID | Phaser test (describe › it) | GDScript test | Expected values in the six-lane game |
|---|---|---|---|
| car-1 | gear › is high only while A (X) is held, low otherwise | `tests/test_car.gd::test_gear_is_high_only_while_held` | Unchanged. Also checked: high gear held without throttle. |
| car-2 | stepSpeed › low gear accelerates with the throttle and stops at 198 km/h | `tests/test_car.gd::test_low_gear_tops_out_at_198` | Unchanged: exactly 198 km/h after 20 s (1200 ticks). |
| car-3 | stepSpeed › high gear reaches 400 km/h | `tests/test_car.gd::test_high_gear_reaches_400` | Unchanged: exactly 400 km/h after 40 s (2400 ticks). |
| car-4 | stepSpeed › high gear is slow to start below 160 km/h, then faster | `tests/test_car.gd::test_high_gear_is_slow_below_160_then_faster` | Phaser used dt = 1 s (15 and 245). Per tick: 0.25 and 200.75; over 60 ticks: 15 and 245. |
| car-5 | stepSpeed › with no throttle the car coasts down with drag | `tests/test_car.gd::test_coasting_loses_drag` | Per tick 100 − 25/60; over 60 ticks 75 (Phaser, dt = 1 s: 75). |
| car-6 | stepSpeed › brake beats throttle and never goes below zero | `tests/test_car.gd::test_brake_beats_throttle_and_stops_at_zero` | Per tick 10 → 8; 0 exactly after 60 ticks. |
| car-7 | stepSpeed › above the gear top the car falls back at overspeedFall, not instantly | `tests/test_car.gd::test_overspeed_falls_back_at_25_per_second` | Per tick 350 − 25/60; 325 after 60 ticks. |
| car-8 | stepSpeed › holding the throttle above the gear top does not accelerate further | `tests/test_car.gd::test_throttle_above_the_gear_top_does_not_accelerate` | Unchanged: 203 → 203 − 25/60. |
| car-9 | steerRate › is zero while stopped and full from 30 km/h | `tests/test_car.gd::test_steer_rate_is_zero_stopped_and_full_from_30` | × K: 0 when stopped, 93.9375 px/s at 30 km/h (Phaser 167). |
| car-10 | steerRate › is about 150 px/s at 198 km/h and 130 px/s at 400 km/h | `tests/test_car.gd::test_steer_rate_at_198_and_400`, `tests/test_car.gd::test_steer_rate_is_phaser_times_k` | × K: 84.4875 px/s at 198 km/h, 73.125 at 400 (Phaser 150.2 and 130). Equal to Phaser × K at every speed from 0 to 420 km/h. |
| car-11 | stepLateral › steers at the speed-dependent rate | `tests/test_car.gd::test_steering_moves_at_the_speed_rate` | From x = 291 at 198 km/h: 292.408125 after one tick. |
| car-12 | stepLateral › steering into the barrier reports a roadside hit | `tests/test_car.gd::test_steering_into_the_barrier_is_a_roadside_hit` | Barriers at x = 188 and 452 − 14 = 438 (Phaser 60 and 274); the car is held there. |
| car-13 | stepLateral › a slide into the roadside reports a roadside hit | `tests/test_car.gd::test_a_slide_into_the_roadside_is_a_hit` | x = 188, slide −50.625 px/s (−90 × K); the slide stops. |
| car-14 | stepLateral › while skidding, steering does not move the car sideways | `tests/test_car.gd::test_skidding_ignores_steering` | The slide moves the car 0.84375 px per tick (Phaser 1.5). |
| car-15 | stepLateral › steering into the slide recovers it in about 15 steps (90 px/s at 360 px/s²) | `tests/test_car.gd::test_skid_recovers_in_15_steps` | Exactly 15 ticks in both profiles (50.625 px/s at 202.5 px/s²). |
| car-16 | stepLateral › steering against the slide, or not steering, leaves the slide speed unchanged | `tests/test_car.gd::test_steering_against_or_not_at_all_keeps_the_slide` | The slide stays 50.625 px/s. |
| car-17 | stepLateral › an uncorrected skid from the centre lane reaches the roadside within 2 seconds | `tests/test_car.gd::test_skid_time_to_the_edge_per_lane` | **Changes.** Ticks to the roadside from lanes 0–5: sliding left 18, 70, 123, 175, 227, 279; sliding right 279, 227, 175, 123, 70, 18. From the start lane (2): 123 ticks (2.05 s) left, 175 (2.92 s) right, so "within 2 s" holds only for lanes 0–1 sliding left and 4–5 sliding right. Phaser's centre lane: 72 ticks (1.2 s) either way, still checked in the `phaser` profile. |
| car-18 | crash and bump › a roadside crash drops speed to 30 % and starts invulnerability | `tests/test_car.gd::test_a_crash_drops_speed_to_30_percent_and_starts_invulnerability` | Speed × 0.3. Invulnerability is 91 ticks: Phaser's 1.5 s, counted down in float seconds, lasted 91 steps (1.5 − 90 × 1/60 leaves 3.3e-16). |
| car-19 | crash and bump › a bump keeps speed and starts a skid away from the other car | `tests/test_car.gd::test_a_bump_keeps_speed_and_skids_away` | Slide −50.625 px/s; 91 ticks of invulnerability. |
| car-20 | crash and bump › the car keeps the player-sized rectangle | `tests/test_car.gd::test_the_car_keeps_the_player_hitbox` | 14 × 24 (Phaser 26 × 44, kept in the `phaser` profile). |
| fuel-1 | drainFuel › drains 1 unit per second | `tests/test_fuel.gd::test_drains_one_unit_per_second` | Unchanged: 90 after 600 ticks (Phaser: one call with dt = 10 s). |
| fuel-2 | drainFuel › never goes below zero | `tests/test_fuel.gd::test_drain_never_goes_below_zero` | Unchanged. |
| fuel-3 | collectFuelCar › refills by the pickup amount, capped at the tank size | `tests/test_fuel.gd::test_a_pickup_refills_10_capped_at_the_tank` | Unchanged: 50 → 60, 95 → 100. |
| fuel-4 | collectFuelCar › pays a flat 1000 points every time, with no chain | `tests/test_fuel.gd::test_a_fuel_car_pays_a_flat_1000_every_time` | Unchanged. The world step pays the points (`Fuel.collect` only refills), so the test collects four fuel cars in a `World`: 1000, 2000, 3000, 4000. |
| fuel-5 | applyCrashFuel › costs 5 or 6 units | `tests/test_fuel.gd::test_a_roadside_crash_costs_5_or_6_units` | Unchanged (seed 7, 50 draws); both costs occur. |
| fuel-6 | applyCrashFuel › never goes below zero | `tests/test_fuel.gd::test_a_crash_never_leaves_the_tank_below_zero` | Unchanged. |
| loop-1 | advance (fixed timestep) › runs one step per 1/60 s of frame time | `tests/test_fixed_step.gd::test_one_step_per_sixtieth_of_frame_time`, `tests/test_fixed_step.gd::test_fixed_fps_60_is_one_step_every_frame` | Unchanged: 2/60 s + 1 ms runs 2 steps and keeps 1 ms. The accumulator is `scripts/app/fixed_step.gd` (docs/GODOT_PLAN.md §3), Phaser's `advance()` operation for operation; under `--fixed-fps 60` every frame is exactly one step (3600 frames checked). |
| loop-2 | advance (fixed timestep) › a frame shorter than one step runs zero steps and carries the time over | `tests/test_fixed_step.gd::test_a_short_frame_runs_no_step_and_carries_its_time` | Unchanged: 1/120 s runs no step and is carried; a second 1/120 s runs one. |
| loop-3 | advance (fixed timestep) › a 240 Hz display still averages exactly one step per 1/60 s | `tests/test_fixed_step.gd::test_240_hz_averages_one_step_per_sixtieth` | Unchanged: 240 frames of 1/240 s run exactly 60 steps. |
| loop-4 | advance (fixed timestep) › a huge frame (tab switch) is clamped and never runs more than the per-frame cap | `tests/test_fixed_step.gd::test_a_huge_frame_is_clamped_to_the_cap`, `tests/test_fixed_step.gd::test_a_frame_of_exactly_the_cap_drops_the_remainder` | Unchanged: a 5 s frame (or an infinite one) runs 5 steps and leaves the accumulator at 0. |
| loop-5 | advance (fixed timestep) › negative or NaN-like inputs do not run steps | `tests/test_fixed_step.gd::test_negative_or_nan_frames_run_no_steps` | Unchanged for negative frames. A NaN frame counts as 0 s, so the accumulator stays a number (in JavaScript it became NaN and stopped the loop for good). |
| loop-6 | latchEdges › keeps a press that has not been consumed yet | `tests/test_input.gd::test_latch_keeps_a_press_until_a_step_consumes_it` | Unchanged; the presses are the pause and confirm bits of the input byte (`PlayerInput.latch`). |
| loop-7 | latchEdges › combines simultaneous presses of different actions | `tests/test_input.gd::test_latch_combines_presses_of_different_actions` | Unchanged; held bits are never latched. |
| state-1 | createGame › starts running on stage 1 with a full tank and the first goal | `tests/test_world.gd::test_a_new_world_starts_running_with_a_full_tank_and_the_first_goal` | Goal 13 500 px (24 000 × K); start x = 291, lane 2 of 6 (Phaser 167, lane 1 of 3). |
| state-2 | pause › Esc/P toggles pause, and nothing moves while paused | `tests/test_world.gd::test_pause_toggles_and_nothing_moves_while_paused` | Unchanged; the pause press is bit 5 of the byte. |
| state-3 | fuel and game over › an empty tank ends the run | `tests/test_world.gd::test_an_empty_tank_ends_the_run` | Unchanged. |
| state-4 | fuel and game over › fuel drains even when the car is stopped | `tests/test_world.gd::test_fuel_drains_while_stopped` | 99 after 60 ticks (Phaser: one step with dt = 1 s). |
| state-5 | fuel and game over › touching a truck ends the run | `tests/test_world.gd::test_touching_a_truck_ends_the_run` | Truck hitbox 18 × 40. |
| state-6 | bumps and roadside crashes › a car bump costs no fuel and no speed, and starts a skid away from the car | `tests/test_world.gd::test_a_bump_costs_no_fuel_or_speed_and_skids_away` | The small yellow car (10 × 20) over the player's right half. Fuel 100 − 1/60, speed 150 + 70/60, slide −50.625, 91 ticks. |
| state-7 | bumps and roadside crashes › the same traffic car cannot bump the player twice, even after invulnerability ends | `tests/test_world.gd::test_the_same_traffic_car_cannot_bump_twice` | `struck_mask` bit 0 is set. |
| state-8 | bumps and roadside crashes › a bump during invulnerability is ignored and does not mark the car as struck | `tests/test_world.gd::test_a_bump_during_invulnerability_is_ignored_and_does_not_strike` | Invulnerability of 60 ticks (Phaser: 1 s). |
| state-9 | bumps and roadside crashes › a roadside crash costs 5–6 fuel, drops speed to 30 %, and starts invulnerability | `tests/test_world.gd::test_a_roadside_crash_costs_5_or_6_fuel_and_70_percent_of_the_speed` | x = 188, slide −50.625. Speed (100 − 25/60) × 0.3 = 29.875 (Phaser checked ≈ 30); 90 ticks of invulnerability left after the crash tick. |
| state-10 | oil and skids › driving onto oil starts a skid exactly once | `tests/test_world.gd::test_oil_starts_a_skid_exactly_once` | Oil 18 × 12. |
| state-11 | fuel pickups › a fuel car refills by 10 and pays a flat 1000 points | `tests/test_world.gd::test_a_fuel_car_refills_10_and_pays_1000` | Unchanged: 60 − 1/60 and 1000 points. |
| state-12 | scoring › passing a car scores 50 points | `tests/test_world.gd::test_passing_a_car_scores_50` | Unchanged; the car starts 0.1 px above the player's rear edge (screen y 316). |
| state-13 | stages › reaching the goal enters stage clear and pays 30 points per whole fuel unit | `tests/test_world.gd::test_reaching_the_goal_clears_the_stage_with_30_per_fuel_unit` | Goal 13 500; bonus floor(40.9 − 1/60) × 30 = 1200. |
| state-14 | stages › confirm at stage clear starts stage 2 with a longer goal, an empty road and a full tank | `tests/test_world.gd::test_confirm_at_stage_clear_starts_stage_2` | Goal 15 750 (28 000 × K); distance and camera back to 0; gap scale 0.9. |
| state-15 | stages › the goal loops after four stages (24 000, 28 000, 32 000, 36 000, then 24 000) | `tests/test_world.gd::test_stage_goals_times_k_loop` | 13 500, 15 750, 18 000, 20 250, then 13 500. |
| state-16 | determinism › the same seed and the same inputs produce the same game | `tests/test_world.gd::test_the_same_seed_and_inputs_give_the_same_game`, `tests/test_world_state.gd::test_restore_midway_same_checksum` | Compared with `checksum()`, the SHA-256 of the whole state. |
| traffic-1 | lanes › laneOf is the inverse of laneX for every lane | `tests/test_traffic.gd::test_lane_of_inverts_lane_x_for_every_lane` | 6 lanes, every hitbox width, both profiles. |
| traffic-2 | stepTraffic relative motion › a car slower than the player drifts down the screen | `tests/test_traffic.gd::test_a_slower_car_drifts_down_the_screen`, `tests/test_traffic.gd::test_n1_traffic_screen_motion_matches_phaser` | One tick at 180 km/h moves it down (speed − 80) × K / 60 px. |
| traffic-3 | stepTraffic relative motion › a car faster than the player drifts up and is removed once it leaves the top | `tests/test_traffic.gd::test_a_faster_car_drifts_up_and_leaves_the_top` | From y = −56.25 (−100 × K) at 200 km/h it rises 1.875 px per tick and is removed after 17 ticks, when its bottom passes −67.5 (−120 × K). |
| traffic-4 | stepTraffic relative motion › oil patches stay still relative to the road only when the player is stopped | `tests/test_traffic.gd::test_oil_moves_on_screen_only_while_the_player_moves` | Oil at y = 168.75 (300 × K). |
| traffic-5 | passing › awards exactly one pass per car, once it is fully behind the player | `tests/test_traffic.gd::test_a_pass_is_paid_once_when_the_car_is_fully_behind` | `passed_mask` bit 0; one tick at 150 km/h. |
| traffic-6 | passing › oil and fuel cars are never counted as passed cars | `tests/test_traffic.gd::test_oil_and_fuel_cars_never_count_as_passed` | Placed in lane 0, so the world step does not also collect the fuel car. |
| traffic-7 | lane changes › a red car changes lane exactly once | `tests/test_traffic.gd::test_a_red_car_changes_lane_exactly_once`, `tests/test_traffic.gd::test_lane_changes_go_to_an_adjacent_lane` | The new lane is adjacent (docs/GODOT_PLAN.md §4); Phaser's any-other-lane rule stays in the `phaser` profile. |
| traffic-8 | spawner is driven by road distance › spawns nothing while the road is not scrolling | `tests/test_traffic.gd::test_nothing_spawns_while_the_road_stands_still` | Unchanged. |
| traffic-9 | spawner is driven by road distance › spawns roughly one car per 350 px of road covered, independent of speed | `tests/test_traffic.gd::test_about_one_car_per_gap_of_road_at_any_speed` | One car per 98.4375 px (350 × K × 3/6), the first after half a gap: exactly 6 cars in 590.625 px (2100 × K × 3/6) at both 100 and 190 km/h (Phaser: 4 to 9 in 2100 px). |
| traffic-10 | spawner is driven by road distance › car gaps never go below the minimum spacing | `tests/test_traffic.gd::test_car_gap_floor` | Floor 56.25 px (200 × K × 3/6), which applies from stage 7 (98.4375 × 0.9⁶ ≈ 52.3) and is checked at stage 50; Phaser 200 in the `phaser` profile. |
| traffic-11 | spawner is driven by road distance › later stages have shorter car gaps (busier road) | `tests/test_traffic.gd::test_later_stages_have_shorter_gaps` | Gap scale 0.81 at stage 3, kept as a running product; oil gaps too. |

## Not ported

- **The 22 render tests** (`tests/render-atlas.test.ts`, `tests/render-draw.test.ts`) tested Phaser's renderer and
  are not ported (docs/GODOT_PLAN.md §6). Three of their intentions are kept in `tests/test_assets.gd`:
  - every frame the view uses exists: `test_frames_used_by_the_view_exist`;
  - every frame lies inside the atlas: `test_atlas_frames_lie_inside_the_atlas`;
  - scales are whole numbers: `test_view_scales_are_whole_numbers`.

  The first and third read `scripts/view/` and `scenes/` (A2's files) as text, and each must find at least one frame
  name or scale there. `tests/test_view.gd` checks the view's layout and rules, and `tools/scalecheck.gd` the pixels on
  screen.
- **Other Phaser checks**, outside the 60: `assets.test.ts` became `tests/test_assets.gd::test_assets_listed`,
  `purity.test.ts` became `tests/test_sim_purity.gd::test_sim_purity`, and `no-audio.test.ts` became
  `tests/test_assets.gd::test_no_audio`. The Playwright end-to-end tests are replaced by A2's smoke test
  (`tools/smoke.gd`).
