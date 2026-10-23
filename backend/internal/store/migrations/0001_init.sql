-- Fuel Rivals API, schema 1 (docs/SPEC_ONLINE.md 9 and 16.3).
-- Privacy: the SteamID lives only in players.steam_id (nullable, cleared on account deletion); everything else uses
-- player_id. Bans are kept as a salted hash. No IP address is stored anywhere.

CREATE TABLE players (
    player_id     bigserial PRIMARY KEY,
    steam_id      text UNIQUE CHECK (steam_id IS NULL OR steam_id ~ '^[0-9]{17}$'),
    name          text        NOT NULL,
    is_guest      boolean     NOT NULL DEFAULT false,
    banned        boolean     NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    deleted_at    timestamptz,
    CHECK (is_guest = (steam_id IS NULL) OR deleted_at IS NOT NULL)
);

CREATE TABLE guests (
    player_id  bigint PRIMARY KEY REFERENCES players ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);

-- Hash of (salt, steam id) of banned accounts, so a ban survives account deletion without keeping the SteamID.
CREATE TABLE bans (
    steam_hash bytea PRIMARY KEY,
    reason     text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- One active session per player: the unique player_id makes a new login replace the old one.
CREATE TABLE sessions (
    token_hash bytea PRIMARY KEY,
    player_id  bigint      NOT NULL UNIQUE REFERENCES players ON DELETE CASCADE,
    kind       text        NOT NULL CHECK (kind IN ('steam', 'guest')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

-- One-time codes the OpenID return hands to the page (60 s), exchanged for a session by POST.
CREATE TABLE exchange_codes (
    code_hash  bytea PRIMARY KEY,
    player_id  bigint      NOT NULL REFERENCES players ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);

CREATE TABLE openid_nonces (
    nonce   text PRIMARY KEY,
    seen_at timestamptz NOT NULL
);

CREATE TABLE ratings (
    player_id      bigint PRIMARY KEY REFERENCES players ON DELETE CASCADE,
    points         integer          NOT NULL DEFAULT 0 CHECK (points >= 0),
    rating         double precision NOT NULL DEFAULT 1500,
    dev            double precision NOT NULL DEFAULT 350,
    vol            double precision NOT NULL DEFAULT 0.06,
    ranked_matches integer          NOT NULL DEFAULT 0,
    last_match_id  bigint,
    updated_at     timestamptz      NOT NULL DEFAULT now()
);
CREATE INDEX ratings_points_idx ON ratings (points DESC, player_id);

-- Game servers: each has its own key (derived from MASTER_KEY, never stored) and a lease renewed by heartbeats.
CREATE TABLE servers (
    server_id        bigserial PRIMARY KEY,
    name             text        NOT NULL UNIQUE,
    region           text        NOT NULL,
    url              text        NOT NULL,
    capacity         integer     NOT NULL CHECK (capacity >= 0),
    key_version      integer     NOT NULL DEFAULT 1,
    draining         boolean     NOT NULL DEFAULT false,
    active_matches   integer     NOT NULL DEFAULT 0,
    metrics          jsonb       NOT NULL DEFAULT '{}',
    sim_hash         text        NOT NULL DEFAULT '',
    game_version     text        NOT NULL DEFAULT '',
    registered_at    timestamptz NOT NULL DEFAULT now(),
    last_heartbeat   timestamptz,
    lease_expires_at timestamptz
);

CREATE TABLE matches (
    match_id    bigserial PRIMARY KEY,
    server_id   bigint      NOT NULL REFERENCES servers,
    seed        bigint      NOT NULL CHECK (seed >= 0),
    humans      integer     NOT NULL CHECK (humans BETWEEN 1 AND 6),
    bots        integer     NOT NULL DEFAULT 0 CHECK (bots BETWEEN 0 AND 5),
    ranked      boolean     NOT NULL,
    rank_reason text        NOT NULL,
    status      text        NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned', 'settled', 'void', 'annulled')),
    -- released: the server went silent and its players were freed; the match may still be settled if it comes back.
    released    boolean     NOT NULL DEFAULT false,
    game_version text       NOT NULL DEFAULT '',
    sim_hash    text        NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    settled_at  timestamptz,
    result_hash bytea,
    result      jsonb,
    annul_reason text
);
CREATE INDEX matches_open_idx ON matches (server_id) WHERE status = 'assigned';

CREATE TABLE match_players (
    match_id       bigint  NOT NULL REFERENCES matches ON DELETE CASCADE,
    seat           integer NOT NULL CHECK (seat BETWEEN 0 AND 5),
    player_id      bigint  NOT NULL REFERENCES players ON DELETE CASCADE,
    ranked         boolean NOT NULL DEFAULT false, -- scores in this match (not a guest, match ranked)
    abandoned      boolean,
    reported_place integer,
    final_place    integer,
    points_before  integer,
    points_after   integer,
    applied_delta  integer, -- the change actually applied, after the floor of 0; what an annulment reverts
    rating_before  double precision,
    dev_before     double precision,
    vol_before     double precision,
    PRIMARY KEY (match_id, seat),
    UNIQUE (match_id, player_id)
);
CREATE INDEX match_players_player_idx ON match_players (player_id);

-- Players who played together today, to stop farming (a pair that met more than 3 times does not score).
CREATE TABLE pairings (
    day date   NOT NULL,
    a   bigint NOT NULL REFERENCES players ON DELETE CASCADE,
    b   bigint NOT NULL REFERENCES players ON DELETE CASCADE,
    n   integer NOT NULL DEFAULT 1,
    PRIMARY KEY (day, a, b),
    CHECK (a < b)
);
CREATE INDEX pairings_b_idx ON pairings (b);

-- Replays: seed, configuration and the compressed control stream, uploaded by the game server. Partitioned by month
-- (EnsureReplayPartitions creates them ahead); there is no player id in a replay.
CREATE TABLE replays (
    match_id   bigint      NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    format     text        NOT NULL,
    sha256     bytea       NOT NULL,
    data       bytea       NOT NULL,
    PRIMARY KEY (match_id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE replays_default PARTITION OF replays DEFAULT;

CREATE TABLE reports (
    report_id  bigserial PRIMARY KEY,
    reporter   bigint      NOT NULL REFERENCES players ON DELETE CASCADE,
    target     bigint      NOT NULL REFERENCES players ON DELETE CASCADE,
    match_id   bigint,
    reason     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit (
    audit_id  bigserial PRIMARY KEY,
    at        timestamptz NOT NULL DEFAULT now(),
    kind      text        NOT NULL,
    severity  text        NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warn', 'alert')),
    actor     text        NOT NULL DEFAULT '',
    match_id  bigint,
    player_id bigint,
    detail    jsonb       NOT NULL DEFAULT '{}'
);
CREATE INDEX audit_at_idx ON audit (at);
