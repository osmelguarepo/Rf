# Controles táctiles

Los botones en pantalla (`scripts/input/touch.gd`, dibujados por `scripts/view/touch_view.gd`) **pulsan las teclas del teclado**.
Un toque en un botón envía la tecla pulsada, soltar el dedo envía la tecla soltada, así que el juego individual, la pantalla de
unirse, el versus y los menús funcionan igual que con teclado y ninguna pantalla sabe de dedos. `App._touch_key()` convierte cada
(tecla, pulsada) en un `InputEventKey`; `touch.gd` recuerda cada evento propio para no tomarlo por un teclado real.

## Cuándo se muestran
- **Dispositivo**: empiezan activos si el navegador dice que el puntero principal es táctil (`matchMedia('(pointer: coarse)')`,
  `WebBridge.coarse_pointer()`) o la build es móvil (`OS.has_feature("mobile")`). Un portátil con pantalla táctil o una Steam Deck
  empiezan sin ellos.
- **Un toque real** los activa; **una tecla o un botón de mando real** los desactiva (los eventos que crean los propios botones no
  cuentan).
- **Pantalla** (`App.touch_mode()`): carrera (`Game`, `Versus`) → botones de conducir; menús (`Title`, `Join`, `Ranking`, `Online`,
  `Login`, `Queue`) → cruceta y OK/ESC; el título web que espera el primer toque → ninguno.
- **Escala**: con los controles activos la ventana se estira por fracciones (`CONTENT_SCALE_STRETCH_FRACTIONAL`) en vez de por
  números enteros, para llenar la pantalla de un móvil; sin ellos vuelve a enteros.
- **Vertical**: se dibuja "TURN YOUR DEVICE TO PLAY". Al pasar a pantalla completa en la web se intenta bloquear la orientación en
  horizontal (`WebBridge.lock_landscape()`; solo funciona en Android).

## Botones
| Modo | Botones (tecla) |
|---|---|
| Carrera | ◀ ▶ (flechas), GAS (↑), BRK (↓), NOS (X: nitro y gas), II (P: pausa), OK (Enter), ESC |
| Menú | cruceta (flechas), OK (Enter), ESC, DEL (Retroceso), pantalla completa (F11), SND (M), − y + (volumen) |

Varios dedos a la vez; un dedo que se desliza de un botón a otro cambia de botón; un botón se suelta cuando lo sueltan todos los
dedos que lo tenían. Un toque cuenta hasta 10 px fuera del borde (`SLOP`) y gana el botón más cercano.

## Textos
En el título y en la pantalla de unirse los textos nombran los botones ("TAP TO START", "TAP OK TO JOIN"). Las pantallas ONLINE,
RANKING, LOGIN y QUEUE conservan sus textos de teclado; se manejan con la cruceta y OK/ESC.

## Sin verificar
Solo se comprobó con pruebas automáticas y capturas de escritorio. Falta probarlo en un móvil o tableta reales: multitoque,
tamaño de los botones, pantalla completa y bloqueo de orientación en Safari/Chrome, rendimiento, y los textos de las pantallas
ONLINE/RANKING en táctil.
