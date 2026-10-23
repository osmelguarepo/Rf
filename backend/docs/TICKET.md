# Match ticket format (version 1)

A match ticket proves to a game server that the API assigned a player a seat in a match. The API signs it with the
target server's key; the client carries it as an opaque string in the `ticket` field of the `HELLO` message
(`scripts/net/protocol.gd`, printable ASCII, at most 16 KB; a ticket is about 190 characters). The game server verifies it
with the same key and never contacts the API to do so.

Reference implementation: `backend/internal/ticket/ticket.go`. Test vectors: `backend/testdata/ticket_vectors.json`.
If the code and this document disagree, fix the code or the document and regenerate the vectors
(`TICKET_UPDATE_VECTORS=1 go test ./internal/ticket/`).

## Wire form

```
ticket = base64url(payload || mac)        RFC 4648 section 5, alphabet A-Z a-z 0-9 - _, NO padding
mac    = HMAC-SHA256(key, payload)        32 bytes
key    = the server's 32-byte key (see "Key")
```

Decode strictly: reject `=`, characters outside the alphabet, and a final character whose unused bits are not zero.
After decoding, the last 32 bytes are the MAC and the rest is the payload.

## Payload

All integers are big endian. A "string" is one length byte `n` (0 to 64) followed by `n` bytes of ASCII.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `version` | `1`. Anything else: reject. |
| 1 | 1 | `flags` | bit 0 = guest (no SteamID). All other bits must be 0. |
| 2 | 1 | `seat` | 0 to 5. |
| 3 | 8 | `seed` | unsigned, must be below 2^63 (so it is also a valid signed 64-bit integer). The match seed. |
| 11 | 8 | `expires` | unix time in seconds, below 2^63. Valid while `now <= expires`. The API issues `now + 60`. |
| 19 | 1+n | `server_id` | string, 1 to 64 printable ASCII (0x21 to 0x7e). The server the ticket is for. |
| .. | 1+n | `match_id` | string, decimal digits, 1 to 19 (the API's match id). |
| .. | 1+n | `player_id` | string, decimal digits, 1 to 19 (the API's internal player id). |
| .. | 1+n | `steam_id` | string, exactly 17 decimal digits, or empty when the guest flag is set. |
| .. | 1+n | `name` | string, 0 to 8 characters from `A-Z0-9`: the display name of the seat. |

There is nothing after `name`. The `guest` flag must be set if and only if `steam_id` is empty. IDs are text on purpose:
a SteamID does not fit in a double (GDScript `float`, JSON number) without losing digits, and the seed and match id are
kept as text in JSON for the same reason. In GDScript read the 8-byte fields with `PackedByteArray.decode_s64()` after
reversing, or by hand (`PackedByteArray` decodes little endian), and compare strings, never floats.

## Verification (what a game server must do)

1. Decode as above. Fewer than 19 + 5 + 32 bytes: reject. Parse the fields exactly; any leftover or missing byte: reject.
2. `version == 1`, no unknown flag bits, `seat <= 5`, `guest flag <=> steam_id is empty`, field syntax as in the table.
3. Compute `HMAC-SHA256(key, payload)` and compare with the MAC in **constant time**. Mismatch: reject.
4. `server_id` equals this server's own id. (A ticket for another server fails the MAC anyway, because keys differ; this
   gives a clearer error.)
5. `now <= expires`, with `now` the server's UNIX clock. Check the clock is NTP-synchronised; the 60 s window is short.
6. One use: the first valid `HELLO` for `(match_id, seat)` binds the seat to that connection; later tickets for the same
   seat are refused while it is bound (spec 16.2: the first valid `HELLO` creates the room). The API never reissues a
   ticket for a seat that is not yet bound.
7. The ticket fixes the room: `match_id`, `seed` and the seat of `player_id`. The other seats come from the other
   players' tickets as they arrive (or from the API when it sends the player list; see the matchmaking milestone).

## Key

Every game server has its own 32-byte key, created at registration (`POST /servers/register`) and returned once as 64
lower-case hex characters. The HMAC key is the **32 decoded bytes**, not the hex text. In GDScript:
`var key: PackedByteArray = key_hex.hex_decode()` and
`var tag := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, key, payload)`. The key is also what authenticates the
server to the API (`Authorization: Bearer <hex>`), so keep it in an environment variable or a file with mode 600, never in
the repository or the client.

The API does not store keys: it derives them (`HMAC-SHA256(master, "fuel-rivals/server-key/v1\0" || server_id || be32(key_version))`),
so a copy of the database does not leak them. Rotating a key means registering the same server name again.

## Test vectors

`backend/testdata/ticket_vectors.json`:

```
{ "key_hex": "...", "vectors": [ { "name", "server_id", "match_id", "seat", "player_id", "steam_id", "display_name",
    "seed" (text), "expires", "payload_hex", "mac_hex", "ticket", "valid", "error", "now" } ] }
```

For every vector the Godot implementation must (a) parse `ticket` and get the fields back, (b) rebuild `payload_hex` and
`mac_hex` from the fields when `valid` is true, and (c) accept the ticket at `now` exactly when `valid` is true. The invalid
vectors are one second after expiry (`expired`) and a changed character inside the signature (`bad signature`).
