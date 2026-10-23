# Especificación: partida de 3 carreras, puntos y ranking por divisiones

Estado: **implementada** (carreras, puntos de carrera, ranking, divisiones, nombres y pantalla RANKING en LOCAL; el almacén online queda como interfaz, ver §10). Sustituye las reglas de partida de `scripts/sim/match.gd` ("el primero en ganar 2 rondas") en el modo LOCAL. Los números marcados como *propuesta* están por afinar jugando.

## 1. Objetivo

Los jugadores compiten por tener más puntos. Cada carrera reparte puntos a todas las posiciones, y al terminar la partida cada jugador humano gana o pierde puntos de ranking según su posición final, como los trofeos de Clash Royale. Los puntos suben y bajan, y el ranking se agrupa en divisiones.

- LOCAL: ranking solo durante la sesión (se pierde al cerrar el juego).
- ONLINE: ranking guardado en una base de datos. Ahora solo se construye la interfaz de almacenamiento (ver §9).

## 2. Dos puntuaciones

| Puntuación | Para qué sirve | Dónde vive |
|---|---|---|
| **Puntos de carrera** | Deciden quién gana la partida | Solo dentro de la partida |
| **Puntos de ranking** | Número a largo plazo y división | Sesión (LOCAL) / base de datos (ONLINE) |

## 3. La partida

- Una partida son **3 carreras** (constante `MATCH_RACES = 3`). Reemplaza `MATCH_WINS`, `MATCH_ROUNDS_MAX` y `MATCH_LONE_LOSSES` para el modo carrera.
- Entre carreras se mantiene la pantalla de resultados con confirmación (como hoy, `MATCH_CONFIRM_TICKS`).
- Más adelante cada carrera podrá ser un mapa distinto. Hoy es la misma pista de ~13.500 px.

## 4. Fin de carrera y posiciones

Hoy la carrera termina cuando el primer coche cruza la meta. Cambia así:

1. Cuando el primer coche cruza la meta empieza una **cuenta atrás de 10 s** (`RACE_FINISH_GRACE_TICKS`, *propuesta*).
2. Cada coche que cruza antes del final de la cuenta atrás queda clasificado por **orden de cruce**.
3. Al terminar la cuenta atrás, los que no cruzaron se clasifican por **distancia recorrida** (mayor primero), por detrás de todos los que cruzaron.
4. Si todos cruzan antes, la carrera termina en ese momento.
5. Empate exacto de cruce en el mismo tick: gana quien ha pasado más lejos la línea (regla ya existente); si sigue el empate, el asiento de menor número.
6. Un humano desconectado: su coche pasa a un bot, que sigue compitiendo en esas carreras (el jugador ya está penalizado, ver §6).

Los coches que ya cruzaron la meta dejan de recibir input y se apartan de la pista (la vista decide cómo; el sim solo los marca como terminados).

## 5. Puntos de carrera

Por posición, con 6 coches: **10, 7, 5, 3, 2, 1**. Con menos de 6 coches se usan las primeras posiciones de la lista (con 4 coches: 10, 7, 5, 3).

Ganador de la partida: el que suma más puntos de carrera tras las 3 carreras.

Desempate: **quien quedó mejor en la última carrera**. Siempre decide (posiciones únicas), así que no hay partidas sin ganador.

Los bots ganan puntos de carrera y pueden ganar la partida a efectos de la pantalla de resultados, pero no tienen ranking (§7).

## 6. Puntos de ranking

Se aplican **una vez, al terminar la partida**, a cada humano según su posición final entre todos los coches (bots incluidos). Tabla fija por tamaño del campo, simétrica: la mitad superior gana, la inferior pierde, y en tamaños impares la posición central queda en 0. *Propuesta*:

| Coches | 1º | 2º | 3º | 4º | 5º | 6º |
|---|---|---|---|---|---|---|
| 2 | +20 | -20 | | | | |
| 3 | +25 | 0 | -25 | | | |
| 4 | +30 | +10 | -10 | -30 | | |
| 5 | +30 | +15 | 0 | -15 | -30 | |
| 6 | +30 | +18 | +8 | -8 | -18 | -30 |

Reglas:

- Los puntos de ranking **nunca bajan de 0**. Se puede bajar de división, pero no a negativo.
- Todos empiezan con 0 puntos.
- **Desconexión o abandono** en mitad de la partida: el jugador cuenta como **último** en la tabla de ranking, pase lo que pase con sus puntos de carrera. Sus puntos de carrera ya no deciden nada para él; los demás se clasifican entre sí con el bot en su asiento.
- **Los bots no tienen ranking** ni entrada en la clasificación. Ocupan posiciones, así que ganarles vale algo.
- Una partida con un solo humano contra bots mueve el ranking igual que cualquier otra. Riesgo conocido: se puede "farmear" contra bots; se puede revisar más adelante (por ejemplo escalando por número de humanos).

## 7. Divisiones

Umbrales fijos, la división es simplemente dónde cae el total. *Propuesta*:

| División | Desde | Hasta |
|---|---|---|
| Bronce | 0 | 299 |
| Plata | 300 | 699 |
| Oro | 700 | 1199 |
| Platino | 1200 | 1799 |
| Diamante | 1800 | sin límite |

No hay subdivisiones, ni protección tras subir: al bajar de un umbral se desciende de división al instante. Se muestra una insignia junto al nombre. Cada cambio de división enseña un aviso de ascenso o descenso.

## 8. Identidad y clasificación

### LOCAL

- Un jugador es un **asiento** (teclado, mando A, mando B...) con un **nombre editable** de 3 a 8 caracteres, por defecto `P1`, `P2`...
- El nombre se edita en la pantalla de unirse. El ranking sigue al asiento mientras el juego esté abierto.
- Si cambia el mando asignado a un asiento, la historia se queda con el asiento.
- Todo se pierde al cerrar el juego.

### ONLINE (futuro)

- El jugador es su **cuenta de Steam** (GodotSteam ya está en el proyecto): el Steam ID es el identificador y el nombre de Steam es el nombre mostrado.
- Sin Steam en ejecución no hay ranking online.

## 9. Pantallas

1. **Pantalla de fin de partida** (sustituye a "YOU WIN / BOT WINS THE MATCH"): posiciones finales con puntos de carrera de cada carrera y total; para cada humano el cambio de ranking (`+18` / `-8`), el total nuevo, la insignia de división y el aviso de ascenso o descenso.
2. **Pantalla de clasificación** (desde el título): lista de jugadores de la sesión (LOCAL) ordenada por puntos de ranking, con insignia de división. En ONLINE será la lista de los mejores jugadores.
3. Entre carreras se mantiene la pantalla de resultados actual, ampliada con los puntos de carrera de esa carrera y la clasificación provisional de la partida.

No entra en esta versión: mostrar el ranking en la tarjeta de la pantalla de unirse.

## 10. Diseño técnico

### Simulación (pura, determinista)

- `Config`: `match_races = 3`, `race_points = [10, 7, 5, 3, 2, 1]`, `race_finish_grace_ticks = 600`. Perfil `Config.game()` los activa; `standard()` queda intacto para los tests de Phaser y golden.
- `World`: lleva la lista de **llegadas** (slot y tick) y un estado `FINISHING` (cuenta atrás) entre `RUNNING` y `ROUND_OVER`. Un coche que ha llegado queda marcado `finished` y ya no entra en el cálculo de la meta. Cambia FORMAT del mundo.
- `Match`: para modo carrera guarda `race_points[slot]`, `race_results` (posiciones por carrera) y decide al cumplir `match_races`. `FORMAT` sube. `wins` y `totals` existentes se mantienen para el modo antiguo.
- Nueva clase pura `Ranking` (sin Godot nodes): `delta(field_size, position) -> int`, `division(points) -> int`, `apply(points, delta) -> int` con el suelo en 0, y los nombres de las divisiones. Tablas y umbrales como constantes.

### Almacenamiento

- Interfaz `RankingStore` con `get(player_id) -> Record`, `apply(player_id, delta)`, `top(n)`. 
- `MemoryRankingStore` (LOCAL, sesión), usado ahora.
- `SteamRankingStore` / base de datos: **no se implementa ahora**; la interfaz debe bastar para sustituirlo sin cambiar el juego. El resultado de la partida lo escribe la autoridad (servidor) en ONLINE, nunca el cliente.

### App

- `Seats` o un nuevo objeto de sesión guarda nombre por asiento; `App` posee el `RankingStore` de la sesión.
- Al terminar la partida `Versus` calcula posiciones, llama a `Ranking`, escribe en el store y pasa el resultado a `versus_hud` para la pantalla de fin.
- El dashboard `--admin` (F1) expone `match_races` y la cuenta atrás de fin de carrera; las tablas de puntos no.

## 11. Pruebas previstas

- Ranking: tablas simétricas y suma cero para tamaños pares, suelo en 0, umbrales de división en los bordes (299/300, 699/700...), ascenso y descenso.
- Fin de carrera: cuenta atrás, clasificación por orden de cruce y por distancia, todos cruzan antes del final, empate en el mismo tick.
- Partida: tres carreras, puntos 10-7-5-3-2-1, desempate por la última carrera, abandono = último, un bot puede ganar la partida pero no recibe ranking.
- Determinismo: checksum de partida y golden `versus_checksum.txt` regenerado; test de Phaser sin cambios.
- Pantallas: fin de partida con cambio de ranking y aviso de división; clasificación ordenada.
- `tools/smoke.gd` y `tools/controls_check.gd` actualizados para la partida de 3 carreras.

## 12. Fuera de alcance / abierto

- Base de datos y servicio ONLINE (hosting, anti-trampas, temporadas).
- Cambio de mapa por carrera.
- Reducir el farmeo contra bots, y reinicios de temporada.
- Tablas y umbrales definitivos: salen de partidas de prueba.

## 13. Notas de implementación

Lo que se decidió al construirlo y no estaba en la entrevista:

- Un coche que cruza la meta deja de estar vivo (`alive = 0`, `finish_place` = su puesto) y desaparece de la pista; el panel
  de su asiento muestra FINISHED y su puesto. `World.standings()` da el orden.
- `Match` marca como abandonado (`abandoned_mask`) a un asiento humano al que se le da el byte 0xFF (el que usa un asiento
  cuyo mando se fue), así la desconexión es una entrada más y la partida se reproduce igual. Salir a otra pantalla con la
  partida sin terminar (pausa, Back o Esc) marca a todas las personas como abandonadas y aplica ese resultado al ranking.
- El nombre se edita con las órdenes de menú de la pantalla de unión (Arriba/Abajo cambian la letra, Derecha añade, Izquierda
  quita), para que valga con mando y con teclado. Las insignias de los paneles siguen siendo P1 a P6 (son del color del
  asiento y miden 32 px); el nombre se ve en las líneas de ranking y en la clasificación.
- `RankingStore` es la clase en memoria; la interfaz para ONLINE se definirá cuando haya partidas online, con las mismas
  llamadas (`record`, `apply`, `top`).
- La fórmula de puntos de carrera usa la lista `Config.RACE_POINTS` y el panel F1 expone `match_races` y la cuenta atrás.
