-- Persisted per-client model state, so clients resume after a pod restart/redeploy.
-- One row per client_id (the random integer seed the client sends as ?client_id=);
-- the server upserts it on each tick/command and loads every row on startup.
--
--   indices: the full TimelineModel snapshot — each sequence's remembered position,
--            e.g. {"Linear": 12, "Primes": 3, "Fibonacci": 0} (see timeline_model.py).
--   sequence_name: the client's active sequence.
--   playing: whether the server-side ticker is advancing this client.

-- migrate:up
CREATE TABLE timeline.client_state (
    client_id     BIGINT PRIMARY KEY,
    sequence_name TEXT NOT NULL,
    indices       JSONB NOT NULL,
    playing       BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- migrate:down
DROP TABLE timeline.client_state;
