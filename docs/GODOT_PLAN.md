# Plan: migración de Fuel Rivals a Godot 4.7.2 y multijugador local

Entradas:
- `docs/DECISIONES_MULTIJUGADOR.md`, con las decisiones del dueño;
- `docs/PLAN.md` §4, con las reglas actuales;
- el código Phaser en el commit `181eba9` de la rama `feat/road-fighter-mvp`. Ese código es la referencia de comportamiento. Se lee con `git show 181eba9:src/game/state.ts`, por ejemplo.

## 0. Hechos verificados en el entorno de desarrollo (14 oct 2026)

| Hecho | Resultado |
|---|---|
| Godot 4.7.2 estable para Linux | Se descarga desde las releases de GitHub y funciona con `--headless --version`. |
| Renderizado y capturas | `xvfb-run` con `--rendering-driver opengl3` (Mesa) renderiza y guarda un PNG de 640×360. El audio cae al driver silencioso. |
| Plantillas de exportación 4.7.2 | Se pueden descargar (1,28 GB). |
| GUT y gdUnit4 | **Bloqueados**: GitHub y codeload devuelven 403. Se usa un **runner de tests propio**, sin dependencias (§6). |
| GodotSteam | Codeberg responde. La **v4.23.1 GDExtension** (plugin para Godot 4.4+) está disponible. También hay plantillas `g472`. |
| Cliente de Steam y mandos físicos | **No disponibles.** Steam Input y la prueba con 6 mandos quedan para un PC real. |

## 1. Alcance y fases

- **Fase A, port.** El juego actual en Godot, con las mismas reglas y los mismos sprites, ya en 16:9 con 6 carriles.
  - La simulación admite N jugadores desde el principio; el modo de un jugador es N = 1.
  - Al final de la fase se borra la versión Phaser.
- **Fase B, multijugador local.** Reglas de `DECISIONES_MULTIJUGADOR.md` §2: pantalla de unión, bots, rondas al mejor de 3, HUD de 6 jugadores y Steam Input.
- **Fuera de alcance:** la exportación web y el online. Sí se prepara la lógica para el online (§3).

## 2. Estructura del repositorio (al terminar)

```
project.godot              640×360, stretch viewport, escala entera, filtro Nearest, audio Dummy
icon.svg                   icono propio (obra del proyecto)
assets/
  sprites.png, sprites.json   atlas actual (GrafxKid, CC0), movido desde public/assets
  font/                       Press Start 2P (OFL-1.1) + OFL.txt
scripts/
  sim/        lógica PURA (RefCounted, sin nodos, Input, OS, Time ni randf/randi)
    config.gd     todas las constantes, con la conversión desde Phaser documentada
    rng.gd        mulberry32 con enteros de 64 bits y máscaras de 32
    car.gd  fuel.gd  traffic.gd  collision.gd
    world.gd      estado de partida con N jugadores; step(inputs) a 60 Hz
    match.gd      rondas, mejor de 3, ganador (fase B)
    bot.gd        IA determinista que produce PlayerInput a partir del estado (fase B)
    player_input.gd   entrada de un jugador en un paso: acelerar, frenar, girar, marcha alta, pausa, confirmar
  input/      lectura de dispositivos → PlayerInput (teclado, mandos de Godot, adaptador de Steam Input)
  view/       atlas, carretera, autos, HUD, paneles
scenes/       boot, title, join (B), game, results (B)
tests/        run_tests.gd (runner propio) + test_*.gd
tools/        smoke.gd (partida sin pantalla con entradas guionizadas), screenshots.gd
addons/godotsteam/   GDExtension (fase B), opcional en tiempo de ejecución
ASSETS.md     licencias de todo lo que se distribuye
```

## 3. Simulación: determinista, con N jugadores y lista para red

- **Paso fijo de 1/60 s.** El estado avanza solo con `world.step(inputs: Array[PlayerInput])`, una entrada por jugador. No lee el reloj ni dispositivos.
- **Coordenadas de mundo.**
  - Cada auto (jugadores y tráfico) tiene `x` en píxeles de pantalla y `y_world`, la distancia recorrida en la carretera.
  - La cámara es `camera_y`. En la fase A es la del único jugador; en la fase B, la del líder.
  - La pantalla se calcula desde `y_world - camera_y`.
  - Esto reemplaza el "movimiento relativo" de Phaser, donde el jugador estaba fijo en pantalla. Con N = 1, el resultado visible debe ser equivalente.
- **Aleatoriedad.** Solo `rng.gd` con semilla. Nunca `randf()`, `randi()` ni `RandomNumberGenerator` sin semilla.
- **Aritmética.** Floats de 64 bits con + − × ÷, comparaciones y `sqrt` como mucho. Nada de `sin`, `cos`, `exp` ni `pow` no entero en la simulación, porque podrían diferir entre plataformas en el futuro online.
- **Serialización.** `world.to_dict()` y `world.checksum()`, para tests de determinismo y para la sincronización futura.
- **Bordes de pulsación.** Pausa y confirmar se guardan hasta que un paso los consume, como `edges.ts`. El acumulador de paso fijo admite como máximo 5 pasos por frame, como `loop.ts`.

## 4. Geometría y conversión desde Phaser

La resolución base es **640×360**: escala ×3 a 1920×1080 y ×2 a 1280×720. En la Steam Deck (1280×800) queda ×2 con barras.

Factor vertical: **K = 360 / 640 = 0,5625**. Se elige para que la carretera tarde **lo mismo en cruzar la pantalla** que en Phaser:
- a 198 km/h, una pantalla cada ~3,2 s;
- velocidad de scroll en px/s = km/h × K.

Toda magnitud de Phaser en píxeles o px/s (huecos de aparición, deslizamiento, giro, objetivo de etapa, metros…) se multiplica por K. Los km/h, el combustible, los puntos y los tiempos **no cambian**.

- **Carretera:** 6 carriles de **44 px** = 264 px, centrada (x de 188 a 452), con barreras de 2 px. Quedan unos 188 px a cada lado para el HUD (en la fase B, 3 paneles de jugador por lado).
- **Sprites a escala entera ×2:**
  - autos de 8×12 → **16×24**;
  - auto pequeño de 6×10 → 12×20;
  - camión de 10×20 → 20×40;
  - mancha de aceite de 10×6 → 20×12;
  - baldosas de 8 px → 16 px.
  Los hitboxes son el cuerpo del sprite sin la sombra de 1 px.
- **Visibilidad.** Con 360 px de alto, el jugador va a ~80 % de la altura de pantalla, para ver suficiente carretera por delante.
- `config.gd` documenta cada valor como "valor Phaser × K" y su origen.

## 5. Presentación y entrada

- **Atlas.** `sprites.json` se lee en tiempo de ejecución y cada frame se convierte en un `AtlasTexture`. El camión y la mancha de aceite se portan desde `pixelArt.ts` como imágenes generadas en código.
- **Calidad de imagen.** Filtro Nearest y escala entera. Fuente Press Start 2P (Godot importa WOFF2) a tamaños múltiplos de 8.
- **Fase A.** Pantallas de título (controles e INICIAR), juego y HUD. Pausa, fin de partida y etapa completada, como ahora. Teclado y mando con el mapeo actual. Pausa al perder el foco.
- **Fase B.**
  - Pantalla de unión: A para unirse, con un color por jugador; selector de bots de 0 a 6 menos humanos; Start para empezar.
  - HUD de 6 jugadores con color, combustible, puntos y rondas ganadas.
  - Pantallas de fin de ronda y de partida.
- **Entrada.**
  - `input/` produce un `PlayerInput` por jugador y por paso.
  - Modo de un jugador: teclado o cualquier mando.
  - Multijugador: solo mandos, cada uno asignado a una plaza.
  - Con Steam disponible (GodotSteam inicializado), los mandos se leen con Steam Input. Si no, con los mandos de Godot.
  - Mando desconectado: un bot toma la plaza hasta que reconecte.
- **Sin audio.** Driver de audio Dummy, ningún `AudioStreamPlayer` y ningún archivo de audio. Un test lo comprueba.

## 6. Pruebas y verificación

- **Runner propio** (`tests/run_tests.gd`, unas 100 líneas): descubre los `test_*.gd`, ejecuta sus métodos `test_*`, informa los fallos y sale con código distinto de 0. Se lanza con `godot --headless --path . -s tests/run_tests.gd`.
- **Port de los tests de Phaser.** Los 124 tests de vitest se portan por intención, no línea a línea: coche, combustible, tráfico, estado, bucle, bordes, determinismo y escena de etapa. A eso se suman tests de N jugadores y, en la fase B, de las reglas multijugador (§7).
- **Test de pureza.** Ningún archivo de `scripts/sim/` usa `Input`, `OS.`, `Time.`, `randf`, `randi`, `RandomNumberGenerator`, `get_tree`, `Node` ni `await`.
- **Test de assets.** Todo archivo de `assets/` aparece en `ASSETS.md`, no hay archivos de audio y los frames del atlas están dentro de la imagen.
- **Prueba de humo.** `tools/smoke.gd` juega N minutos simulados, sin pantalla y con entradas guionizadas, en el modo de un jugador y (fase B) con 6 bots. Falla si aparece `SCRIPT ERROR` o `ERROR` en la salida.
- **Capturas.** `xvfb-run` con `opengl3`. El jefe del equipo las revisa: título, juego, pausa y fin; en la fase B, también unión, 6 autos, HUD y fin de ronda.
- **Exportación.** Plantillas 4.7.2: exportar Linux y Windows. El ejecutable de Linux debe arrancar sin pantalla unos segundos sin errores.

## 7. Reglas multijugador a implementar (fase B)

Fuente: `DECISIONES_MULTIJUGADOR.md` §2 y §3. Valores iniciales, todos en `config.gd`:

- **Cámara.** `camera_y` sigue al jugador vivo más adelantado, sea humano o bot.
- **Borde inferior.** Un auto que bajaría de la parte baja de la pantalla queda sujeto a ella, avanza con la cámara y pierde **4 de combustible por segundo** mientras la toca.
- **Contacto.** Los jugadores se atraviesan entre sí y chocan con el tráfico como ahora. El tráfico azul persigue el carril del jugador vivo más cercano.
- **Puntos.** +50 por adelantar, +1000 por auto arcoíris y **+10 por cada 100 px de mundo** recorridos.
- **Tráfico.** Sin etapas. Cada 20 s los huecos de aparición bajan un 10 %, con un mínimo de 200 px × K. Las manchas de aceite y los autos arcoíris también escalan.
- **Eliminación.** Combustible a 0 o contacto con un camión.
  - Un bot eliminado desaparece y la ronda sigue.
  - Un humano eliminado termina la ronda.
- **Ganador de la ronda.** El humano vivo con más puntos; si empatan, el de más distancia.
  - Con un solo humano: gana si tenía más puntos que cada bot vivo.
  - Los bots nunca ganan.
- **Partida.** Al mejor de 3. Cada ronda empieza con todos los autos en parrilla y el tanque lleno.
- **Pausa.** Cualquier humano con Start.
- **Desconexión.** Un bot toma la plaza hasta que vuelva el mando.
- **Colores.** 6 colores de jugador; el tráfico usa otros, sin solaparse.

## 8. Criterios de aceptación

**Fase A**
1. `godot --headless -s tests/run_tests.gd` pasa todos los tests, incluidos pureza y assets.
2. La prueba de humo de un jugador, con 3 minutos simulados, termina sin errores.
3. Las capturas muestran título, juego con 6 carriles en 16:9, pausa y fin de partida, con sprites nítidos y la fuente cargada.
4. Las reglas de un jugador se comportan como en Phaser, escaladas por K: velocidades, marchas, combustible, derrape, empujón, choque con el borde, camión, puntos y etapas.
5. La exportación de Linux y Windows funciona, y el binario de Linux arranca.
6. Se borra la versión Phaser y el README describe Godot.

**Fase B**
1. Los tests cubren cada regla de §7, incluida la de 1 humano contra bots, el mejor de 3 y que los bots no ganan.
2. Determinismo: la misma semilla con las mismas entradas para 6 jugadores durante 2 minutos da el mismo `checksum()`.
3. La prueba de humo con 6 bots durante 5 minutos simulados termina sin errores, y las rondas terminan cuando corresponde.
4. Las capturas muestran la pantalla de unión, 6 autos con colores distintos, el HUD de 6 y el fin de ronda.
5. El adaptador de Steam Input existe y el juego funciona sin Steam, con un aviso en el registro. Queda documentado lo no verificado.

## 9. Equipo

- **Revisión:** 3 agentes Opus 5.5 con esfuerzo máximo, en paralelo:
  - fidelidad de reglas y diseño multijugador;
  - arquitectura Godot, determinismo y online, Steam Input;
  - pruebas, alcance y riesgos.
  El jefe incorpora los cambios aceptados en este plan.
- **Fase A (secuencial):**
  - A1: proyecto base, simulación, runner y tests.
  - A2: escenas, render, entrada, HUD y capturas.
  - A3: QA, exportación, borrado de Phaser y README.
- **Fase B (secuencial):**
  - B1: reglas multijugador, bots y tests.
  - B2: unión, HUD de 6, flujo de rondas, entrada por mando y adaptador de Steam Input.
  - B3: QA, capturas y exportación.
- El jefe verifica y hace commit entre fases.

## 10. Riesgos

- **Sensación de juego.** El port en coordenadas de mundo puede cambiar sutilmente la sensación. Se mitiga portando los tests por intención y comparando capturas en movimiento.
- **Más de 4 mandos de Xbox.** En Windows fuera de Steam, Godot (SDL3) lee esos mandos por XInput, que admite 4. Está documentado: dentro de Steam, Steam Input lo resuelve.
- **Steam Input con el App ID 480.** Spacewar no tiene un manifiesto de acciones propio. Se entrega `steam_input_manifest.vdf` con instrucciones de prueba local. No es verificable aquí.
- **Steam Deck.** 1280×800 deja barras a escala ×2. Es aceptable.
- **Descargas bloqueadas.** Por eso el runner de tests es propio.
