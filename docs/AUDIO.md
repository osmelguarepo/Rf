# Audio

Fuel Rivals has retro sound, all of it free: CC0 files from Kenney's Digital Audio pack, and effects and music the project makes itself with `tools/gen_audio.gd` (square and triangle waves, noise and sweeps, released as CC0). Every file and its licence is listed in `ASSETS.md`.

## What plays, and when

`scripts/app/audio.gd` is the only code that makes sound. The simulation does not know it exists, so a silent run (headless, the tests) plays the same game. In a race, `Versus` calls `race_step()` after every step of the match and `drive()` every frame. Bots are silent; only the people's cars make sound.

| Sound | When | File |
|---|---|---|
| Start beeps | each red light of the gantry comes on | `beep_light.wav` |
| Green | the lights go out | `beep_go.wav` |
| Engine loop | while the race runs; pitch from 0.6 (idle) to 3.0 (400 km/h) follows the fastest person's car | `engine.wav` |
| Nitro | a whoosh when nitro starts, a loop while it burns | `nitro_start.wav`, `nitro_loop.wav` |
| Crash | roadside or truck | `crash.wav` |
| Bump | a light touch with traffic | `bump.wav` |
| Skid | oil | `skid.wav` |
| Pickup | a fuel car | `kenney/powerUp2.ogg` |
| Nitro ready | the tank is full again | `kenney/powerUp5.ogg` |
| Finish | a person's car crosses the line | `finish.wav` |
| Overtake | a person's car gains a place | `kenney/phaserUp5.ogg` |
| Race end | a race is over | `kenney/threeTone1.ogg` |
| Match win / lose | a person wins the match / ends it last | `kenney/threeTone2.ogg`, `kenney/lowThreeTone.ogg` |
| Division up / down | a person's division changed, a second after the match ends | `kenney/zapThreeToneUp.ogg`, `kenney/zapThreeToneDown.ogg` |
| Pause / resume | pause and resume | `pause.wav` |
| Menu | tick on a move, blip on confirm, blip on back (title, join screen, ranking) | `menu_move.wav`, `menu_confirm.wav`, `menu_back.wav` |
| Crowd | a person's car crosses the line (with the finish fanfare) | `cheer.wav` |
| Car pass | a person's car passes a traffic car | `car_pass.wav` |
| Low nitro | a person burns nitro with the tank under 20 %: a beep at once, then every half second | `nitro_low.wav` |
| Music | a menu song on the title, join and ranking screens; a race song from the green light until the race ends | `music_menu.wav`, `music_race.wav` |

## Volume

On every screen: `-` (or numpad minus) lowers the volume, `+` (`=` or numpad plus) raises it, in tenths, and `M` mutes and unmutes. A tick plays at the new level and "VOL 7/10" or "MUTE" shows in the top right corner for a moment. Zero is silent. The master bus is what changes, so effects and music move together. The level is kept in `user://settings.cfg` (only the game writes it, never the tests) and the default is 7.

## Making the generated sounds

```
godot --headless --path . -s res://tools/gen_audio.gd
```

The noise is a seeded generator, so a run writes the same files. The files are committed, so nobody needs to run it.

## Tests

`tests/test_audio.gd` checks that every sound loads, that each game event asks for its sound, that the engine pitch follows speed and stays in range, and that the loops are seamless. `tests/test_assets.gd` keeps audio files to `assets/audio/`, as WAV or Ogg, each with a CC0 or own-work row in `ASSETS.md`.
