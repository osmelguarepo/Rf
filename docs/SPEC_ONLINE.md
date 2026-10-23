# Especificación: juego online, plataformas y despliegue (web y Steam)

Estado: **aprobada tras revisión adversarial (§16, que prevalece sobre las secciones anteriores); implementados M0, M1 y M2 (ver §16.7)**. Sale de la entrevista del 23-10-2026. Los valores marcados como *propuesta* están por medir o afinar (ver §14). Completa a `SPEC_RANKING.md`: allí se define *cómo se puntúa* una partida y aquí *cómo se juega en red, cómo se identifica a la gente y cómo se publica el juego*.

## 1. Objetivo y decisiones tomadas

| Tema | Decisión |
|---|---|
| Plataformas | Escritorio (Steam, Windows primero) y **web** (navegador), con el juego completo en ambas |
| Jugadores | Todos juntos, cualquier plataforma (crossplay) |
| Modo online | **Emparejamiento rápido** (matchmaking) con el ranking por divisiones de `SPEC_RANKING.md`. Sin salas privadas en esta versión |
| Autoridad | **Servidor dedicado propio**; los clientes solo envían sus controles |
| Servidor | Godot **headless**, el mismo código de `scripts/sim/*` que el cliente |
| Latencia | Predicción en el cliente y reconciliación (rollback) |
| Transporte | WebSocket detrás de una interfaz; WebRTC después si hace falta |
| Identidad | **Cuenta de Steam** en todas partes (en web, con Steam OpenID) |
| Antitrampas | Servidor autoritativo + registro de repeticiones (replays) para revisar |
| Compañeros de partida | Solo humanos; sin bots en las partidas online |
| Desconexión | El jugador sale y cuenta como último (regla de abandono ya existente) |
| Escala | Cientos de jugadores simultáneos; global desde el primer día |
| Dinero | Gratis en todas partes, sin pagos |
| Publicación | Primero web (local), luego online, luego Steam Playtest y Early Access |
| Equipo | Equipo pequeño |

Fuera de alcance de esta versión: salas privadas e invitaciones de amigos, bots en online, pagos y cosméticos, modo espectador, chat, temporadas, otras plataformas (móvil, consolas), mapas distintos por carrera (ver `SPEC_RANKING.md` §3).

## 2. Qué se reutiliza y qué cambia en el juego

La simulación es pura y determinista a 1/60 s (`scripts/sim/*`) y cada asiento se controla con **un byte por tick** (`PlayerInput`). Eso hace posible este diseño: la red solo transporta bytes de control, no estados.

- Sin cambios en `scripts/sim/*`: no conoce la red. El test de pureza (`test_sim_purity`) sigue prohibiendo nodos, `static var` y singletons del motor. La red vive en código nuevo (§11).
- `World.clone()`, `World.to_array()`/`from_array()` (FORMAT 6) y `Match` (FORMAT 2) ya existen: son la base de las instantáneas y del rollback.
- `Match.abandon` y el byte `0xFF` de bot ya marcan un asiento como abandonado: el servidor los usa para las desconexiones.
- `Ranking.apply` y las tablas por tamaño de campo (2 a 6) ya sirven para campos de solo humanos.
- Cambios de reglas solo para online: **no hay pausa** (el byte de pausa se ignora en el servidor), y entre carreras no hace falta que todos pulsen aceptar: la pantalla de resultados avanza sola tras `ONLINE_RESULTS_SECONDS` (*propuesta*: 10 s).

## 3. Arquitectura

```
 Cliente de Steam ─┐                       ┌── Servidor de juego (Godot headless), región A
 Cliente web ──────┼─ wss ─► Proxy TLS ───►├── Servidor de juego, región B
                   │                       └── Servidor de juego, región C
                   │            ▲  registro, latido, resultados
                   └─ https ──► API / matchmaker ──► PostgreSQL
                                 ▲
                         Steam Web API (verifica tickets y OpenID)
```

- **API y matchmaker** (una sola instancia lógica, global): cuentas, sesiones, cola, asignación de servidor, ranking, repeticiones. Puede ser un proceso Godot headless con `HTTPServer` propio o un servicio ligero aparte; se decide en M3 (§13). La base de datos es **PostgreSQL**.
- **Servidores de juego**: procesos Godot headless en cada región. Como la simulación es pura, **un proceso aloja muchas partidas** (cada una es un `Match` en memoria). Se registran en el matchmaker, mandan un latido con su capacidad y reciben partidas.
- **Proxy TLS** (Caddy o nginx) delante de cada servidor de juego: los navegadores solo aceptan `wss://` desde una página `https://`, y Godot headless no termina TLS con comodidad. Cada región tiene su dominio (por ejemplo `eu.play.<dominio>`).
- **Regiones iniciales** (*propuesta*): América, Europa y Asia-Pacífico. Hay **una cola global**; el matchmaker elige para cada carrera el servidor con menor latencia máxima entre sus jugadores (§6). Otras regiones se añaden cuando haya jugadores que las justifiquen.

## 4. Identidad y sesión

Una cuenta es un **SteamID de 64 bits**. No hay otro método de acceso en esta versión.

**Cliente de Steam (GodotSteam)**
1. El cliente pide un ticket de autenticación web (`getAuthTicketForWebApi`, identidad `fuelrivals`).
2. `POST /auth/steam` con el ticket. La API lo verifica con la Steam Web API (`ISteamUserAuth/AuthenticateUserTicket`).
3. La API responde con un **token de sesión** opaco (caducidad *propuesta*: 24 h).

**Cliente web (Steam OpenID)**
1. El botón ONLINE abre la redirección a Steam OpenID (ventana o redirección completa) con retorno a la API.
2. La API verifica la respuesta (`check_authentication`) y obtiene el SteamID.
3. La API devuelve la sesión a la página (token en el fragmento de la URL, leído con `JavaScriptBridge`; nunca en la query).

Con la sesión, el cliente:
- lee su perfil (`GET /me`): nombre, puntos de ranking, división;
- **nombre mostrado** = nombre de perfil de Steam, pasado a mayúsculas, solo los caracteres de `Names.CHARS`, filtrado contra insultos y recortado a `Names.MAX` (8). Si queda por debajo de `Names.MIN` (3) se rellena con `P` + las cifras finales del SteamID. Hay un camino de **reporte y renombrado** (§12);
- **datos guardados** (*propuesta*): SteamID, nombre, puntos, partidas y repeticiones. Debe existir un borrado de cuenta (§12).

No se confía en nada que el cliente diga sobre su identidad en la partida: el servidor de juego solo acepta un **billete de partida** firmado por la API (SteamID, asiento, ID de partida, caducidad de 60 s).

## 5. Protocolo

Mensajes binarios sobre `WebSocketPeer` (nuestro propio protocolo, no la API multijugador de alto nivel de Godot, para controlar el formato y sustituir el transporte). Todos empiezan con `u8 tipo`. Versión del protocolo en el saludo; si no coincide con el servidor, se rechaza con un mensaje que pide actualizar.

Cliente → servidor:

| Tipo | Contenido |
|---|---|
| `HELLO` | versión del protocolo, versión del juego, hash de la simulación (§14), billete de partida |
| `INPUT` | `tick:u32`, `byte:u8`; se envía en cada tick, con los últimos 4 controles repetidos para tolerar pérdidas |
| `PING` | marca de tiempo del cliente |
| `ACK_SNAPSHOT` | `tick:u32` de la última instantánea recibida |

Servidor → cliente:

| Tipo | Contenido |
|---|---|
| `WELCOME` | asiento propio, número de asientos, semilla, configuración de la partida (`Config.game()` más la afinación activa), tick de salida, tick del servidor |
| `TICKS` | `tick:u32` inicial y los bytes de los controles **confirmados** de todos los asientos, 1 byte por asiento y tick; se envía cada 2 ticks (30 Hz, *propuesta*) |
| `SNAPSHOT` | `tick:u32` y el estado de `Match` en su formato de matriz; cada 60 ticks (1 s) y bajo demanda |
| `CHECKSUM` | `tick:u32` y suma de comprobación del estado, cada 60 ticks |
| `PONG` | marca de tiempo del cliente y tick actual del servidor |
| `EVENT` | desconexión de un asiento, fin de carrera, fin de partida y resultados |

Tamaño aproximado: 6 asientos × 1 byte × 60 Hz = 360 B/s de controles, más cabeceras y una instantánea por segundo (unos pocos KB). Menos de 20 KB/s por cliente.

## 6. Modelo de ticks, predicción y reconciliación

Idea: el servidor construye el **flujo canónico de controles** (un byte por asiento y tick) y ejecuta la simulación con él. Cada cliente ejecuta la misma simulación con ese flujo, así que llega exactamente al mismo estado que el servidor, y para no esperar a la red **predice** los controles que aún no ha recibido.

**Servidor**
- Avanza un tick cada 1/60 s con el reloj del proceso (`FixedStep`). Para el tick `T` toma de cada asiento el último `INPUT` recibido con `tick ≤ T`; si no hay ninguno nuevo, **repite el anterior**. Un `INPUT` que llega tarde se aplica en el tick actual (no reescribe el pasado).
- Los asientos desconectados reciben el byte de bot `0xFF`, que la simulación ya marca como abandono (`Match.step`).
- Difunde los controles confirmados (`TICKS`), las instantáneas y las sumas de comprobación.
- Sin pausa: ignora el bit de pausa.

**Cliente**
- Mantiene un reloj estimado del servidor con `PING`/`PONG` (media móvil del desfase). Corre **por delante** del servidor la mitad del RTT más un margen `INPUT_LEAD_TICKS` (*propuesta*: 2) para que sus controles lleguen a tiempo.
- Ejecuta `Match.step` con sus propios controles **al instante** (predicción local) y con los controles de los demás **predichos** (repite el último conocido).
- Guarda un anillo de instantáneas (`World.clone()`/`Match` clonado) de los últimos `ROLLBACK_TICKS` (*propuesta*: 30, 0,5 s) y los controles usados en cada tick.
- Al llegar `TICKS` confirmados: si coinciden con lo predicho no hace nada; si alguno difiere, **restaura la instantánea** de ese tick y **vuelve a simular** hasta el tick actual con los controles ya corregidos.
- Si el desvío supera `ROLLBACK_TICKS` o la suma de comprobación del servidor no coincide, pide o usa una `SNAPSHOT` y se resincroniza (`Match.from_array`).
- Las pantallas leen el estado simulado como siempre. Los sonidos de `audio.gd` no deben repetirse en un rollback: se disparan solo desde los ticks confirmados o se descartan los eventos de un tick ya reproducido (§14).

**Salida**: el servidor fija el tick de salida; la cuenta atrás de 3 s (`race_start_ticks`) y las luces del semáforo se derivan del tick, no de relojes del cliente.

## 7. Emparejamiento

**Cola**: `POST /queue` con la sesión. Cada ticket guarda SteamID, puntos, latencias medidas a cada región (el cliente hace `PING` a los proxies antes de entrar) y la hora de entrada.

**Reglas** (*propuesta*; el servicio las evalúa cada segundo):
1. Ordena los tickets por puntos.
2. Dos tickets son compatibles si la diferencia de puntos es ≤ `band(espera)`, con `band = 1 división` al entrar y `+1 división` cada 10 s de espera del más reciente, hasta cualquier división tras 30 s.
3. Forma un grupo con hasta **6** compatibles (cualquier tamaño de 2 a 6). Se lanza cuando se llega a 6, o cuando el ticket más antiguo lleva `QUEUE_MAX_WAIT` = 30 s y hay al menos 2.
4. **Servidor**: el de menor latencia máxima del grupo, entre los que tienen capacidad. Si la mejor latencia máxima supera `MAX_PING_MS` (*propuesta*: 250) se acepta igualmente tras 30 s, avisando al jugador.
5. Con un solo jugador en cola, sigue esperando; la pantalla muestra el tiempo y "BUSCANDO RIVALES".

**Resultado**: la API crea la partida en el servidor elegido, genera la semilla y el billete de cada jugador y los envía por la conexión de la cola (consulta periódica o `WebSocket` de la API).

## 8. Flujo de una partida online

1. Cola → encontrada → cada cliente abre `wss://` al servidor y envía `HELLO`; el servidor espera a todos (`JOIN_TIMEOUT` 15 s; los que no llegan se tratan como abandono antes de empezar).
2. `WELCOME` con la semilla y el tick de salida. Cuenta atrás de 3 s con el semáforo existente (`start_lights_lit`).
3. Tres carreras según `SPEC_RANKING.md`: tras cada una, resultados `ONLINE_RESULTS_SECONDS` y siguiente carrera.
4. Al decidirse la partida, el servidor envía los resultados a la API (§9) y a los clientes (`EVENT`). La pantalla de fin de partida muestra puntos de carrera y cambio de ranking, como hoy.
5. Los clientes vuelven al título (o a la cola con "OTRA PARTIDA"). No hay revancha con el mismo grupo.

**Desconexión**: si un cliente cae (cierre del socket o `CLIENT_TIMEOUT` = 5 s sin `INPUT`), el servidor le pone `0xFF`. El coche sigue como bot pero **cuenta como último** y recibe la penalización de abandono de `SPEC_RANKING.md` §6. No hay ventana de reconexión en esta versión. Si queda un solo humano conectado, la partida se **anula** para él (sin cambio de ranking); los que se fueron conservan su penalización.

## 9. Resultados, ranking y repeticiones

**Liquidación**: el servidor de juego envía `POST /matches/{id}/result` con la lista por asiento (SteamID, puntos de carrera, puesto final, abandono) y la repetición. La API calcula el cambio de ranking con **la misma tabla** (`Ranking.delta` por tamaño de campo; los datos de `ranking.gd` se leen de un recurso compartido o se replican con una prueba que los compare) y lo aplica en una transacción **idempotente** por ID de partida. Los puntos no bajan de 0.

**Repetición**: se guarda la semilla, la configuración y afinación, la versión del juego/simulación, los asientos, y el flujo canónico de controles (1 byte por asiento y tick, comprimido; unos pocos KB por partida). Con la simulación determinista basta para reproducir cualquier partida y su suma de comprobación final.

**Revisión**: una tarea sin conexión puede volver a simular una repetición con Godot headless y comparar el resultado con el liquidado (para partidas marcadas por reporte o por reglas, por ejemplo tiempos imposibles). Los administradores pueden anular una partida (revierte el ranking).

**Esquema** (*propuesta*):

| Tabla | Columnas principales |
|---|---|
| `players` | `steam_id` (clave), `name`, `created_at`, `banned`, `deleted_at` |
| `ratings` | `steam_id`, `points`, `updated_at` |
| `matches` | `id`, `region`, `field_size`, `seed`, `game_version`, `sim_hash`, `started_at`, `finished_at`, `status` (`ok`, `void`, `annulled`) |
| `match_players` | `match_id`, `steam_id`, `seat`, `race_points`, `final_place`, `abandoned`, `points_before`, `points_after` |
| `replays` | `match_id`, `format`, `data` |
| `reports` | `id`, `reporter`, `target`, `match_id`, `reason`, `created_at` |

**Tabla de líderes online**: `GET /leaderboard?limit=` (los mejores N por puntos) y `GET /me`. La pantalla RANKING usa `RankingStore` para LOCAL y un `OnlineRankingStore` (misma interfaz: `record`/`apply`/`top`) que habla con la API. La interfaz ya está lista para esto (`SPEC_RANKING.md` §10).

## 10. Seguridad y trampas

- El cliente **no decide nada**: envía un byte de control por tick. El servidor valida que el byte sea de los permitidos, limita a un `INPUT` por tick y asiento (descarta el exceso) y liga cada asiento a su conexión y billete.
- Un tick de `INPUT` demasiado en el futuro (> `INPUT_FUTURE_MAX` = 30 ticks) o en el pasado se descarta.
- Límite de tasa y tamaño de mensaje; desconexión ante mensajes inválidos repetidos.
- Los billetes de partida caducan en 60 s y solo valen para una partida y asiento.
- La API limita intentos de acceso y de cola por SteamID e IP.
- Límite honesto: un jugador puede usar scripts o macros que generen controles legítimos (bots). No se resuelve en esta versión; las repeticiones permiten revisarlo y el sistema de reportes lo canaliza (§12).
- Los secretos (claves de la Steam Web API, firma de billetes) viven en variables de entorno del servidor, nunca en el cliente ni en el repositorio.

## 11. Estructura de código propuesta

Nada de esto toca `scripts/sim/*`. Los nuevos directorios siguen las reglas existentes (tipos estrictos, advertencias como errores, pruebas junto al código).

```
scripts/net/
  protocol.gd            codificación y lectura de los mensajes de §5
  transport.gd           interfaz: connect, send, poll, estado
  ws_transport.gd        WebSocketPeer (escritorio y web)
  loopback_transport.gd  en memoria, con latencia, jitter y pérdida configurables (para pruebas)
  clock_sync.gd          reloj del servidor estimado con PING/PONG
  rollback.gd            anillo de instantáneas, resimulación, resincronización
  online_session.gd      une transporte + rollback + Match para el cliente
scripts/server/
  server_main.gd         punto de entrada headless (argumentos: puerto, región, clave)
  room.gd                una partida: asientos, bucle de ticks, difusión, desconexiones
  host.gd                varias salas en un proceso, registro y latido en la API
scripts/app/
  queue_screen.gd        pantalla "BUSCANDO RIVALES"
  online_ranking_store.gd
tools/
  net_sim.gd             simula N clientes con red degradada contra una sala
  replay.gd              reproduce una repetición y compara la suma de comprobación
```

Cambios en lo existente: la opción ONLINE del título (hoy una interfaz limpia) abre inicio de sesión y cola; `versus.gd` aprende a leer el estado de `online_session` en lugar de ejecutar el `Match` local; la pausa se desactiva en online; `audio.gd` recibe los eventos sin repetirlos en un rollback.

## 12. Plataformas, moderación y datos personales

**Web**
- Exportación sin hilos (Godot 4.3 o posterior) para no exigir cabeceras COOP/COEP y poder alojarla en cualquier sitio estático (por ejemplo itch.io o la propia web del juego).
- El complemento GodotSteam **no se incluye** en el preset web; `start_steam` ya queda en "desactivado" y se verifica en pruebas.
- Audio: los navegadores bloquean el sonido hasta el primer gesto; el título pide "PULSA UNA TECLA" antes de empezar la música.
- Pantalla completa: F11 es del navegador; hace falta una tecla o botón dentro de la página (y que Esc, que sale de pantalla completa, no rompa el "volver"). Revisar que `-`, `+`, `M` y Retroceso no activen acciones del navegador.
- `user://` es el almacenamiento del navegador (la configuración de volumen persiste, pero puede borrarse).
- Primera carga: ~30 MB del motor; mostrar progreso.

**Steam**: Steam Input ya está hecho (`STEAM_INPUT.md`). Falta la ficha de tienda, el despliegue de compilaciones con SteamPipe, Playtest primero y Early Access después, y la comprobación en Steam Deck.

**Moderación**: filtro de insultos al derivar el nombre (§4); botón REPORTAR en la pantalla de resultados que guarda `reports`; la revisión es manual con las repeticiones; los baneos son por SteamID.

**Datos personales**: política de privacidad (SteamID y nombre público de Steam, partidas, repeticiones); borrado de cuenta bajo petición (se anonimiza el nombre y se retira el SteamID de `players`, conservando las repeticiones sin identidad). Las repeticiones no guardan nada personal más allá del asiento.

## 13. Hitos y criterios de aceptación

Cada hito se cierra con pruebas automáticas ejecutables sin red real (`tools/test.sh`) más una comprobación manual donde se indica.

**M0. Compilación web local** (previo a todo lo online). Preset web, GodotSteam excluido, gesto de audio, pantalla completa en página.
- Arranca sin errores en Chrome y Firefox; las 94 comprobaciones de `controls_check` y `smoke` pasan en escritorio; jugar una partida LOCAL completa en el navegador con teclado y mando; la suma de comprobación del sim de `tests/golden` coincide en la compilación web.

**M1. Protocolo y transporte simulado.** `protocol.gd`, la interfaz de transporte y `loopback_transport.gd`.
- Pruebas de codificación/decodificación de todos los mensajes (incluidos mensajes truncados y basura); versiones incompatibles rechazadas.

**M2. Servidor y cliente con rollback (escritorio).** `room.gd`, `server_main.gd`, `rollback.gd`, `online_session.gd`.
- Con 6 clientes simulados en memoria, 150 ms de latencia, 30 ms de jitter y 5 % de pérdida: tras una partida de 3 carreras, **el estado de cada cliente es idéntico al del servidor** (suma de comprobación) en todos los ticks confirmados, sin resincronizaciones.
- Un cliente con 600 ms de latencia o 20 % de pérdida no corrompe a los demás (el servidor repite sus controles).
- Una desconexión a mitad de carrera marca abandono y deja el ranking calculado según `SPEC_RANKING.md`.
- Manual: dos ventanas en LAN, con y sin latencia artificial; el coche propio responde al instante.

**M3. Servicio de cuentas y ranking.** Autenticación de Steam (ticket) y OpenID, base de datos, `result`, tabla de líderes, repeticiones.
- Liquidación idempotente (repetir el envío no cambia los puntos); los puntos nunca bajan de 0; un billete caducado o reutilizado se rechaza; el repetidor reproduce una partida y obtiene la misma suma de comprobación final.

**M4. Emparejamiento y regiones.** Cola, bandas de división que se amplían, elección de servidor, registro y latido de servidores.
- Pruebas unitarias del emparejador con colas sintéticas (casos de 1, 2, 5 y 30 jugadores; ampliación de la banda con el tiempo; nadie espera más de `QUEUE_MAX_WAIT` con ≥ 2 compatibles).
- Con 100 jugadores simulados el emparejador forma grupos de 2 a 6 sin repetir jugadores.

**M5. Online en la web.** `wss`, OpenID, sesión desde el fragmento de la URL.
- Una partida mixta de 2 jugadores (uno en Steam, uno en el navegador) termina con el mismo resultado en ambos y el ranking aplicado.

**M6. Steam Playtest.** SteamPipe, ficha, política de privacidad, borrado de cuenta, reportes.
- Instalación y partida online completa en una máquina limpia desde el cliente de Steam; Steam Deck verificado.

## 14. Riesgos y puntos abiertos

1. **Determinismo entre plataformas.** La simulación usa números `float` (doble precisión). Hoy `scripts/sim` no llama a `sin`, `cos` ni `pow` (que sí pueden diferir en el último bit entre sistemas), solo a operaciones básicas que son iguales en todas partes, así que el riesgo es bajo. Hay que mantenerlo así (una prueba que busque esas funciones en `scripts/sim`) y correr la prueba dorada (`tests/golden`) en Linux y en la web (M0 y M2). La suma de comprobación periódica y el reenvío de instantáneas detectan y corrigen cualquier desviación que aparezca.
2. **Coste del rollback.** `World.clone()` 30 veces por resimulación con 6 coches debe caber en el presupuesto de un fotograma. Medir en M2; si no cabe, bajar `ROLLBACK_TICKS`, clonar solo los campos cambiantes o simular a saltos.
3. **Capacidad de un proceso Godot.** Cuántas partidas aloja a 60 Hz: medir en M2 con partidas de bots. Define cuántos servidores hacen falta para "cientos de jugadores".
4. **WebSocket sobre TCP.** Una pérdida de paquetes bloquea los siguientes. La predicción lo disimula; si se nota, cambiar a WebRTC detrás de la interfaz de transporte (sin tocar el resto). Medir con pérdida simulada en M2.
5. **Cola vacía al principio.** Con cola global de solo humanos y pocos jugadores, las esperas serán largas. Se mitiga con la banda que se amplía, pero hay que decidir antes de Early Access si se permiten bots de relleno (hoy queda fuera de alcance).
6. **Todos necesitan Steam.** Los jugadores web sin cuenta de Steam no pueden jugar online. Un acceso adicional (invitado, Google) rompería "una identidad por jugador"; se deja para más adelante.
7. **Audio y rollback.** `audio.gd` dispara sonidos desde `race_step`; con rollback un tick se simula dos veces. Hay que reproducir sonidos solo de ticks confirmados o llevar un contador de ticks ya sonados.
8. **Versiones.** Cliente y servidor deben usar la misma versión de la simulación. `HELLO` incluye el hash de la simulación (por ejemplo, la suma de comprobación de un tramo fijo de la partida dorada); si no coincide, el servidor rechaza y la web fuerza recarga.
9. **TLS y dominios.** Cada región necesita dominio y certificado (renovación automática).
10. **Coste de operación.** Cientos de jugadores y tres regiones son varias máquinas y vigilancia. Hay que fijar métricas (partidas activas, ping medio, cola, desincronizaciones, errores) y alarmas desde M2.

Abierto, por decidir con datos: el valor de `INPUT_LEAD_TICKS` y de `ROLLBACK_TICKS`, cuánto esperar en cola, qué hacer con colas vacías, cómo se contará una partida anulada para quien se quedó, y el alojamiento concreto (proveedor y tamaño de máquina).

## 15. Stack tecnológico

Aprobado el 23-10-2026 y corregido tras la revisión adversarial (§16).

| # | Capa | Decisión | Alternativa descartada |
|---|---|---|---|
| 1 | Motor y cliente | Godot 4.7.2, GDScript, renderer Compatibility | — |
| 2 | Simulación | La actual (`scripts/sim`) sin cambios, más una prueba que prohíba `sin`/`cos`/`pow` en ella | Reescribirla en otro lenguaje |
| 3 | Servidor de juego | Godot headless en Linux, un proceso con muchas partidas, en un contenedor Docker | Servidor en Go o Node |
| 4 | Transporte | WebSocket (`WebSocketPeer`) con protocolo binario propio, detrás de una interfaz | WebRTC desde el inicio |
| 5 | Netcode | Flujo de controles autoritativo del servidor y predicción con rollback en el cliente | Instantáneas de estado completas |
| 6 | TLS | Caddy delante de cada servidor de juego, con certificados automáticos | Terminar TLS dentro de Godot |
| 7 | API y matchmaker | **Servicio en Go** (net/http, pgx, un cliente OpenID probado); los SteamID viajan como texto. Una prueba de CI compara sus tablas de puntos con `ranking.gd` | Godot headless (no tiene servidor HTTP ni cliente SQL mantenido) |
| 8 | Base de datos | PostgreSQL | Firebase, Supabase |
| 9 | Identidad | SteamID: ticket de GodotSteam en escritorio, Steam OpenID en web | Cuentas propias, Google |
| 10 | Hosting | **Beta: Oracle Cloud Always Free (ARM Ampere), una sola región**; después Hetzner de pago y más regiones si los datos lo piden | Nube gestionada con autoescalado |
| 11 | Despliegue | Docker Compose, imágenes en GitHub Container Registry, despliegue con GitHub Actions | Kubernetes |
| 12 | Web | Exportación sin hilos servida desde **dominio propio** (Caddy, Brotli), misma origen que la API. itch.io solo enlaza o aloja la versión LOCAL | itch.io para la versión online |
| 13 | Steam | SteamPipe, Playtest y después Early Access | — |
| 14 | CI | GitHub Actions: pruebas, `controls_check` y smoke en Windows y Linux; exportación web y de escritorio | Pruebas solo locales |
| 15 | Observabilidad | Logs JSON, Grafana Cloud (nivel gratuito) y una sonda externa; los servidores mandan métricas en el latido | Prometheus y Grafana propios |
| 16 | Repeticiones | Semilla más flujo de controles comprimido, en PostgreSQL (`bytea`) | Almacenamiento de objetos |
| 17 | Moderación | Filtro de insultos local con lista versionada, reportes en base de datos, revisión manual | Servicio externo |
| 18 | Privacidad | Política publicada, borrado de cuenta bajo petición, datos mínimos | — |

**Decisiones de producto que acompañan al stack** (modifican §1, §7 y §8):
- **Cola vacía:** tras 30 s de espera se rellena con bots, solo mientras la comunidad sea pequeña. Una partida con bots **no cambia el ranking**. Las partidas online sin bots siguen el spec.
- **Jugador que se queda solo:** la partida se anula para él, sin cambio de ranking.
- **Web:** todo jugador online necesita cuenta de Steam.
- **Free-to-play:** sin pagos por ahora; la arquitectura no los impide.

## 16. Revisión adversarial: decisiones aprobadas (prevalecen sobre §1 a §15)

Cuatro revisores (netcode, backend, plataformas, producto y seguridad) atacaron el diseño el 23-10-2026. Todo lo siguiente fue aprobado. Mediciones citadas: un `Match.step` cuesta unos 70 µs, un `World.clone()` 70 a 85 µs, la instantánea ocupa unos 3,3 KB, el cliente usa unos 6 KB/s y una repetición comprimida ocupa unos 3 KB.

### 16.1 Cambios de arquitectura
1. **API en Go**, no en Godot (§3, §15.7). Los servidores de juego siguen en Godot. Los SteamID son texto en todo el protocolo y la API. Una prueba de CI compara las tablas de puntos con `scripts/sim/ranking.gd`.
2. **Dos estados en el cliente** en lugar del anillo de instantáneas (§6): un estado *confirmado*, que sigue el flujo ordenado del servidor y nunca retrocede, y uno *predicho*, que se reconstruye desde el confirmado cada fotograma. Se resincroniza solo si falla la suma de comprobación. Pasado `MAX_PREDICT` ticks sin confirmación se congela la predicción en lugar de resincronizar. Sustituye a `ROLLBACK_TICKS` y a "ningún resync" en M2.
3. **Reloj y adelanto de entrada** (§6): el servidor usa un reloj monotónico (no el `FixedStep`, que descarta atrasos). `TICKS` informa a cada cliente de su margen de llegada y el cliente acelera o frena un ±2 % para mantener el percentil 95 de sus entradas al menos 1 tick antes. En las pruebas se aclara si 150 ms es de ida o de ida y vuelta. Una entrada pasada se aplica al tick actual (§6) y no se descarta (§10); solo se descartan las futuras lejanas.
4. **Loopback como TCP**: en orden, y las pérdidas aparecen como retraso, no como mensajes perdidos.
5. **WebSocket para la beta; WebRTC (canal no fiable) para `INPUT`/`TICKS`** cuando haya jugadores con pérdida de paquetes. La beta se juzga con ≤ 2 % de pérdida. Se corrige §14.4: la predicción no oculta los bloqueos de TCP en el coche propio.
6. **Bits de control**: se enmascaran los bits 5 a 7 en cliente y servidor, se rechaza `0xFF` de un cliente y el bit de pausa se ignora. El servidor añade el CONFIRM al flujo 600 ticks tras el fin de cada carrera.
7. **Configuración**: `WELCOME` y `CHECKSUM` llevan un resumen de `cfg`, porque la instantánea solo serializa `cfg.profile`.
8. **Efectos de lado**: los sonidos de un tick se reproducen una sola vez, la primera vez que se predice; los resultados y las melodías de fin salen del estado confirmado o del `EVENT` del servidor. Las correcciones de coches remotos y de cámara se suavizan solo en la vista.
9. **Instantáneas** solo cuando falla la suma de comprobación, y escalonadas entre salas.
10. **Un proceso por vCPU** del servidor de juego; cada servidor tiene su propia clave.

### 16.2 Confianza y resultados
- El billete de partida (firmado con la clave de ese servidor) lleva ID de partida, semilla y jugadores; el primer `HELLO` válido crea la sala. Se elimina la llamada "crear partida" de la API al servidor.
- La API recuerda los jugadores asignados y de los servidores solo acepta puestos y abandonos. Calcula ella los puntos y guarda el cambio realmente aplicado (tras el suelo de 0), para anular exactamente. El primer resultado gana; uno distinto después devuelve 409 y una alerta.
- Un SteamID, una sesión activa y una partida a la vez. Los servidores guardan un buzón en disco y reintentan.
- Se vuelve a simular del 5 al 10 % de las repeticiones.
- Latido con arrendamiento: si un servidor calla se liberan sus jugadores y se anulan sus partidas sin liquidar tras N horas.
- Despliegue: servidores en drenaje, `stop_grace_period` mayor que una partida, `stream_close_delay` en Caddy y colas por hash de simulación (conviven la versión nueva y la anterior).
- Conexiones: validar el billete al abrir el socket, cerrar si no hay `HELLO` en 2 s, límite de conexiones por IP en el proxy.

### 16.3 Identidad y cuentas
- **Steam OpenID** (§4): POST solo a `https://steamcommunity.com/openid/login`; `op_endpoint` exacto; `return_to` exacto con `state`; `claimed_id` igual a `identity`, con la forma `^https://steamcommunity\.com/openid/id/\d{17}$` y firmados; nonce de un solo uso de menos de 5 minutos; `state` ligado a una cookie `__Host-` SameSite=Lax. Se devuelve a la página un **código de un solo uso de 60 s** (no la sesión), que se canjea por POST; luego `history.replaceState`. El nombre se pide en el servidor con `GetPlayerSummaries` y se filtra con el filtro de texto de Steam.
- **Invitados** (web): token aleatorio de 7 días con límite por IP, en la misma cola, **sin puntos**. Vincular una cuenta de Steam activa el ranking. Se respeta `publisherbanned`.
- **Esquema** (§9): `player_id` interno en todas las tablas; el SteamID solo en `players` (anulable); hash con sal para los baneos; las IP solo en memoria; registros y copias hasta 30 días; borrado de cuenta que limpia `match_players`, `ratings`, `reports` y las IP; exportación de datos.
- **Ranking** (§7): una partida puntúa solo si los humanos están a 2 divisiones o menos (por número de división). Las demás, los jugadores de la misma /24 y los emparejamientos repetidos más de 3 veces al día juegan sin puntos. Valoración oculta (OpenSkill o Glicko) para emparejar y escalar, periodo provisional para cuentas nuevas y reinicios de temporada: diseño en una especificación aparte antes de abrir una tabla pública.

### 16.4 Producto
- **Relleno con bots** (cambia §1 y §7): toda carrera se rellena a 6 con bots marcados. Con 2 o más humanos puntúan entre ellos; con 1 humano la partida no puntúa. Se retira "sin bots en online" de §1 y §14.5.
- **Abandono** (§8): el jugador que se queda en una partida de 2 recibe el resultado (no se anula). **Reconexión de 30 a 60 s** con la instantánea; el abandono definitivo y la penalización llegan al agotarse. Se añade un aviso de partida encontrada con confirmación. Colas de castigo para los que abandonan a menudo. `CLIENT_TIMEOUT` pasa a ser largo mientras el socket siga abierto, y en web un aviso `visibilitychange` cede el asiento a un bot. Cambio pequeño en `scripts/sim/match.gd`: el primer `0xFF` ya no abandona para siempre.
- **Salas privadas sin puntos** (por código), antes de M4. Invitaciones de Steam más tarde.
- **Una sola región** para la beta (Oracle Free). Las demás se añaden con datos.
- **Antitrampas**: la semilla de cada tramo de pista se revela al cliente poco antes de necesitarla, más comprobaciones automáticas sobre las repeticiones.

### 16.5 Plataformas y Steam
- **Web online**: página completa en un dominio propio, misma origen que la API (sin CORS); el inicio de sesión es una redirección de página completa desde el título. Se descarta itch.io para la versión online.
- **`APP_ID`** (`scripts/input/steam_input.gd`): pasar 0 cuando Steam lanza el juego; 480 solo en desarrollo. Playtest usa un App ID hijo; el manifiesto de Steam Input se declara en ambos.
- **Steam Direct** (cuota, identidad, banco, impuestos, revisión de marca "Fuel Rivals" y página "Coming Soon") se inicia ahora; la clave de la Web API de editor depende de tener App ID propio.
- **Steam Deck**: criterio de M6 = probado en Deck y revisión solicitada.
- **Web**: medir 30 ticks de resimulación en un portátil flojo; plantilla de exportación personalizada sin 3D ni módulos que no se usan (pasar la prueba dorada); en Safari un mando no cuenta como gesto: "PULSA UNA TECLA" exige tecla o clic. Preset de servidor dedicado con su propia escena principal y sin GodotSteam, comprobado en CI. Añadir `addons/godotsteam/win64/~*.TMP` al `.gitignore`. Prueba automática en Windows en CI.

### 16.6 Operación, hosting y coste
- **Beta**: Oracle Cloud Always Free (ARM64), una región; servidor de juego, API en Go, PostgreSQL y Caddy. Capacidad estimada: **450 a 900 jugadores simultáneos** (límite: CPU, después tráfico); se confirma en M2. Es suficiente para la beta. Hay que exportar el servidor para Linux ARM64 y probarlo. Riesgos: alta con tarjeta, instancias inactivas recuperables, región fija.
- **Después de la beta**: Hetzner de pago (unos 60 a 90 € al mes) y más regiones, vigilando el tráfico incluido de EE. UU. y Singapur.
- **Observabilidad**: Grafana Cloud gratis, sonda externa, telemetría del embudo título → cola → partida terminada, tiempos de cola y abandonos; volcados de estado en cada desincronización; copias WAL-G con restauración probada (o Postgres gestionado); respaldo en LOCAL si online cae.
- **Herramientas**: entorno de pruebas, clientes bot sin interfaz para pruebas de carga y una herramienta de administración por línea de comandos.
- **Legal**: política de privacidad y términos antes de que se conecte el primer probador externo.

### 16.7 Hitos revisados
- **M0 (ahora)**: demo web LOCAL pública, con enlace a la lista de deseos y un canal de Discord para probadores. **Puerta de decisión**: ¿es divertido jugar con personas contra bots? Si no, se vuelve al juego antes de M1.
  - **M0: implementado** (compilación local): preset "Web" (sin hilos, sin GodotSteam; `build/web/index.html`; `index.wasm` ~39,5 MB sin comprimir, `index.pck` ~0,66 MB), título "PRESS ANY KEY" en la web (tecla o clic, no mando) antes de la música, tecla F como pantalla completa en la web (Esc sigue siendo VOLVER), prueba de `start_steam` sin el complemento, `build/` y `addons/godotsteam/win64/~*.TMP` en `.gitignore`. **Falta**: probarla en Chrome, Firefox y Safari, la suma de comprobación dorada en web y las teclas `-`, `+`, `M` en cada navegador; alojamiento público, enlace a la lista de deseos y canal de Discord son tareas de la persona responsable.
- **M1**: protocolo y transporte loopback tipo TCP.
- **M2**: servidor, cliente de dos estados y salas privadas sin puntos. Puertas de salida: tamaño de la corrección en píxeles, profundidad de resimulación, tiempo de fotograma en la web y una sesión con personas por internet real.
- **M3**: Go + PostgreSQL, Steam Direct en marcha, ranking con la valoración oculta, repeticiones.
- **M4**: emparejamiento, bots de relleno y una región.
- **M5**: web online con OpenID e invitados.
- **M6**: Playtest. Puertas: tasas de desincronización, caídas, tiempo en cola y abandono.

**M1: implementado.** Archivos: `scripts/net/protocol.gd` (mensajes de §5 como `PackedByteArray`; `decode()` devuelve un Dictionary o `{"error": ...}` y no falla ni registra errores con entradas truncadas, basura o demasiado grandes; versión solo en `HELLO`; SteamID como texto; bits 5 a 7 del control enmascarados y `0xFF` de un cliente rechazado; `WELCOME` y `CHECKSUM` llevan el resumen de `cfg`), `scripts/net/transport.gd` (interfaz sin señales: `connect_to`, `send`, `poll`, `get_state`, `get_available_packet_count`, `get_packet`, `close`), `scripts/net/loopback_transport.gd` (en memoria, tipo TCP: en orden, la pérdida solo añade retraso, latencia, jitter y `stall` configurables, semilla fija y reloj propio que solo avanza con `Link.advance(ms)`). Pruebas: `tests/test_net_protocol.gd` y `tests/test_net_loopback.gd`. Detalles: el texto del protocolo es ASCII imprimible (el resto se rechaza); no se hizo `net_clock.gd` porque el reloj vive en el `Link`.

**M2: implementado.** Servidor, cliente de dos estados y salas privadas por código (sin puntos), todo en GDScript. `scripts/sim/*` solo cambia en `Match.step(inputs, rejoin = false)`: con `rejoin` (servidor y clientes online) un asiento humano al que se dio el byte `0xFF` vuelve a ser suyo cuando llega un byte real; es un parámetro y no un campo porque `test_sim_purity` y `test_match` prohíben campos nuevos, así que el estado, las instantáneas y los checksums dorados no cambian (`tests/test_net_rejoin.gd`). Protocolo: `protocol.gd` añade `START` (5, el dueño de una sala), `SNAPSHOT_REQ` (6, tras un CHECKSUM distinto) y `LOBBY` (22: código, asiento, dueño, secreto de reconexión y nombres). Archivos: `scripts/server/{room,host,replay,server_main}.gd`, `scripts/net/{ws_transport,ws_server,net_config,ticket,room_code,rollback,online_session}.gd`, `scripts/app/online.gd` con `scripts/view/online_view.gd` y `scenes/online.tscn`, `tools/{net_harness,net_sim,net_client}.gd`, `tools/net_local.sh` y `tests/test_net_*.gd`.
- *Servidor* (`room.gd`): reloj monotónico propio (no el `FixedStep`: un poll tardío ejecuta los ticks que debe, hasta `MAX_CATCH_UP` = 30). Ticks absolutos; `PREROLL_TICKS` = 60 entre el WELCOME y el primer paso. Por asiento se guarda la última entrada: una pasada se aplica ya (no se reescribe el pasado), una a más de `INPUT_FUTURE_MAX` = 30 ticks descarta **todo el mensaje** (también su historial, para que no adelante la marca de "más reciente" y bloquee las buenas; el margen sí se mide), solo cuenta una por tick, los bits 5 a 7 se enmascaran, `0xFF` lo rechaza el decodificador y no hay pausa. Sin recibir nada la entrada se repite; un cliente sin enviar más de 15 s pasa al bot (vuelve al enviar). Desconexión: sigue la última entrada `bot_after_ms` (1,5 s), luego `0xFF` (el `Match` lo cuenta como abandono) y `EVENT_DISCONNECT`; dentro de `grace_ms` (45 s) el mismo billete (o el secreto, en una sala privada) devuelve el asiento con WELCOME y SNAPSHOT y el bot conduce hasta su primera entrada; después es definitivo, y si ninguna persona queda la sala termina incompleta. Añade `CONFIRM` 600 ticks después del fin de cada carrera (solo a personas conectadas). Difunde `TICKS` cada 2 ticks con el margen de llegada de cada cliente, `CHECKSUM` cada 60 ticks (escalonado por sala), `SNAPSHOT` solo a quien lo pide (como mucho uno por segundo) o vuelve, y `EVENT` de fin de carrera, desconexión y fin de partida (puestos, puntos, abandonos). Resultado por asiento (puesto, puntos de carrera, abandono; SteamIDs como texto, `ranked` siempre falso aquí) y repetición (`replay.gd`: semilla, reglas, asientos y el flujo de bytes comprimido; `Replay.run` la reproduce y obtiene el mismo checksum final).
- *Host y billetes* (`host.gd`, `ticket.gd`, `room_code.gd`): muchas salas por proceso; cierra a quien no manda HELLO en 2 s; rechaza versión o hash de simulación distintos (`EVENT_REJECT` con el motivo), billetes falsos, caducados, de otro asiento o sin firma (los `dev.` solo con `--dev`). Billete `v1.PARTIDA.ASIENTO.STEAMID.SEMILLA.CADUCIDAD.ASIENTOS.HUMANOS.HMAC-SHA256`; el primero válido crea la sala. Salas privadas: `new:NOMBRE`, `join:CODIGO:NOMBRE`, `rejoin:CODIGO:ASIENTO:SECRETO`; códigos de 6 caracteres sin 0/O/1/I/L; 6 asientos rellenados con bots; el dueño empieza con `START`. Transporte: `ws_transport.gd` (WebSocketPeer, también en el navegador) y `ws_server.gd` (TCPServer + `accept_stream`); `server_main.gd` (`--port --region --key --dev --no-private --race-px --races --max-seconds`).
- *Cliente* (`rollback.gd`, `online_session.gd`): estado confirmado (solo avanza con los bytes del servidor, nunca retrocede) y estado predicho (copia del confirmado más los ticks sin confirmar con la entrada propia y la última confirmada de cada otro asiento, sin repetir los botones de pulsar). Se reconstruye cuando una entrada confirmada difiere de la usada o cambia el byte confirmado de otro asiento (`always_rebuild` lo hace cada fotograma y da exactamente el mismo estado: lo comprueba una prueba); `MAX_PREDICT` = 60 congela la predicción. Reloj: PING/PONG con filtro de mínimo RTT, adelanto = viaje de ida + 2 ticks + un extra que sube o baja con el percentil 5 del margen (objetivo 2 ticks, tope 12), velocidad ±2 % y salto si la diferencia pasa de 30 ticks. Solo hay resincronización si falla un CHECKSUM (SNAPSHOT_REQ). Los sonidos salen una vez por tick predicho (`on_predicted_tick`); el fin de partida sale del estado confirmado y del `EVENT`; `view_match()` nunca muestra una fase posterior a la confirmada; las correcciones de coches y cámara se suavizan solo en el dibujo (`view_offset`, `versus.gd` dibuja una copia).
- *Pantallas*: ONLINE del título abre `online.gd` (NOMBRE, CREAR SALA, UNIRSE, CÓDIGO; sala de espera con el código y los nombres; el dueño empieza con Aceptar). `versus.gd` con una sesión muestra la partida online sin tocar la ruta LOCAL; Esc sale (abandono) y no hay pausa ni revancha. `--server=ws://host:puerto` en el cliente.
- *Medido* con `tools/net_sim.gd` (6 clientes, 3 carreras de 1800 px, ~4000 ticks, `Match.step` del servidor 36 µs de media y 330 µs como máximo): con 150 ms de ida, 30 ms de jitter, 2 % de retransmisiones y cortes de 1,2 s, profundidad de resimulación p99 = 41 ticks (máx. 56), corrección de cualquier coche p99 = 118 px (máx. 163), del coche propio p99 = 6 px (máx. 68; casi todo tras un corte), tiempo del `update` de un cliente p99 = 2,6 ms (máx. 9 ms), 0 resincronizaciones; sin pérdidas ni cortes: profundidad p99 = 27, corrección propia máx. 2 px, otros coches p99 = 81 px, fotograma p99 = 1,9 ms; con 60 ms y 10 ms de jitter: profundidad 14, corrección propia máx. 0,5 px, otros p99 = 46 px, fotograma p99 = 1,0 ms. La mayor parte de la corrección de los coches ajenos es la predicción de un cambio de carril: es lo que debe suavizar la vista. Con un sexto cliente a 600 ms (y 5 % de retransmisiones) los demás siguen idénticos al servidor y sin resincronizar. Localhost real con tres procesos (`tools/net_local.sh`): ambos clientes terminan con el mismo checksum y el servidor guarda el resultado.
- *Pruebas* (`tests/test_net_*.gd`, 534 en total en el proyecto): aceptación de §13/§16.7 con 6 clientes, 150 ms, 30 ms de jitter, pérdida y cortes (el estado confirmado de cada cliente es el del servidor en cada tick, sin resincronizar); un cliente a 600 ms; congelación y recuperación tras un corte; resincronización por CHECKSUM distinto; desconexión y reconexión; abandono definitivo; reglas de entrada; códigos; billetes; muchas salas; pantallas; WebSocket real en localhost; la repetición reproduce el checksum final. Solo falla la prueba de sha256 de Steam que ya fallaba.
- *No hecho o sin verificar*: una sesión con personas por internet real; el tiempo de fotograma en la web (y que `WebSocketPeer` en el navegador cumpla lo probado en escritorio); TLS/Caddy y dominios; la capacidad real por proceso (solo se midió el coste de `Match.step`: ~0,2 % de un núcleo por sala a 60 Hz, lo que apunta a unos cientos de salas por núcleo, sin sockets); `tools/replay.gd` (existe `Replay.run`); aviso de pestaña oculta (`visibilitychange`) y colas de castigo; la API que emite los billetes (aquí hay un emisor HMAC de pruebas); un buzón en disco para reintentar el envío de resultados (hoy solo `results` y `on_result`); una corrección propia de hasta ~70 px tras un corte largo sigue siendo visible.

**M3 (parte del servicio): implementada** en `backend/` (Go, `net/http`, `pgx/v5`, PostgreSQL; ver `backend/README.md`). Cuentas y sesiones (billete de Steam, OpenID con todas las comprobaciones de §16.3 y código de canje de un solo uso, invitados), valoración oculta **Glicko-2**, reglas de partida puntuable decididas al asignar (humanos puntuables a ≤ 2 divisiones, distinta /24, ≤ 3 emparejamientos al día; los invitados no puntúan), liquidación idempotente de primer resultado ganador (409 y alerta si difiere), anulación exacta, repeticiones (`bytea`, particionadas por mes), arrendamiento de servidores, borrado y exportación de cuenta, y billetes de partida firmados con la clave de cada servidor (formato byte a byte en `backend/docs/TICKET.md`, con vectores de prueba). Las tablas de puntos se comparan con `scripts/sim/ranking.gd` en pruebas Go (`tools/export_ranking_tables.gd` genera `backend/testdata/ranking_tables.json`). Despliegue preparado en `deploy/` y `docs/DEPLOY_ORACLE.md`. **Falta**: el emparejador (M4; hasta entonces `POST /admin/matches` crea la partida y los billetes), probar con Steam real y construir las imágenes Docker.

**M4/M5 cliente: implementado** (la mitad de Godot; el emparejador y la API están en `backend/`). Todo detrás de interfaces pequeñas para probar sin red, navegador ni Steam.
- *Archivos nuevos*: `scripts/net/{api_client,api_result,http_transport,http_request_transport,account,login_flow,steam_auth,web_bridge,matchmaking,match_ticket}.gd`, `scripts/app/{login_screen,queue_screen,online_ranking_store}.gd`, `scripts/view/queue_view.gd`, `scripts/server/{api_link,outbox}.gd`, `scenes/{login,queue}.tscn`. Cambios: `app.gd` (API, login, `use_online`, `show_login/show_queue/leave_online_race`, visibilidad), `title.gd` (ONLINE -> `show_online_entry`), `online_session.gd` (reconexión automática, `send_away`), `protocol.gd` (`AWAY` = 7), `room.gd`/`host.gd` (sala abierta, billete de la API, reclamar puesto con billete caducado, drenaje, `AWAY`), `server_main.gd` (`--api --server-id --register-token --public-url --capacity --exit-when-drained`), `versus.gd`/`versus_hud.gd` (aviso de reconexión, puntos tras la partida), ranking.
- *Decisiones*: URL de la API = `--api=URL`, ajuste `fuel/net/api_url`, en web el origen de la página + `/api`, o `http://127.0.0.1:8080/api`. Los ids viajan como texto y un entero de 16 o más cifras en una respuesta se entrecomilla antes de analizar el JSON. El billete de la API no dice cuántos humanos hay: la sala los toma según llegan y empieza a los 6 s del primero (`Room.gather_ms`) o con 6. Un billete caducado solo sirve para volver a un puesto ya ocupado por la misma persona. Los billetes de texto antiguos se rechazan salvo con `--dev`. El campo `ticket` de `GET /match/{id}/join` se pasa tal cual al HELLO (ya es el texto base64url de TICKET.md). La región de la cola se llama `default` salvo `--regions=nombre=url,...`.
- *Pruebas*: `tests/test_net_{api_client,login,match_ticket,matchmaking,outbox,server_api,screens_online}.gd` con `tests/fake_{http,steam_auth,web}.gd` (vectores de `backend/testdata/ticket_vectors.json`, ids mayores de 2^53, máquina de estados de la cola, ready-check, buzón con reintentos y 409, mensaje de pestaña oculta, reconexión, pantallas).
- *No hecho o sin verificar*: contra el Go real (la forma exacta de `/queue/status`, de los errores de penalización, del latido y de `GET /match/{id}/join` se tomó del encargo y de `backend/README.md`, no se ejecutó); GodotSteam real (`getAuthTicketForWebApi` y su señal `get_ticket_for_web_api` según la API de GodotSteam, sin cliente de Steam aquí); `JavaScriptBridge` en un navegador real (redirección, fragmento, `replaceState`, `visibilitychange`) y `HTTPRequest` en web; que `send()` del WebSocket del navegador salga durante el evento de pestaña oculta; el nombre de región que espera el emparejador; los nombres de las respuestas de penalización (se reconoce 429 o un código con "penal"); el registro del servidor con la API real (la clave sale una vez por la salida estándar); un servidor ARM64; una partida mixta Steam + navegador de punta a punta.
