# Fuel Rivals API (backend)

Go service for milestones M3 and M4 of `docs/SPEC_ONLINE.md` (section 16 prevails): accounts, sessions, ranking, match
settlement, replays, game-server registry, signed match tickets, and (M4) the matchmaking queue, ready-check, server
choice, queue penalties, metrics and the operator tools. Standard `net/http` mux, `pgx/v5`, PostgreSQL.
No framework, no `make`: every command below is a plain `go` command. The matchmaking contract and parameters are in
`docs/MATCHMAKING.md` (Spanish).

```
cmd/api/              main: configuration, migrations, graceful shutdown, periodic jobs, the matching loop
cmd/adminctl/         operator CLI: servers, matches, queue, annul, ban/unban, drain, replay export
cmd/loadbot/          headless load test: N guests through queue, ready, join (optionally playing the game server)
internal/config/      environment variables
internal/api/         routes, middleware, rate limits, handlers
internal/matchmaker/  matcher (pure rules), engine (queue, ready-check, penalties), server choice
internal/telemetry/   Prometheus text metrics registry
internal/apiclient/   small JSON client shared by adminctl and loadbot
internal/loadbot/     the load bot and its simulated game server
internal/store/       migrations (embedded SQL) and every query
internal/steam/       ticket verifier, OpenID 2.0, persona names, fakes for tests
internal/ranking/     port of scripts/sim/ranking.gd, ranked-match rules, hidden Glicko-2 rating
internal/ticket/      match tickets (format: docs/TICKET.md)
internal/names/       display name derivation and the insult blocklist
internal/testdb/      a fresh PostgreSQL database per test
testdata/             ranking_tables.json (from Godot), ticket_vectors.json
docs/TICKET.md        the ticket format, byte for byte, for the Godot server
```

## Run the tests

Needs Go 1.26 or newer. The PostgreSQL tests need a server where the user may create databases; they create and drop
one database per test, and are **skipped with a message** if `TEST_DATABASE_URL` is not set or the server does not answer.

```sh
cd backend
go vet ./...
go test ./...                                   # PostgreSQL tests skipped without TEST_DATABASE_URL
TEST_DATABASE_URL='postgres://postgres@localhost:5432/postgres?sslmode=disable' go test -count=1 ./...
```

No installed PostgreSQL? Use a throwaway one:

- Docker: `docker run --rm -d -p 54329:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17`, then
  `TEST_DATABASE_URL='postgres://postgres@localhost:54329/postgres?sslmode=disable'`.
- Windows without admin rights: unzip the binaries from EnterpriseDB (`postgresql-17.x-windows-x64-binaries.zip`),
  then `initdb -D <dir> -U postgres -A trust`, `pg_ctl -D <dir> -o "-p 54329" start`. Same URL as above. Stop it with
  `pg_ctl -D <dir> stop`. Keep the data directory outside the repository.

### Ranking parity with the game

`internal/ranking` has the same tables as `scripts/sim/ranking.gd` and `RACE_POINTS` of `scripts/sim/config.gd`.
Two tests guard it: one compares the Go tables with `testdata/ranking_tables.json`, which the game's own code generates,
and one reads `ranking.gd` and `config.gd` directly when the module sits in the repository. After changing the Godot
tables, regenerate the file and update the Go tables until both tests pass:

```sh
godot --headless --path . -s res://tools/export_ranking_tables.gd     # writes backend/testdata/ranking_tables.json
```

### Ticket vectors

`go test ./internal/ticket/` checks `testdata/ticket_vectors.json`. If the format changes on purpose, regenerate with
`TICKET_UPDATE_VECTORS=1 go test ./internal/ticket/` and update `docs/TICKET.md` and the Godot verifier.

## Run the service

```sh
cd backend
export DATABASE_URL='postgres://postgres@localhost:54329/fuel?sslmode=disable'   # the database must exist
export PUBLIC_URL='http://localhost:8080'  MASTER_KEY="$(openssl rand -hex 32)" BAN_SALT="$(openssl rand -hex 16)"
export ADMIN_TOKEN="$(openssl rand -hex 24)" SERVER_REGISTER_TOKEN="$(openssl rand -hex 24)"
go run ./cmd/api
```

Migrations run at start-up (advisory lock, so several instances are safe). `SIGTERM` drains requests for up to 20 s.

| Variable | Meaning | Default |
|---|---|---|
| `DATABASE_URL` | PostgreSQL URL (required) | |
| `PUBLIC_URL` | origin players use, `https://...` (`http://localhost` allowed for development) | required |
| `API_PREFIX` | where the reverse proxy mounts the API; the OpenID return URL is `PUBLIC_URL + API_PREFIX + /auth/openid/return` | `/api` |
| `LISTEN_ADDR` | | `:8080` |
| `TRUST_PROXY` | `true` behind Caddy: the client address is the last `X-Forwarded-For` entry; otherwise the socket address | `false` |
| `MASTER_KEY` | at least 32 bytes as hex; game server keys are derived from it (never stored) | required |
| `BAN_SALT` | at least 16 characters; salts the ban hashes | required |
| `ADMIN_TOKEN` | bearer token of `/admin/*` (at least 24 characters) | required |
| `SERVER_REGISTER_TOKEN` | bearer token for `POST /servers/register` (at least 24 characters) | required |
| `STEAM_PARTNER_API_KEY`, `STEAM_APP_ID`, `STEAM_TICKET_IDENTITY` | `ISteamUserAuth/AuthenticateUserTicket` on `partner.steam-api.com`; identity default `fuelrivals`. Without the key `POST /auth/steam` answers 503 | |
| `STEAM_WEB_API_KEY` | `GetPlayerSummaries` for the persona name. Without it names fall back to `P` + 4 digits | |
| `SESSION_TTL`, `GUEST_TTL` | | `24h`, `168h` |
| `LEASE_TTL`, `VOID_AFTER` | game server lease; silent matches are voided without settling after this | `30s`, `6h` |
| `RATE_LOGIN_PER_MIN`, `RATE_GUEST_PER_HOUR`, `RATE_ACCOUNT_PER_MIN` | per IP on `/auth/*`, guests created per IP, requests per account | `20`, `10`, `120` |
| `RATE_QUEUE_PER_MIN`, `RATE_STATUS_PER_MIN` | per account: `POST/DELETE /queue` and `/queue/ready`; `GET /queue/status` | `20`, `90` |
| `QUEUE_MAX_WAIT`, `QUEUE_SOLO_WAIT`, `QUEUE_BAND_STEP`, `READY_SECONDS` | queue timers (seconds or a duration such as `45s`): a group of 2 to 5 launches when its oldest ticket has waited `QUEUE_MAX_WAIT`; a lone human gets bots after `QUEUE_SOLO_WAIT`; the band grows one division per `QUEUE_BAND_STEP`; time to confirm a found match | `30`, `30`, `10`, `15` |
| `MAX_PING_MS` | the best server above this latency is accepted only after `QUEUE_MAX_WAIT` | `250` |
| `MATCHMAKER_TICK`, `MATCHMAKER` | loop interval; `MATCHMAKER=off` disables the loop | `1s`, on |
| `PENALTY_FREE_STRIKES`, `PENALTY_BASE`, `PENALTY_MAX` | queue ban for repeat leavers: free strikes per day, first ban, longest ban | `2`, `5m`, `2h` |
| `METRICS_TOKEN` | bearer token of `GET /metrics` (16+ characters); without it `/metrics` answers 404 | |
| `REPLAY_MAX_BYTES` | | `262144` |
| `LOG_LEVEL` | `debug`, `info`, `warn`, `error`; logs are JSON on stdout | `info` |

## API

JSON in and out; SteamIDs, player ids and match ids are **strings**. Errors: `{"error": "code", "message": "..."}`.
Player endpoints take `Authorization: Bearer <session token>`; game servers send `X-Server-Id` and
`Authorization: Bearer <server key hex>`; `/admin/*` takes `ADMIN_TOKEN`.

| Endpoint | Who | What |
|---|---|---|
| `POST /auth/steam` `{ticket}` | desktop client | Steam auth ticket (hex) to session. 401 invalid ticket, 403 banned, 503 Steam unavailable |
| `GET /auth/openid/start` | browser | redirect to Steam; sets the `__Host-fr_oid` state cookie |
| `GET /auth/openid/return` | browser | verifies the assertion, redirects to `PUBLIC_URL/#code=<one-time code>` (or `#login_error=<code>`) |
| `POST /auth/exchange` `{code}` | page | the 60 s one-time code to a session |
| `POST /auth/guest` | web | unranked guest, 7-day token, limited per IP |
| `POST /auth/logout` | player | ends the session |
| `GET /me` | player | name, points, division, rank, provisional flag |
| `POST /account/delete` `{"confirm":"DELETE"}` | player | erases the account (409 while in an open match) |
| `GET /account/export` | player | all stored data of the account, as JSON |
| `POST /reports` | player | report a player |
| `GET /leaderboard?limit=` | public | best accounts, 1 to 100, ties share a rank |
| `POST /servers/register` | operator (`SERVER_REGISTER_TOKEN`) | registers a game server, returns its key once; the same name again rotates the key |
| `POST /servers/heartbeat` | game server | renews the lease; capacity, `draining`, metrics. Reply: `{ok, lease_seconds, drain, capacity, assigned_matches, free}`; `drain: true` means an operator asked the server to drain (finish its rooms, accept none) |
| `POST /queue` `{latencies:{region:ms}}` | player | enters the queue, `{queue_id}`. 403 `queue_banned`, 409 `busy`, 429 |
| `GET /queue/status` | player | `{state: idle/waiting/found/ready/starting, wait_s, band_divisions, players_found, match:{match_id, ready_deadline_unix}}` |
| `POST /queue/ready` `{match_id}` | player | confirms a found match |
| `DELETE /queue` | player | leaves the queue; after a match was found it declines it (a strike) |
| `GET /match/{id}/join` | player | `{ws_url, ticket}`, the ticket of `docs/TICKET.md`, 60 s from the first request |
| `POST /match/{id}/leave` | player | leaves the match (an abandon if a ticket was issued); a match everybody left becomes void |
| `GET /metrics` | `METRICS_TOKEN` | Prometheus text: funnel, wait times, abandons, bot-filled share, queue and server gauges |
| `POST /matches/{id}/result` | game server | placements and abandons of the assigned humans |
| `POST /matches/{id}/replay` | game server | compressed replay as the body, `X-Replay-Format` header |
| `POST /admin/matches` | admin | records a match by hand and returns each human's signed ticket (the queue does this by itself now) |
| `GET /admin/matches?status=&limit=`, `GET /admin/matches/{id}`, `GET .../replay` | admin | list, inspect (with `player_ids`), export the replay |
| `POST /admin/matches/{id}/annul` `{reason}` | admin | reverts exactly the applied deltas |
| `POST /admin/players/{id}/ban` `{reason}`, `POST .../unban` | admin | ban, lift the ban and the queue penalty |
| `GET /admin/servers`, `POST /admin/servers/{id}/drain` `{drain}` | admin | servers with lease and capacity; drain or undrain |
| `GET /admin/queue` | admin | who is waiting, matches waiting for confirmations, the timers |
| `GET /healthz`, `GET /readyz` | probes | liveness, database check |

Result body: `{"players":[{"player_id":"12","place":1,"abandoned":false}, ...]}` with the places among all cars (1 to 6);
the server cannot send points, SteamIDs or anything else (unknown fields are refused).

## Decisions

- **Hidden rating: Glicko-2.** It has an explicit deviation, which gives the provisional period (fewer than 10 ranked
  matches or deviation above 110) without extra state, and a published worked example that a test reproduces. A
  race is rated as pairwise games between the scoring humans. The hidden rating does not change the visible points; it
  is stored for the matchmaker (M4) to pick opponents and is never sent to players (`json:"-"`).
- **Ranked or not is decided when the match is assigned**, not when it ends, so players know before racing: at
  least 2 scoring humans (Steam accounts; guests never score and are ignored by the rule), all within 2 divisions of
  each other by division number, no two from the same /24 (the matchmaker passes `ip_prefix`; it is used in memory
  and never stored), and no pair meeting for the 4th time in a UTC day. Otherwise the match is played with no points
  and `rank_reason` says why.
- **Settlement.** The API ranks the scoring humans among themselves from the reported places, puts leavers last (each
  gets the last-place change of the table for the number of humans), reads the delta from the table for that number
  of humans (2 to 6), applies the floor of 0 and stores the delta actually applied. The remaining human of a 2-human
  match therefore wins. First result wins; the same one again is a no-op (200, `already_settled`); a different one is
  409 plus an `alert` row in `audit`.
- **Annulment** subtracts exactly the stored applied delta (never below 0). Hidden ratings are restored if no later
  ranked match touched the account. An open match becomes `void`.
- **Server keys are derived, not stored**: `HMAC-SHA256(MASTER_KEY, "fuel-rivals/server-key/v1\0" || server_id || be32(key_version))`.
  The key signs tickets and authenticates the server. Registering the same server name again rotates it.
- **Leases.** A heartbeat renews the lease. When it lapses the server's open matches are marked `released` (their
  players can be assigned again); after `VOID_AFTER` they are voided without settling. A late result for a released
  match is still accepted until it is voided.
- **Privacy.** The SteamID is stored only in `players.steam_id` (null after deletion). Bans keep only a salted hash.
  No IP address is stored or logged. Account deletion removes sessions, ratings, match history, reports, pairings and
  audit references and leaves an anonymous tombstone row.
- **Sessions** are 256-bit random tokens, stored as SHA-256 hashes; a player has one active session (a new login ends
  the old one). The OpenID return hands the page a one-time 60 s code in the URL fragment, never the session.

## Matchmaking (M4)

Details, contract and parameters: `docs/MATCHMAKING.md`. In short: tickets in memory, a pass every second (sort by
points, band of 1 division widening by 1 per 10 s to any at 30 s, groups of up to 6, launch at 6 or when the oldest of
2 to 5 waited `QUEUE_MAX_WAIT`, a lone human gets bots after `QUEUE_SOLO_WAIT`), a 15 s ready-check, the server with the
lowest maximum latency that has free capacity and a live lease, bots fill the field to 6, ranked or not decided by
`store.AssignMatch` at assignment, strikes and escalating queue bans in memory and in `leave_strikes`. The match id is
reserved when a match is found (`ReserveMatchID`) and used by the assignment. IO of a pass runs with the queue lock held,
which is fine at hundreds of players.

```sh
go run ./cmd/adminctl -url http://localhost:8080 -token "$ADMIN_TOKEN" servers
go run ./cmd/loadbot -url http://localhost:8080 -n 60 -ramp 20s -simulate-server \
  -register-token "$SERVER_REGISTER_TOKEN" -admin-token "$ADMIN_TOKEN"     # raise RATE_GUEST_PER_HOUR on that instance
```

Tests: `internal/matchmaker` (synthetic queues of 1, 2, 5, 30 and 100 players with an injectable clock, ready-check
paths, server choice, penalties; no database), `internal/api/queue_test.go` (HTTP contract, end to end to settlement,
rate limits, drain, bans; PostgreSQL), `internal/api/loadbot_test.go` (the load bot against the API with the loop
running), `internal/store/queue_test.go`, `cmd/adminctl`.

## Not in this milestone

WebRTC, the replay re-simulation job, seasons, several API instances sharing one queue, and the real Godot game server
and client talking to these endpoints (the game server side is simulated in tests).
