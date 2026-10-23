-- Schema 2: matchmaking (docs/SPEC_ONLINE.md 7 and 16, docs/MATCHMAKING.md).

-- An operator asks a game server to drain (adminctl). The heartbeat reply passes it on; a server's own drain flag
-- (the heartbeat body) is kept in draining. The effective state is draining (the heartbeat stores the OR of both).
ALTER TABLE servers ADD COLUMN drain_requested boolean NOT NULL DEFAULT false;

-- When the API handed the player a ticket for the match, and when the player told the API they left.
ALTER TABLE match_players ADD COLUMN join_issued_at timestamptz;
ALTER TABLE match_players ADD COLUMN left_at timestamptz;

-- Queue penalty counters for players who leave after a match was found or while it runs.
-- strikes decays: a strike older than 24 hours does not count (see matchmaker.NextPenalty).
CREATE TABLE leave_strikes (
    player_id    bigint      PRIMARY KEY REFERENCES players ON DELETE CASCADE,
    strikes      integer     NOT NULL DEFAULT 0,
    last_at      timestamptz NOT NULL,
    banned_until timestamptz
);
