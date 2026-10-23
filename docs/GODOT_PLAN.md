# Plan: migración de Fuel Rivals a Godot 4.7.2 y multijugador local (v2, tras la revisión)

**Entradas:**
- `docs/DECISIONES_MULTIJUGADOR.md`: decisiones del dueño, que son requisitos.
- `docs/PLAN.md` §4: reglas actuales.
- Código Phaser de referencia en el commit **`0a0841f`** de la rama `feat/road-fighter-mvp`, también con la etiqueta local `phaser-reference`. Se lee con `git show 0a0841f:src/game/state.ts`, o con `git worktree add /tmp/phaser-ref 0a0841f`.
- **Revisión.** La v1 de este plan la revisaron 3 agentes (reglas, arquitectura y pruebas). El §12 lista qué se aceptó y qué no.

## 0. Hechos verificados en el entorno de desarrollo (14 oct 2026)

| Hecho | Resultado |
|---|---|
| Godot 4.7.2 Linux | Se descarga y funciona: `--headless --version` → `4.7.2.stable.official.ed1daf0bf`. Binario en `/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64`. |
| Capturas | `xvfb-run -a -s "-screen 0 1920x1080x24"` con `--rendering-driver opengl3` renderiza; `get_viewport().get_texture().get_image()` guarda PNG. |
| Escala entera | En ventana de 1920×1080, escala ×3. En 1280×800, ×2 con una franja de 40 px arriba y abajo. Comprobado por un revisor. |
| GUT / gdUnit4 | **Bloqueados** (403 en GitHub y codeload). Se usa un **runner propio** (§6). |
| GodotSteam 4.23.1 | El asset de Codeberg `…plugin-4.4.zip.tar.xz` (18 MB, es un tar.xz) funciona. Exportando a Linux copia `libgodotsteam…so` y `libsteam_api.so` junto al binario. Sin Steam, `steamInitEx(480)` devuelve status 1. |
| Plantillas de exportación | El `.tpz` pesa 1,28 GB. Con peticiones HTTP de rango basta extraer `version.txt`, `linux_release.x86_64` y `windows_release_x86_64{,_console}.exe` (unos 68 MB). |
| Push de etiquetas git | **Rechazado por el proxy.** Solo se suben commits de la rama. |
| No disponible aquí | Cliente de Steam, mandos físicos y Windows real. |

## 1. Alcance, fases y equipo

- **Fase A, port del juego de un jugador.**
  - **A1.** Etiqueta de referencia, trazas doradas, borrado de Phaser, proyecto base, simulación, runner y tests.
  - **A2.** Escenas, render, entrada, HUD, prueba de humo y capturas.
  - **A3.** QA, exportación de prueba con `--export-pack`, README y CI.
- **Fase B, multijugador local.**
  - **B1.** Reglas multijugador, partida al mejor de 3, bots y tests.
  - **B2.** Pantalla de unión, asientos por mando, HUD de 6 y pantallas de ronda y partida.
  - **B3.** QA, escenarios con 6 autos, exportaciones reales de Linux y Windows.
  - **B4.** Adaptador de Steam Input, manifiesto y `docs/STEAM_INPUT.md`.
- **Cada agente** es Opus 5.5 con esfuerzo máximo. Hay un verificador adversarial después de cada uno. El jefe verifica y hace commit **después de cada agente**.
- **Fuera de alcance:** exportación web y online. Sí se deja la simulación preparada (§3).

### Propiedad de archivos

| Agente | Es dueño de |
|---|---|
| A1 | `project.godot`, `scripts/sim/**`, `tests/**`, `tools/test.sh`, `assets/**`, `.gitignore`, borrado de Phaser |
| A2 | `scenes/**`, `scripts/{view,input,app}/**` (incluido `scripts/view/view_config.gd`), `tools/smoke.gd`, `tools/screenshots.gd`, `tools/scalecheck.gd` |
| A3 | `README.md`, `export_presets.cfg`, `.github/workflows/ci.yml` |
| B1 | `scripts/sim/{world,match,bot,config}.gd` y sus tests |
| B2 | escenas de unión y resultados, HUD multijugador, `scripts/input/seats.gd` |
| B3 | escenarios de humo, exportaciones, capturas de la fase B |
| B4 | `scripts/input/steam_input.gd`, `steam_input/`, `addons/godotsteam/`, `docs/STEAM_INPUT.md` |

Editar un archivo de otro agente exige añadir un test y una nota en `docs/HANDOFF.md`.

### Entrega entre agentes

Cada agente añade su sección a **`docs/HANDOFF.md`** con:
- los archivos tocados;
- los comandos de verificación y la última línea esperada de cada uno;
- la API pública (campos de `World` que lee la vista, `PlayerInput`, eventos, nombres de configuración);
- los huecos conocidos.

## 2. Estructura del repositorio (al terminar)

```
project.godot  icon.svg  export_presets.cfg  .gitignore (.godot/ build/ shots/)
assets/   sprites.png  sprites.json  font/ (woff2 + OFL.txt + .import)  source/.gdignore
scripts/
  sim/    PURO: config.gd rng.gd car.gd fuel.gd traffic.gd collision.gd world.gd match.gd bot.gd player_input.gd
  input/  keyboard.gd pads.gd seats.gd (B) steam_input.gd (B4)
  view/   atlas.gd road.gd cars.gd hud.gd view_config.gd
  app/    app.gd (paso fijo, pausa por foco, cambio de escena)
scenes/   boot title game join(B) results(B)
tests/    run_tests.gd  test_case.gd  test_*.gd  PARITY.md  golden/
tools/    test.sh  smoke.gd  screenshots.gd  scalecheck.gd  slice-sheet.py  fetch_assets.py  gen_golden/ (vitest, solo A1)
steam_input/  steam_input_manifest.vdf (B4)
docs/     PLAN.md  DECISIONES_MULTIJUGADOR.md  GODOT_PLAN.md  HANDOFF.md  STEAM_INPUT.md  screenshots/
ASSETS.md README.md
```

### `project.godot` (claves comprobadas)

```
[application] config/name="Fuel Rivals"
[audio]      driver/driver="Dummy"
[display]    window/size/viewport_width=640, window/size/viewport_height=360,
             window/size/window_width_override=1920, window/size/window_height_override=1080,
             window/stretch/mode="viewport", window/stretch/scale_mode="integer"
[rendering]  renderer/rendering_method="gl_compatibility", renderer/rendering_method.mobile="gl_compatibility",
             textures/canvas_textures/default_texture_filter=0, 2d/snap/snap_2d_transforms_to_pixel=true
[debug]      gdscript/warnings/integer_division=2, gdscript/warnings/untyped_declaration=2
```

- La fuente se importa con `antialiasing=0`, `hinting=0` y `subpixel_positioning=0`, y se hace commit del `.import`.
- El atlas se carga con `load()`. Los frames, con `JSON.parse_string(FileAccess.get_file_as_string(...))`; los números llegan como float.
- Nunca se usa `Image.load_from_file` sobre `res://`.

## 3. Simulación pura, determinista, de N jugadores, lista para red

- **Organización del código.**
  - Clases `RefCounted` tipadas con `clone()`, y funciones `static` que modifican el estado en el sitio.
  - Las dependencias se cargan con `const X := preload("res://scripts/sim/x.gd")`. No se usa `class_name` en `scripts/sim/` ni en `tests/`: en un clon recién hecho, `-s` no las resuelve.
  - Prohibido `static var`, autoloads y nodos en la simulación.
- **Paso.** `World.step(inputs: PackedByteArray)`, con un byte por plaza, avanza un tick (1/60 s) y suma `tick += 1`. Formato del byte:
  - bit 0: acelerar;
  - bit 1: frenar;
  - bits 2–3: giro + 1;
  - bit 4: marcha alta;
  - bit 5: pausa;
  - bit 6: confirmar;
  - `0xFF`: la plaza la conduce un bot. `bot.gd` corre dentro de `step()`, así las tomas de control por bot se reproducen exactamente.
- **Fuera de la simulación.** El acumulador de paso fijo (máximo 5 pasos por frame), la pausa por foco y la lectura de dispositivos van en `scripts/app` y `scripts/input`.
- **Coordenadas de mundo.**
  - Cada auto tiene `x` (px de pantalla) e `y_world` (distancia en px de mundo).
  - La pantalla se calcula con `screen_y = anchor + (camera_y - y_world)`. Para el auto que define la cámara, `screen_y == anchor`.
  - La cámara es **monótona**: `camera_y = max(camera_y_prev, leader_y)`.
- **Anclas.**
  - Un jugador: el borde superior del jugador está en **y = 292** (520 × K).
  - Multijugador: el líder está en **y = 192**, lo que deja 136 px detrás para el resto.
- **Aritmética permitida.**
  - Campos solo `float` e `int`.
  - Operaciones: + − × ÷, comparaciones, `sqrt`, `absf`, `minf`, `maxf`, `clampf`, `floorf`, `floori`, `signf`.
  - Prohibido `Vector2`, `Rect2` y `PackedFloat32Array` (usan float de 32 bits), y también `**`, `pow`, `lerp`, `sin`, `cos`, `tan`, `exp`, `log`, `hash`, `randomize`, `randf` y `randi`.
  - El escalado de huecos se guarda como un producto (`scale *= 0.9`).
  - Las duraciones son **ticks enteros**.
  - No se escriben literales con 10 o más decimales.
- **RNG.** mulberry32 exacto, verificado contra el TypeScript en 1 000 000 de salidas:
  ```gdscript
  static func _imul(a: int, b: int) -> int:
      return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF
  func next() -> float:
      state = (state + 0x6D2B79F5) & 0xFFFFFFFF
      var t := _imul(state ^ (state >> 15), state | 1)
      t ^= (t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF
      return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0
  ```
  - `int(lo, hi) = lo + floori(next() * (hi - lo + 1))`.
  - Cada bot tiene su propio RNG, sembrado desde la semilla de la partida, para que el número de bots no altere el tráfico.
- **Estado completo.**
  - `to_array()` / `from_array()` cubren todos los campos: RNG, huecos, `next_id`, temporizadores, cámara, máscaras.
  - `checksum() = var_to_bytes(to_array()).hex_encode().sha256_text()`.
  - Nunca se hace hash de un Dictionary ni de JSON, y no se guardan floats como texto.
- **Por plaza.** `passed`, `struck` y `consumed` se guardan como **máscaras de bits por plaza**.

## 4. Geometría y conversión desde Phaser

- **Base.** 640×360, con escala entera.
- **Factor K = 360/640 = 0,5625.** Toda magnitud de Phaser en px o px/s se multiplica por K. Los km/h, el combustible, los puntos y los tiempos **no cambian**.
- **Carretera.**
  - 6 carriles de **44 px** = 264 px, en x de 188 a 452, con barreras de 2 px.
  - El jugador de un jugador empieza en el **carril 2** (centro en x ≈ 298).
- **Sprites ×2.** Autos de 16×24, auto pequeño de 12×20, camión de 20×40, mancha de 20×12, baldosas de 16 px.
- **Hitboxes reducidos 1 px por lado:**
  - jugador y autos: **14×24**;
  - auto pequeño: **10×20**;
  - camión: **18×40**;
  - mancha: **18×12**.
- **Densidad.** Seis carriles reparten el tráfico entre el doble de carriles, así que los huecos se ajustan para mantener la densidad por carril de Phaser:
  - hueco de autos: **350 × K × 3/6 = 98,4375 px**, mínimo **56,25 px**;
  - hueco de manchas: **1125 ± 281,25 px**;
  - hueco de autos arcoíris: **4500 ± 1125 px**, sin cambio.
- **Cambios de carril.** Solo a un carril **adyacente**.
- **Literales.** Los números sueltos de `traffic.ts` (100, 4, 20, −120, 200) pasan a `config.gd` multiplicados por K. Cada constante documenta "valor Phaser × K".
- **Perfil "phaser".** `config.gd` lo expone para los tests dorados: K = 1, 3 carriles de 80 px, vista de 360×640 e hitboxes de Phaser.

## 5. Presentación y entrada

- **Atlas.** Un `AtlasTexture` por frame. El camión y la mancha se portan desde `pixelArt.ts`.
- **Colores de jugador.** 6 recoloreados de `car_red`, incluidos sus frames de 45°, que no coinciden con los colores del tráfico (amarillo, salmón, azul, camión). El auto arcoíris es la excepción declarada.
- **Fase A.**
  - Pantallas: boot, título (controles e INICIAR) y juego (HUD, pausa, fin de partida, etapa completada).
  - Teclado y cualquier mando, con el mapeo actual. El mapa de entrada se construye en código.
  - Pausa al perder el foco.
  - Opción `--selftest`.
- **Mandos (fase B).**
  - Se escucha `Input.joy_connection_changed`.
  - Un mando se une con un `InputEventJoypadButton` de A desde un `event.device` sin asignar.
  - Se sondea `Input.is_joy_button_pressed(id, …)` y `get_joy_axis(id, …)` con umbral 0,5. No se usan las acciones de InputMap, que mezclan dispositivos.
  - No se depende de `Input.get_connected_joypads()`, que está vacío sin pantalla.
  - **Desconexión:** el byte de la plaza pasa a `0xFF`. Al reconectar, el mismo GUID de mando recupera su plaza; si no, el siguiente mando sin asignar que pulse A recupera la plaza huérfana más baja.
  - No se limita a 4: RAWINPUT podría pasar del límite fuera de Steam.
- **Steam (B4).**
  - `steam_input.gd` nunca nombra `Steam` directamente. Usa `Engine.has_singleton("Steam")`, `Engine.get_singleton()` y `call("steamInitEx", 480, true)`.
  - Si el status no es 0: un solo `push_warning` y ninguna llamada más. `--no-steam` lo desactiva.
  - Orden de llamadas: `inputInit(false)`, luego `setInputActionManifestFilePath(<dir_exe>/steam_input/steam_input_manifest.vdf)`, luego `enableDeviceCallbacks()`. Los handles se leen con `input_configuration_loaded`.
  - **Una sola fuente por sesión:** Steam si hay handles; si no, los mandos de Godot.
  - Las compilaciones sin Steam usan `exclude_filter` con `addons/godotsteam/*`.
- **Audio.** Retro y libre, solo en `scripts/app/audio.gd` (ver `docs/AUDIO.md`); la simulación no suena.

## 6. Pruebas y verificación

- **Punto de entrada único: `tools/test.sh`.**
  1. `godot --headless --path . --import || godot --headless --path . --import` (el primer import puede fallar con GodotSteam).
  2. `timeout 600 godot --headless --path . -s res://tests/run_tests.gd -- "$@"`.
  3. Falla si la salida contiene `^(SCRIPT ERROR|ERROR):`. Los WARNING no cuentan.
- **Runner (`tests/run_tests.gd`, `extends SceneTree`) y `tests/test_case.gd`.**
  - Descubre `test_*.gd` y sus métodos `test_*`, ordenados. Admite `before_each`/`after_each` y `--only=`.
  - Asserts al estilo GUT: `assert_eq` con tipos estrictos, `assert_almost_eq`, `assert_true/false`, cada uno con `file:line`.
  - Un `ErrorCounter extends Logger`, registrado con `OS.add_logger()`, hace fallar el test si se registra cualquier error o si el test no hizo ningún assert.
  - Un archivo falla si `not script.can_instantiate()`.
  - Llama a `quit(70)` al principio y a `quit(1 si hay fallos o 0 tests, 0 si no)` al final.
- **Trazas doradas (A1, antes de borrar Phaser).**
  - `tools/gen_golden/` contiene un archivo vitest que ejecuta las reglas TypeScript.
  - Escribe `tests/golden/phaser_golden.json` con los doubles en hex little-endian y el RNG en u32.
  - Tests obligatorios:
    - `test_rng_matches_phaser_u32`;
    - `test_golden_speed_trace_bit_exact` (2000 pasos);
    - `test_golden_no_traffic_60s`: velocidad y combustible exactos al bit; distancia × K con error menor de 1e-9;
    - `test_golden_world_profile_phaser`: `world.gd` con el perfil "phaser", la misma semilla y 3 minutos de entradas guionizadas, igual que la traza de TypeScript.
- **`tests/PARITY.md`.** Relaciona cada uno de los 60 `it()` de reglas de Phaser (coche 20, combustible 6, bucle 7, estado 16, tráfico 11) con un test de GDScript, o con "descartado: motivo", y vuelve a calcular los valores esperados. Los 22 tests de render de Phaser no se portan. Se conservan tres intenciones de render:
  - todo frame usado existe;
  - los frames están dentro del atlas;
  - las escalas son enteras.
- **Otros tests obligatorios de la fase A:**
  - `test_steer_rate_is_phaser_times_k`;
  - `test_skid_recovers_in_15_steps`;
  - el tiempo de deslizamiento hasta el borde, por carril;
  - `test_stage_goals_times_k_loop`;
  - `test_car_gap_floor`;
  - `test_two_players_same_inputs_identical`;
  - `test_players_never_collide`;
  - `test_n1_traffic_screen_motion_matches_phaser`;
  - `test_restore_midway_same_checksum`: restaurar en el tick 600, avanzar 600 más y obtener el mismo checksum;
  - `test_sim_purity`, sobre la lista prohibida del §3;
  - `test_assets_listed`: ignora los `.import`;
  - `test_project_settings`;
  - `test_all_scripts_compile`.
- **Prueba de humo (`tools/smoke.gd`).**
  - Se lanza con `timeout 300 godot --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- --scenario=1p --frames=10800`.
  - Envía eventos reales con `Input.parse_input_event()` según una línea de tiempo: Enter, X mantenida, Esc en los frames 600 y 660, giro que cambia cada 120 frames, y Enter tras cada fin de partida.
  - Comprueba que se llega al juego, que la pausa y la reanudación funcionan, que hay al menos un fin de partida con reintento, y que perder el foco pausa (`NOTIFICATION_APPLICATION_FOCUS_OUT`).
  - Termina con `quit(code)` y aplica el mismo filtro de errores que `test.sh`.
- **Capturas (`tools/screenshots.gd`).**
  - Se lanzan con `xvfb-run` y `--rendering-driver opengl3 --fixed-fps 60`, y se guardan en `docs/screenshots/`, fuera del proyecto importado (§2: `.gdignore`).
  - El fin de partida se fuerza poniendo el combustible a 0,1.
  - `tools/scalecheck.gd` comprueba que la pantalla sea el viewport escalado ×2 o ×3, con 0 píxeles distintos, a 1280×800, 1920×1080 y 1366×768.
- **Exportación.**
  - A3: `--export-pack` (no necesita plantillas), y luego `godot --headless --main-pack build/fuel_rivals.pck -- --selftest`, que debe salir con 0 y sin líneas ERROR.
  - B3: plantillas reales (solo los 4 archivos, comprobando el SHA-512 de la release). Se exportan los presets `"Linux"` y `"Windows Desktop"` con `embed_pck=true` y `exclude_filter="tests/*, tools/*, docs/*"`, creando antes `build/linux` y `build/windows`. El binario de Linux debe arrancar con `--headless --quit-after 300`, y el de Windows ser un PE32+.
- **CI (A3).** `.github/workflows/ci.yml` descarga Godot 4.7.2 y ejecuta `tools/test.sh` y la prueba de humo.

## 7. Reglas multijugador (fase B)

Fuente: `DECISIONES_MULTIJUGADOR.md`. Todos los valores van en `config.gd`.

- **Cámara.** Sigue al **auto vivo más adelantado**, sea humano o bot. Es monótona y el ancla está en y = 192.
- **Borde inferior.**
  - El borde inferior de un auto queda en **y ≤ 352**.
  - Si queda sujeto, su velocidad pasa a ser `max(speed, Δcamera_y / (K·dt))`, para que siga pudiendo girar.
  - "Toca el borde" significa que quedó sujeto en este paso o que su borde inferior está a ≥ 351,5.
  - Mientras toca el borde pierde **2 de combustible por segundo, además** del gasto normal de 1/s. Es un valor inicial a ajustar.
- **Contacto.**
  - Los jugadores se atraviesan entre sí.
  - El tráfico rebota a cada jugador una vez, según la máscara por plaza.
  - Una mancha se retira cuando todos los vivos la activaron.
  - Si varios tocan un auto arcoíris en el mismo paso, se lo queda el centro más cercano y, después, la plaza más baja.
  - El tráfico azul persigue al jugador vivo con menor distancia vertical dentro de 112,5 px; si empatan, la plaza más baja.
  - Los camiones no hacen nada durante la invulnerabilidad.
- **Puntos.**
  - +50 por adelantar, una vez por plaza.
  - +1000 por auto arcoíris.
  - Distancia: **+10 por cada 100 px de mundo**, calculado como `speed × K × dt`.
  - Mientras un auto toca el borde inferior, no suma puntos por adelantar ni por distancia. **Confirmado por el dueño (14 oct).**
- **Tráfico.**
  - Supervivencia sin etapas.
  - Cada **1200 ticks** (20 s), los huecos de autos y manchas × 0,9, con un mínimo de **40 px** (se alcanza hacia los 180 s).
  - Los huecos de autos arcoíris son **fijos**. Si se redujeran, un jugador que recoge todos no se quedaría nunca sin combustible y la ronda no terminaría.
- **Eliminación.**
  - Combustible a 0 o un camión.
  - Todas las eliminaciones de un mismo tick se aplican a la vez.
  - Un bot eliminado desaparece.
  - Un humano eliminado termina la ronda al final de ese tick. Esto incluye una plaza humana conducida por un bot tras desconectarse, que sigue contando como humana.
- **Ganador de la ronda.**
  - Candidatos: los humanos vivos después del tick; si no queda ninguno, los humanos eliminados en ese tick.
  - Orden: más puntos, luego más distancia, luego más combustible. Si siguen iguales, **nadie gana** la ronda.
  - **Un solo humano:** gana si supera en puntos, y luego en distancia, a cada bot vivo.
  - **Los bots nunca ganan.**
- **Partida.**
  - Gana el **primero en llegar a 2 rondas ganadas**.
  - Con 3 o más humanos puede quedar 1-1-1: tras 5 rondas decide quién tiene más rondas ganadas y, después, más puntos totales.
  - Con un solo humano, la partida termina con 2 victorias o 2 derrotas.
  - **Cada ronda reinicia** puntos, distancia, combustible, tráfico, huecos, el reloj de dificultad y los bots. El RNG continúa.
- **Bots.**
  - Siempre aceleran.
  - Pasan a marcha alta desde 160 km/h si hay 150 px libres por delante.
  - Se van al carril adyacente más despejado, corrigen los derrapes y persiguen autos arcoíris a un carril de distancia.
  - Reaccionan con un retraso de 12 ticks.
- **Pausa.** Cualquier humano con Start.
- **Colores.** Los de los jugadores y los del tráfico nunca se solapan.

**Confirmado por el dueño (14 oct):**
- mientras se toca el borde inferior no se suman puntos por adelantar ni por distancia;
- el multijugador exige **al menos 2 autos**: con 1 humano, el selector obliga a añadir al menos 1 bot;
- con un solo humano, si todos los bots quedan eliminados, **la ronda termina al instante y gana el humano**.

## 8. Criterios de aceptación

**A1.**
- `tools/test.sh` termina con 0 y muestra `N passed, 0 failed`, con N > 0.
- Incluye los tests dorados, la paridad, la pureza, los assets, la configuración del proyecto y la compilación de todos los scripts.
- Phaser está borrado, `assets/` movido y `PARITY.md` completo.

**A2.**
- La prueba de humo `1p` (10 800 frames) termina con 0 y sin líneas ERROR.
- Hay capturas de título, juego (6 carriles), pausa y fin de partida.
- `scalecheck` da 0 píxeles distintos en las 3 resoluciones.

**A3.**
- `--export-pack` + `--selftest` terminan con 0.
- El README describe Godot.
- Existe la CI.
- `tools/test.sh` y la prueba de humo pasan desde cero, tras borrar `.godot/`.

**B1.**
- Pasan los tests:
  - `test_camera_follows_leading_alive_car`, `test_camera_monotonic`;
  - `test_bottom_edge_clamps_and_drains_fuel`;
  - `test_players_pass_through`, `test_blue_targets_nearest_alive_player`;
  - `test_pass_50_once_per_player`, `test_rainbow_first_toucher_only`, `test_distance_10_per_100px`;
  - `test_gaps_shrink_10pct_per_1200_ticks_floor`, `test_rainbow_gaps_fixed`;
  - `test_truck_and_empty_tank_eliminate`, `test_simultaneous_eliminations`;
  - `test_bot_elimination_round_continues`, `test_human_elimination_ends_round`;
  - `test_winner_points_distance_fuel_then_none`, `test_single_human_needs_more_than_each_alive_bot`, `test_bots_never_win`;
  - `test_first_to_two_and_cap_five`, `test_round_reset`;
  - `test_any_human_pauses`, `test_disconnect_seat_stays_human`.
- 6 plazas durante 7200 ticks dan el mismo checksum en 2 ejecuciones e igual a `tests/golden/versus_checksum.txt`.

**B2.**
- Las capturas muestran la unión, 6 autos de colores distintos que no coinciden con ningún color del tráfico (comprobado por muestreo de píxeles), el HUD de 6 y el fin de ronda.
- `test_colour_sets_disjoint` pasa.

**B3.**
- Escenarios de humo con 18 000 frames cada uno:
  - (a) 1 humano guionizado + 5 bots;
  - (b) 6 plazas humanas conducidas por `bot.gd`, con 20 semillas.
- Las rondas terminan en el tick de una eliminación humana, ningún bot gana y la partida termina con 2 victorias.
- La mediana de la primera eliminación está entre 45 y 180 s, con al menos un cambio de líder por minuto.
- Las desconexiones se simulan con `Input.joy_connection_changed.emit(d, false)`.
- Las exportaciones reales de Linux y Windows funcionan.

**B4.**
- El juego funciona sin el addon y sin Steam: un solo aviso y ningún ERROR.
- Con el addon y sin el cliente de Steam: status 1, un solo aviso y se usan los mandos de Godot.
- Existen el manifiesto y `docs/STEAM_INPUT.md`, con la prueba local usando el App ID 480 y la lista de lo no verificado (Steam Input real, 6 mandos físicos, Remote Play Together con 6, Windows).

## 9. Fuera de alcance

Exportación web, online, Konami Man, controles táctiles, mandos de más de 6, y las 30 ideas de power-ups (van después).

## 10. Riesgos

- **Sensación de juego.** Mitigada con trazas doradas y el perfil "phaser".
- **Más de 4 mandos de Xbox fuera de Steam en Windows:** depende de RAWINPUT y no está verificado aquí.
- **Steam Input, 6 mandos físicos y Windows:** solo verificables en un PC real (B4 lo documenta).
- **Nombre "Fuel Rivals":** comprobar que esté libre como marca antes de publicar.
- **Pérdida de contexto entre agentes:** se mitiga con `docs/HANDOFF.md`.

## 11. Cambios respecto a la v1

- La configuración del proyecto, el runner, `test.sh`, el formato de entrada por bytes, la aritmética permitida, las anclas de cámara, la densidad de tráfico, las máscaras por plaza, las reglas de eliminación y desempate, la política de bots, las trazas doradas, la propiedad de archivos y la entrega entre agentes son nuevos o se rehicieron tras la revisión.
- El borrado de Phaser pasa de A3 al inicio de A1, porque `node_modules` provocaba 23 errores de importación en Godot.

## 12. Revisión de la v1: aceptado y no aceptado

- **Aceptado.** Todo lo listado arriba, procedente de:
  - **reglas:** 1–4, 6–11;
  - **arquitectura:** 1–8;
  - **pruebas:** 1–12, con matices.
- **Resuelto por el dueño (14 oct).** Reglas 5 y 7: el borde inferior no suma puntos, mínimo 2 autos, y la ronda termina con victoria del humano si no quedan bots vivos.
- **Matices.**
  - La etiqueta `phaser-reference` es solo local: el proxy rechaza el push de etiquetas. La referencia remota es el commit `0a0841f`.
  - Checksum: SHA-256 de `var_to_bytes`, que propuso el revisor de arquitectura, en lugar de MD5.
  - Las plantillas reales se descargan una sola vez, en B3.
