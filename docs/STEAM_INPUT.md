# Steam Input

How Fuel Rivals reads gamepads through Steam (phase B4 of `docs/GODOT_PLAN.md`; the owner's decision is in
`docs/DECISIONES_MULTIJUGADOR.md` §1: Steam Input with GodotSteam, so that the 5th and 6th gamepads work, of any make,
also with Remote Play Together; App ID 480 during development).

**Nothing here has run against a real Steam client.** The development machine has none, no physical gamepad and no
Windows. What was checked here, and what was not, is at the end ("What is not verified").

## In short

- Under Steam, every controller Steam sees (up to 16, of any make, Remote Play Together guests' too) is read through
  the game's **action manifest**, `steam_input/steam_input_manifest.vdf`, and becomes a pad of the game. The join
  screen, the seats, the menus and single player treat it exactly as a gamepad read by Godot.
- Without Steam (no client running, a build without GodotSteam, or `--no-steam`), the game reads Godot's own gamepads,
  as before B4. It prints **one warning** at start and nothing else.
- Once Steam reports a controller of its own, Godot's gamepads are ignored **for the rest of the session**: the same
  controller would otherwise arrive twice, through Steam and through the system.

## How it works

### Files

| File | What it is |
|---|---|
| `addons/godotsteam/` | GodotSteam 4.23.1, the GDExtension that talks to Steam: Linux and Windows x86_64 libraries and Valve's `libsteam_api.so` / `steam_api64.dll`. Source, SHA-256 and licences in `ASSETS.md`. |
| `scripts/input/steam_input.gd` | The adapter: starts Steam Input, reads the controllers every frame, turns them into virtual pads. |
| `scripts/app/app.gd` | Gives the adapter's pad events and connections to the inputs (B4 part: `use_steam()`, `start_steam()`, `poll_steam()`, `guid_of()`, the filters in `_input()` and `_on_joy_connection_changed()`). |
| `steam_input/steam_input_manifest.vdf` | The action manifest: the action sets, the actions, their names in English and Spanish, and one configuration file per controller type. |
| `steam_input/controller_*.vdf` | The default layouts (Steam calls them configurations) of eight controller types. |
| `tests/test_steam_input.gd`, `tests/test_steam_manifest.gd`, `tests/fake_steam.gd` | The tests and a fake GodotSteam singleton. |

### Start (once, when the game starts)

`App._ready()` calls `start_steam()`, which calls `SteamInput.start_engine()`:

1. With `--no-steam` on the command line (before or after `--`, so Steam's launch options work too): nothing at all,
   no warning.
2. GodotSteam is looked up by name only, `Engine.has_singleton("Steam")` and `Engine.get_singleton("Steam")`, and called
   with `call()`. `steam_input.gd` never names GodotSteam's class, so the game compiles and runs without the addon.
   Without the singleton: one warning, `Steam Input is off: GodotSteam (addons/godotsteam/) is not loaded.`
3. `call("steamInitEx", 480, true)`. The `true` makes GodotSteam run Steam's callbacks every frame by itself. Any
   status other than 0 gives one warning, `Steam Input is off: steamInitEx(480) returned status 1 (...)`, and the
   singleton is never called again (GodotSteam's input functions print an `ERROR:` line when Steam is not running:
   the tests check that none is called).
4. With status 0: `inputInit(false)`, then `setInputActionManifestFilePath(<manifest>)`, then the signals
   `input_device_connected`, `input_device_disconnected` and `input_configuration_loaded` are connected, then
   `enableDeviceCallbacks()`, which makes Steam report every controller already connected.

The manifest path is `<folder of the executable>/steam_input/steam_input_manifest.vdf` in an exported game, and
`<project folder>/steam_input/steam_input_manifest.vdf` when the editor runs the game (the editor's executable lives
elsewhere). Steam reads it from disk: the export does not put it in the game's pack, where Steam could not read it
anyway.

Only the game itself starts Steam: tests boot many apps with `App.start()`, which never calls `start_steam()`, and test
the adapter with a fake singleton.

### Handles, and one source per session

- When Steam has loaded a controller's configuration (`input_configuration_loaded`), the adapter reads the handles of
  the manifest's action sets and actions (`getActionSetHandle()`, `getDigitalActionHandle()`; Steam answers 0 until a
  configuration has loaded) and takes the controller.
- The first controller taken makes Steam the session's source of pads (`took_over`). The app then lets Godot's own pads
  go (a seated one leaves its seat on the join screen, or hands it to its bot in a race) and drops their events and
  their comings and goings from then on.
- A controller whose layout is a legacy gamepad template (`uses_steam_input_api` false in the callback) is not taken:
  Steam then emulates a pad for it, which Godot reads. If only such controllers exist, Godot's pads stay the source.
- `input_device_connected` and `input_device_disconnected` follow controllers coming and going. Steam's handle "will
  consistently identify a controller, even if it is disconnected and re-connected" (ISteamInput docs), so the
  controller keeps its virtual device and its GUID (`steam:<handle>`), and seats.gd gives it its seat back.

### Every frame

`App._process()` calls `poll_steam()` before the screen runs. For each controller the adapter calls
`activateActionSet()` with the **racing** set on the screens where people drive (the single-player game and the versus
race) and the **menus** set elsewhere (title, join screen), then `getDigitalActionData()` for that set's actions. Each
action holds down a button of a **virtual pad** on device 1000 (the session's first controller), 1001, ...; each button
that goes down or up becomes an `InputEventJoypadButton`, which the app parses into Godot's `Input` and hands to
`_input()`, as a pad driver's event. So `Pads.held_of(device)` reads the held buttons, and `seats.gd`, `nav.gd` and
`local_input.gd` see a Steam controller as one more pad. A controller that goes away lets go of its buttons first.

| Action set | Action | Virtual pad button | What the game does with it (the gamepad mapping of `pads.gd` and `nav.gd`) |
|---|---|---|---|
| racing | `accelerate` | D-pad up | throttle |
| racing | `brake` | D-pad down | brake |
| racing | `steer_left`, `steer_right` | D-pad left, right | steer |
| racing | `high_gear` | A | high gear and throttle |
| racing | `confirm` | A | confirm: next round, rematch, retry; a pad without a seat takes an orphan seat |
| racing | `pause` | Start | pause and resume (pause and confirm presses) |
| racing | `back` | Back (Select) | quit a paused race to the title; leave the results for the join screen |
| menus | `menu_up`, `menu_down`, `menu_left`, `menu_right` | D-pad | move; left and right take away or add a bot |
| menus | `confirm` | A | join, choose |
| menus | `back` | B | leave your seat |
| menus | `start` | Start | start the race (and confirm on the title) |
| menus | `quit` | Back (Select) | back to the title |

The price of going through a virtual pad: an action counts as its button. `confirm` bound apart from `high_gear` also
gives high gear while held, as a pad's A does; in a race B's "back to the join screen" is the `back` action (View),
since the B button is `accelerate` there.

### Default layouts

The manifest lists a configuration for `controller_xbox360`, `controller_xboxone`, `controller_ps4`, `controller_ps5`,
`controller_switch_pro`, `controller_generic`, `controller_steamcontroller_gordon` (the 2015 Steam Controller) and
`controller_neptune` (the Steam Deck). Each binds the same layout as a gamepad without Steam (README, Controls):

| Input | Racing | Menus |
|---|---|---|
| A (south) | `high_gear` and `confirm` | `confirm` |
| B (east) | `accelerate` | `back` |
| D-pad, and the left stick as a D-pad (the left trackpad on the 2015 Steam Controller) | up `accelerate`, down `brake`, left `steer_left`, right `steer_right` | `menu_up`, `menu_down`, `menu_left`, `menu_right` |
| Start (Menu, Options, +) | `pause` | `start` |
| Back (View, Share, -) | `back` | `quit` |

Steam lets each player change the layout in its configurator. **These eight files were written by hand**, from the
format of the configurations Steam exports and Valve's published example, and have never been loaded by Steam. If
Steam shows them empty or refuses them, make the layout in Steam's configurator and export it over them (see below).
`tests/test_steam_manifest.gd` checks that the manifest's sets and actions are the adapter's, that every action of
both sets is bound in every file, and that the layout is the table above.

## Builds with and without Steam (for B3)

| Preset | GodotSteam | Writes to | Notes |
|---|---|---|---|
| `Linux`, `Windows Desktop` (A3's) | left out: `exclude_filter` adds `addons/godotsteam/*` | `build/linux/`, `build/windows/` | A build without Steam: the game runs with one warning and Godot's pads. Neither the `.gdextension` nor `.godot/extension_list.cfg` is in the pack (checked: Godot 4.7.2 leaves an excluded extension out of the list too). `tools/export_check.sh` checks `Linux`. |
| `Linux Steam`, `Windows Steam` | in the pack | `build/linux_steam/`, `build/windows_steam/` | The Steam builds. Every other setting is the plain preset's (a test checks it). |

What a Steam build needs next to the executable:

- **The libraries.** Godot's export copies them by itself: `libgodotsteam.linux.template_release.x86_64.so` and
  `libsteam_api.so` on Linux (checked when the plan was written, plan §0), and on Windows
  `libgodotsteam.windows.template_release.x86_64.dll` and `steam_api64.dll` (not checked: no Windows export was made).
  A debug export takes the `template_debug` library.
- **`steam_input/`**, with the manifest and the eight `controller_*.vdf` files. Godot does not export them (they are
  not resources, and Steam cannot read files inside the pack): the export script must copy the folder next to the
  executable, for example `cp -r steam_input build/linux_steam/`.
- **`steam_appid.txt` only for development**: a text file with `480` next to the executable, for a build started outside
  Steam. Never ship it. (GodotSteam's `steamInitEx(480)` also sets the `SteamAppId` and `SteamGameId` environment
  variables of the process, seen here, so a run from the editor needs no file.)
- For the game's own App ID, later: replace `APP_ID` in `scripts/input/steam_input.gd`, and in Steamworks, Steam Input
  settings, choose "Custom Configuration (Bundled with game)" with the path `steam_input/steam_input_manifest.vdf`.
  Steam then reads the manifest from the depot when the game is launched from Steam.

A pack of `Linux Steam` can also be checked without templates, as was done here: export it, then run it with
`--main-pack` from a folder that holds `addons/godotsteam/linux64/libgodotsteam.linux.template_debug.x86_64.so` and
`libsteam_api.so` (the editor's binary finds them there; an exported binary finds them next to itself). Here: one
warning (status 1), `selftest: ok`, no `ERROR:` line.

## Testing locally with App ID 480 (on a PC with Steam)

1. Install Steam and log in. App ID 480 is Spacewar, Valve's test app: everyone may use it.
2. In Steam's settings, Controller: turn Steam Input on for the controller types you have (Xbox, PlayStation, Switch
   Pro, generic). A type left off is read by Godot instead, which also works, but then all controllers should be left
   off: as soon as Steam reports one controller, Godot's pads are ignored for the session.
3. Run the game while Steam runs:
   - from the editor (F5), or `godot --path .`: the manifest is the project's `steam_input/`;
   - or an exported Steam build: put `steam_input/` (and, for this test only, `steam_appid.txt` with `480`) next to
     the executable and start it yourself.

   With the game's own App ID it can also be launched from Steam; with 480 there is no depot of your own, so the game
   is started by hand and Steam is told about the manifest by `setInputActionManifestFilePath()` ("This override will
   be remembered for the rest of the Steam session", Steamworks docs).
4. What to expect: no "Steam Input is off" warning. With `--verbose`, lines starting with `Steam Input:` report the
   start, each configuration loaded with the handles read (any handle 0 means Steam does not know that name: check the
   manifest), the takeover, and each controller with its pad number and GUID.
5. Steam's tools for the configuration: in Big Picture, Settings, System, turn on Developer mode, then in Developer
   turn on "Steam Input Layout Dev Mode", which shows errors in the manifest. To replace a hand-written default layout,
   edit the layout in the game's controller configuration, export it ("Export layout"), dump it with
   `steam://dumpcontrollerconfig?appid=480` (on Linux `xdg-open steam://dumpcontrollerconfig?appid=480` writes it to
   `/tmp`), and copy it over the matching `steam_input/controller_*.vdf`. Then run `tools/test.sh` and update
   `tests/test_steam_manifest.gd` if the layout changed on purpose.
6. A quick check of the whole path: on the title choose VERSUS with the D-pad and A, join with A on each controller,
   change the bots with left and right, start with Start, drive, pull a controller's cable or turn it off (its car's
   bot takes over at once), plug it back (it gets its seat back by itself).

## Remote Play Together

- Steam streams the game to the guests and sends their controllers to the host's game "as though they were sitting at
  the same computer" (Steamworks, Remote Play). Through Steam Input they are controllers like the local ones, with
  handles: each one joins the join screen with A and takes a seat. Nothing in the game is specific to guests.
- Only the host needs the game. Its Steam must have Steam Input on for the guests' controller types.
- Valve announces "up to four players, or more with fast connections". **Six players were not tried.** Check six
  before writing it on the store page.
- Guests on a phone or tablet would need a touch layout (`controller_mobile_touch`), which the manifest does not list:
  Steam would offer no layout of the game's for them.
- Steam's Remote Play Together API (invites, the guest's session) is not used: guests are invited from the Steam
  overlay.

## What is not verified here

- **Real Steam Input.** No Steam client: `steamInitEx(480)` returned status 1 (`Failed to load module
  '/root/.steam/sdk64/steamclient.so'`), so everything after it ran only against `tests/fake_steam.gd`: the call
  order, the callbacks, the handles, `getDigitalActionData()`'s results, and the takeover.
- **The manifest and the eight configurations in Steam.** Never loaded by Steam; the configurations are hand-written.
- **Six physical gamepads**, or any physical gamepad, through Steam or not.
- **Remote Play Together**, with six or with any number of players.
- **Windows**: the `.dll` files were never loaded, and no Windows build was made.
- The Steam Deck and the 2015 Steam Controller (their layouts are among the hand-written ones).
- GodotSteam's `getConnectedControllers()` is not called (it prints to the standard output with no newline, which
  could hide an `ERROR:` line from the checks): controllers come from the callbacks only.
- Whether Steam emulates a gamepad, seen by Godot, for a controller that the game reads through the API. The
  one-source rule covers it either way, but only a real PC shows which.

## Known limits

- One source per session: with Steam Input on for some controller types and off for others, the ones Godot reads are
  ignored as soon as Steam reports one controller.
- Steam's handles are 64-bit numbers; GDScript keeps them as signed integers, which GodotSteam turns back into the same
  number when they are passed back.
- A fresh import of the project with the addon crashed the Godot 4.7.2 editor once every time here, after the import had
  finished (SIGSEGV in a worker thread, exit 134, no `ERROR:` line); the second import works. `tools/test.sh`,
  `tools/run_tool.sh` and `tools/export_check.sh` already retry a failed import once.
