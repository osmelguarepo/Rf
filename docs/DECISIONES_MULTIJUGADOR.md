# Fuel Rivals: decisiones para el multijugador y la migración a Godot

Este documento recoge las respuestas del dueño del proyecto del 14 de octubre de 2026, más las decisiones por defecto que tomé donde no hacía falta preguntar. Es la entrada para el plan de implementación.

## 1. Plataforma y tecnología

| Tema | Decisión |
|---|---|
| Nombre | **Fuel Rivals**. Sustituye a "Road Fighter", que es una marca de Konami. Falta comprobar que el nombre esté libre antes de publicar. |
| Motor | **Godot 4.7.2** (estable). Comprobado: se descarga y funciona sin interfaz en el entorno de desarrollo. |
| Lenguaje | **GDScript**, el único que exporta a web en Godot 4. |
| Versión Phaser | **Se borra** del repositorio. Queda en el historial de git, en la rama `feat/road-fighter-mvp`, commit `181eba9`. |
| Repositorio | Este mismo. El proyecto Godot sustituye al de Phaser. |
| Destinos | **Steam (escritorio) primero. Web más adelante.** |
| Mandos 5 y 6 en escritorio | **Steam Input con GodotSteam**: hasta 16 mandos de cualquier marca, también con Remote Play Together. Fuera de Steam se aplica el límite normal del sistema. |
| App ID de Steam | **480 (Spacewar)** durante el desarrollo. Se sustituye por el real cuando exista. |
| Online | Más adelante, para navegador y Steam, con **servidor propio** (por ejemplo WebSockets). Desde ahora la lógica se prepara para ello (sección 5). |

## 2. Reglas del multijugador

| Tema | Decisión |
|---|---|
| Tipo | Local, una sola pantalla. |
| Jugadores | Hasta **6** autos. |
| Controles | **Solo mandos** en multijugador. |
| Unirse | Cada mando pulsa **A** en la pantalla de unión y aparece con su color. Cualquier jugador unido pulsa **Start** para empezar. |
| Bots (local) | Rellenan plazas. **El número se elige antes de empezar**, de 0 hasta completar 6. **Una sola dificultad.** |
| Bots (online) | No hay bots: solo humanos. |
| Pantalla | **Horizontal 16:9**, carretera vertical de **6 carriles**. El modo de un jugador usa el mismo formato. |
| Cámara | **Sigue al líder.** |
| Rezagado | El borde inferior **no elimina: empuja** al auto hacia delante y le **quita combustible** mientras lo toca. |
| Contacto entre jugadores | **Se atraviesan.** Los jugadores solo chocan con el tráfico. |
| Identificación | **Solo el color del vehículo.** El tráfico también tiene colores, pero los dos grupos de colores no se repiten. |
| Combustible | **Individual**, como ahora. Los autos arcoíris son para el primero que los toca. Llegar a 0 elimina. |
| Camión | **Derrota inmediata.** |
| Progresión | **Supervivencia sin fin**: el tráfico se vuelve más denso con el tiempo. No hay meta. |
| Puntos | **Adelantar (+50), autos arcoíris (+1000) y distancia recorrida.** |
| Partida | **Al mejor de 3 rondas.** |
| Fin de ronda | **Solo la eliminación de un humano termina la ronda.** Un bot eliminado desaparece y la ronda sigue. |
| Ganador de ronda | **El humano vivo con más puntos.** Los bots **no pueden ganar**. |
| 1 humano contra bots | Cuando el humano pierde, gana la ronda si tenía **más puntos que cada bot vivo**. Se mantiene el mejor de 3. |
| Mando desconectado | **Un bot toma su auto** sin parar la ronda. Al reconectar, el jugador lo recupera. |
| Modo un jugador | **Se mantiene** como modo aparte, con teclado o mando. |

## 3. Decisiones por defecto (no preguntadas; se pueden cambiar)

- **Resolución base:** 640×360 píxeles, escalada a múltiplos enteros (×3 = 1920×1080) para que el pixel art se vea nítido.
- **Colores:** 6 colores de jugador reservados. El tráfico usa un conjunto de colores distinto, sin repetir ninguno.
- **Pausa:** cualquier jugador humano pausa con Start.
- **Empate de puntos:** gana el que recorrió más distancia.
- **Valores a ajustar al probar:** combustible que pierde el rezagado al tocar el borde inferior, puntos por distancia, y ritmo de aumento del tráfico.
- **Orden de trabajo:** primero se porta el juego actual de un jugador a Godot, con reglas, sprites y tests, ya en 16:9 con 6 carriles. Después se añade el multijugador.
- **Assets:** se reutilizan los mismos sprites (GrafxKid, CC0) y la fuente Press Start 2P (OFL-1.1), con su registro de licencias.
- **Tests:** un framework de tests de GDScript que funcione sin interfaz, como GUT o gdUnit4, para poder ejecutarlo en el entorno de desarrollo y en CI.

## 4. Lo que encontró la investigación (14 de octubre de 2026)

- El límite de 4 mandos que medimos es una constante del código de Chromium (`kItemsLengthCap = 4`). Chromium la subió a 8 en Chrome/Chromium 155 (commit 9fea28ff, 9 de septiembre de 2026). Chromium 141 y Electron 44 o anteriores siguen limitados a 4.
- Cambiar de motor no evita el límite en la web: toda exportación web lee los mandos con `navigator.getGamepads()`. Por eso la web se hace más adelante, y en navegador las plazas sin mando las ocupan bots.
- En Windows, los motores de escritorio leen los mandos de Xbox con XInput, que admite 4. Steam Input (hasta 16 mandos) evita ese límite cuando el juego se lanza desde Steam.
- GodotSteam (licencia MIT) se mudó a Codeberg. La versión 4.23 es compatible con Godot 4.7 e incluye Steam Input. Esto último solo se verificó en parte.
- Remote Play Together se anuncia para "hasta cuatro jugadores, o más con conexiones rápidas". Hay que probar 6 jugadores antes de prometerlo en la página de la tienda.
- Todo lo anterior se basa en código fuente y documentación. **Nadie lo ha probado con 6 mandos físicos.**

## 5. Preparación para el online

- La lógica del juego (reglas, tráfico, combustible, puntos) va en scripts puros, sin nodos de física de Godot. Avanza en pasos fijos de 1/60 s a partir de las entradas de cada jugador en cada paso.
- Usa un generador de números aleatorios con semilla propia, para que el mismo historial de entradas produzca la misma partida.
- La lectura de mandos (Steam Input o el sistema de entrada de Godot) se separa de la lógica mediante una entrada por jugador y por paso. Así el online podrá enviar esas entradas por red.

## 6. No verificable en el entorno de desarrollo

- Steam Input y GodotSteam necesitan el cliente de Steam y mandos reales. Se programan y se dejan cubiertos con tests de la lógica, pero la prueba real es en un PC con Steam.
- Jugar con 6 mandos físicos.
