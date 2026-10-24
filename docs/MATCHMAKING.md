# Emparejamiento (M4, parte del servicio)

Describe la cola, la comprobación de "listo", la elección de servidor, las penalizaciones, el contrato HTTP que usa el cliente, la telemetría y las herramientas de operación. Implementa `SPEC_ONLINE.md` §7 tal como lo corrige §16 (que prevalece). El código está en `backend/internal/matchmaker` (reglas y motor), `backend/internal/api/handlers_queue.go` (HTTP) y `backend/internal/store/queue.go` (base de datos). Las variables de entorno están también en `backend/README.md`.

## 1. Flujo de un jugador

```
idle ──POST /queue──► waiting ──(grupo formado)──► found ──POST /queue/ready──► ready ──(todos listos)──► starting
  ▲                      │ DELETE /queue                │ DELETE /queue (rechazar: falta)        │
  └──────────────────────┴──────────────────────────────┴────────────────────────────────────────┘
starting ──GET /match/{id}/join──► {ws_url, ticket} ──wss + HELLO──► partida ──result del servidor──► liquidación
```

El cliente consulta `GET /queue/status` cada segundo (límite de tasa por cuenta, §5). La cola vive en la memoria del proceso de la API; si la API se reinicia, los que esperaban vuelven a `idle` y deben entrar otra vez. Las partidas ya asignadas viven en PostgreSQL y no se pierden.

## 2. Reglas de la cola

El bucle de emparejamiento corre cada `MATCHMAKER_TICK` (1 s). En cada pasada:

1. **Orden por puntos.** Los tickets (jugador, puntos, latencias por región, hora de entrada, prefijo /24 solo en memoria) se ordenan por puntos. Los invitados cuentan como 0 puntos (primera división) y nunca puntúan.
2. **Banda de compatibilidad.** Dos tickets son compatibles si la diferencia de **número de división** (Bronce=0 … Diamante=4) es como mucho la banda de la espera del **más reciente** de los dos: 1 división al entrar, +1 cada 10 s (`QUEUE_BAND_STEP`) y **cualquier división** desde los 30 s. Con `sim_hash` (opcional en `POST /queue`) solo se mezclan tickets del mismo hash de simulación.
3. **Grupos.** Se parte del ticket que más lleva esperando (los reencolados con prioridad, primero) y se añaden compatibles, primero de otras subredes y más cercanos en puntos, mientras sean compatibles con todos los del grupo, hasta **6**.
4. **Lanzamiento.** Se lanza si hay **6**, o si hay de **2 a 5** y el ticket más antiguo del grupo lleva `QUEUE_MAX_WAIT` (30 s). Un **jugador solo** que lleva `QUEUE_SOLO_WAIT` (30 s) recibe una carrera **contra bots** sin puntos.
5. **Relleno con bots.** El campo se rellena siempre hasta 6 con bots marcados. El registro de la partida guarda `humans` y `bots` (`GET /admin/matches`).
6. **Puntúa o no** se decide **al asignar** (`store.AssignMatch`, reglas de §16.3 ya existentes): al menos 2 humanos con cuenta de Steam, a 2 divisiones o menos entre sí, ninguna pareja en la misma /24 (la IP solo se usa en memoria), y como mucho 3 emparejamientos de la pareja en el día UTC. Los invitados nunca puntúan y no cuentan para la regla. `rank_reason` explica el motivo.
7. **Garantía probada**: nadie espera más de `QUEUE_MAX_WAIT` teniendo al menos otro ticket compatible (prueba con colas sintéticas de 1, 2, 5, 30 y 100 jugadores y reloj inyectable).

## 3. Servidor y capacidad

Entre los servidores registrados con arrendamiento vivo, sin drenaje (del servidor o del operador) y con capacidad libre (`capacity − max(abiertas, activas reportadas) − reservadas por partidas encontradas`), se elige el de **menor latencia máxima** entre los jugadores del grupo (la región sin medir cuenta como 200 ms). Empate: más capacidad libre, luego menor id.

Si esa latencia máxima supera `MAX_PING_MS` (250), el grupo espera hasta `QUEUE_MAX_WAIT` y después se acepta igualmente; el estado trae `high_latency: true` para avisar. Sin servidor utilizable la cola sigue esperando (no hay error). Un jugador solo puede estar en una partida abierta a la vez (`409 busy`).

**Drenaje.** `POST /admin/servers/{id}/drain` (o `adminctl drain`) deja de asignar partidas a ese servidor. La respuesta de cada `POST /servers/heartbeat` trae `drain` (el operador pidió drenar), `capacity`, `assigned_matches` y `free`. El servidor de juego debe dejar de aceptar salas nuevas cuando `drain` es `true` y terminar las que tiene. Su propio `draining` en el latido también cierra la asignación.

## 4. Comprobación de "listo" (ready-check)

Al formarse un grupo, la API reserva el id de partida (el mismo de la base de datos) y los jugadores pasan a `found` durante `READY_SECONDS` (15 s).

- Todos confirman con `POST /queue/ready` → se asigna la partida (semilla, asientos, veredicto de puntuación) y pasan a `starting`.
- Al vencer el plazo, **los que no confirmaron salen** (falta de tipo `ready_timeout`). Si quedan **2 o más** confirmados, la partida empieza con ellos; si queda **uno**, vuelve a la cola **con prioridad** conservando su espera (la regla de jugador solo lo lanza contra bots enseguida); si ninguno, no pasa nada.
- `DELETE /queue` en `found`/`ready` es **rechazar** (falta `ready_decline`): los demás siguen; con menos de 2 miembros el resto vuelve a la cola con prioridad.
- Si la asignación falla (servidor que se llena o drena, jugador aún en otra partida) todos vuelven a la cola con prioridad; el jugador con otra partida abierta se descarta.

## 5. Contrato HTTP

JSON; los ids son **texto**; cabecera `Authorization: Bearer <token de sesión>` (invitados incluidos). Errores: `{"error": "codigo", "message": "..."}`.

| Petición | Respuesta |
|---|---|
| `POST /queue` `{"latencies": {"eu": 35, "us": 120}, "sim_hash": "..."}` (cuerpo opcional) | `200 {"queue_id": "..."}`. Repetir devuelve el mismo id. `403 queue_banned` (`retry_after_s`, `banned_until_unix`), `409 busy` (en una partida o en un ready-check), `429` |
| `GET /queue/status` | `{"state": "idle"\|"waiting"\|"found"\|"ready"\|"starting", "wait_s", "band_divisions", "players_found", "match": {"match_id", "ready_deadline_unix"}}`; extras: `players_confirmed`, `high_latency`. `match` solo en `found`, `ready` y `starting` |
| `POST /queue/ready` `{"match_id": "123"}` | `200` con el estado; `404 no_match` si el id no es el de tu partida encontrada |
| `DELETE /queue` | `200 {"state": "idle", "was": "waiting"\|"found"\|"ready"\|"idle"}` |
| `GET /match/{id}/join` | `{"ws_url", "ticket", "match_id", "seat", "expires_unix"}` |
| `POST /match/{id}/leave` | `{"left": true, "already", "match_status"}` |

- `band_divisions` es la banda de la espera del propio jugador (1, 2, 3 y 5 = cualquier división). `players_found`: compatibles en cola (máx. 6) en `waiting`; miembros del grupo en `found`/`ready`/`starting`. `ready_deadline_unix` es el límite para confirmar.
- **`ticket`** es el billete firmado de `backend/docs/TICKET.md` tal cual (base64url sin relleno de `payload || HMAC`, que el servidor de juego verifica con la clave de su servidor). Se pide cuando el estado es `starting`; caduca **60 s después de la primera petición**; pedirlo otra vez dentro de ese minuto devuelve el mismo billete, después `409 ticket_expired`. `404` si la partida aún no existe o no es tuya, `409 finished`/`left`, `410 gone` si se anuló.
- **`/match/{id}/leave`**: si había billete es un **abandono**: cuenta una falta para la cola de castigo y el asiento queda libre para volver a la cola. El servidor de juego ve el cierre del socket y declara el abandono en su resultado; la API no le avisa. Si se van todos los humanos de una partida sin liquidar, pasa a `void`.
- **Límites de tasa por cuenta** (cubo de fichas en memoria): `POST/DELETE /queue` y `/queue/ready` `RATE_QUEUE_PER_MIN` (20/min, ráfaga 10); `GET /queue/status` `RATE_STATUS_PER_MIN` (90/min, ráfaga 30), además del límite general por cuenta. `429` con `Retry-After`.
- Sigue `POST /admin/matches` (asignación manual con billetes) y todo lo de M3 (`/servers/register`, `/servers/heartbeat`, `/matches/{id}/result`, `/matches/{id}/replay`).

Estados no previstos por el cliente: `403 banned`/`401` si la cuenta está baneada o la sesión caducó.

## 6. Colas de castigo

Cada **falta** (no confirmar, rechazar tras encontrar partida, abandonar una partida asignada) suma una al contador del jugador (olvida las de más de 24 h). Las primeras `PENALTY_FREE_STRIKES` (2) solo avisan; desde la tercera la cola se cierra `PENALTY_BASE` (5 min), el doble en la siguiente (10, 20, 40, 80 min…) hasta `PENALTY_MAX` (2 h). Salir de la cola antes de encontrar partida es gratis. El contador está en memoria y en la tabla `leave_strikes`; `adminctl unban` lo borra.

## 7. Telemetría

`GET /metrics` en formato Prometheus, con `Authorization: Bearer $METRICS_TOKEN` (sin `METRICS_TOKEN` responde 404). Series principales:

- `fr_funnel_total{stage}`: `session` (login), `queued`, `found`, `ready`, `started`, `finished` (jugadores).
- `fr_queue_wait_seconds` (histograma de espera hasta encontrar partida), `fr_matchmaker_tick_seconds`.
- `fr_matches_started_total{filled="bots"|"full"}` (cuota de partidas rellenas con bots), `fr_match_humans_total`, `fr_match_bots_total`, `fr_matches_ranked_total{ranked,reason}`.
- `fr_abandons_total{kind}`: `queue_cancel`, `ready_timeout`, `ready_decline`, `left_match`. `fr_match_start_failures_total{reason}`.
- Gauges: `fr_queue_size`, `fr_pending_matches`, `fr_servers_alive`, `fr_servers_draining`, `fr_open_matches`. `fr_http_requests_total{route,status}`.

Los registros son JSON en la salida estándar; los eventos de cola llevan `event` (`queue_enter`, `match_found`, `ready`, `match_started`, `match_finished`, `strike`, `queue_cancel`, `match_cancelled`). No se registra ninguna IP.

## 8. Herramientas

**`adminctl`** (`go run ./cmd/adminctl`, o `go build ./cmd/adminctl`): `-url`/`$ADMIN_URL`, `-token`/`$ADMIN_TOKEN`.

```
adminctl servers                    servidores, arrendamiento, capacidad, drenaje
adminctl matches [-status assigned] [-limit 50]
adminctl match ID                   una partida con jugadores y resultado
adminctl queue                      cola y partidas esperando confirmación
adminctl annul ID MOTIVO...         anula (revierte los puntos aplicados exactamente)
adminctl ban ID [MOTIVO...] | unban ID
adminctl drain SERVER_ID [off]
adminctl replay [-o archivo] ID     exporta la repetición
```

**`loadbot`** (`go run ./cmd/loadbot -url http://localhost:8080 -n 60 -ramp 20s`): crea N invitados, los pone en cola, confirma, pide el billete y comprueba que describe su asiento. Con `-simulate-server -register-token ... -admin-token ...` además hace de servidor de juego (registro, latidos, resultado de cada partida) y llega a la liquidación. Imprime un informe JSON (esperas p50/p95, tamaños de grupo, partidas con bots, partidas liquidadas, peticiones y 429). Los invitados están limitados por IP (`RATE_GUEST_PER_HOUR`, 10): súbelo en la instancia de pruebas.

## 9. Parámetros

| Variable | Defecto | Significado |
|---|---|---|
| `QUEUE_MAX_WAIT` | 30 | segundos que espera el más antiguo de un grupo de 2 a 5 antes de lanzarse |
| `QUEUE_SOLO_WAIT` | 30 | segundos tras los que un jugador solo corre contra bots |
| `QUEUE_BAND_STEP` | 10 | segundos por división que se ensancha la banda (cualquiera a los 3 pasos) |
| `READY_SECONDS` | 15 | plazo para confirmar |
| `MAX_PING_MS` | 250 | latencia máxima aceptada sin esperar `QUEUE_MAX_WAIT` |
| `MATCHMAKER_TICK` | 1 | segundos entre pasadas (`MATCHMAKER=off` lo desactiva) |
| `PENALTY_FREE_STRIKES`, `PENALTY_BASE`, `PENALTY_MAX` | 2, 5m, 2h | cola de castigo |
| `RATE_QUEUE_PER_MIN`, `RATE_STATUS_PER_MIN` | 20, 90 | límites por cuenta |
| `METRICS_TOKEN` | vacío | token de `/metrics` (16 caracteres o más) |

Las duraciones aceptan `45s`, `2m` o un número de segundos.

## 10. Límites conocidos

- La cola está en un solo proceso (una instancia lógica, como pide §3); no hay reparto entre varias instancias de la API.
- Las llamadas a la base de datos de la pasada (asignar, castigos) se hacen con el cerrojo de la cola tomado: aceptable a cientos de jugadores, a revisar si crece.
- Una partida asignada cuyos jugadores nunca se conectan sigue abierta hasta que ellos llamen a `/match/{id}/leave`, un administrador la anule o el servidor pierda el arrendamiento (`VOID_AFTER`).
- Las colas por hash de simulación (§16.2) solo filtran si el cliente manda `sim_hash`.
- Probado de punta a punta en localhost con el servidor Godot real y clientes Godot reales (`tools/e2e_online.sh`, ver `SPEC_ONLINE.md` "E2E: verificado en localhost"). Falta: navegador, Steam real, TLS y ARM64.
- **Errores de cola**: la penalización es `403 queue_banned` con `retry_after_s` (y `Retry-After`); `429 rate_limited` es solo el límite de tasa. El cliente ya no confunde ambos.
- **Pruebas locales**: `DEV_FAKE_STEAM=1` (solo con `PUBLIC_URL` en localhost) hace que `POST /auth/steam` acepte `{"ticket":"ok-<steamid17>"}`; permite partidas puntuables sin Steam. Con `TRUST_PROXY=true` la /24 sale de `X-Forwarded-For`, así se simulan subredes distintas.
- La API sirve en la raíz (sin `/api`; lo añade Caddy): en local el cliente usa `--api=http://127.0.0.1:PUERTO`. El servidor de juego se registra con `--region=default` (el nombre que usa el cliente) y `--public-url=ws://127.0.0.1:PUERTO`.
