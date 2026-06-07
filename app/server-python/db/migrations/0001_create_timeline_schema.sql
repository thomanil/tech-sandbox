-- Dedicated schema for this app's tables. Everything the timeline server owns
-- lives under `timeline.` from here on, keeping it out of `public`.

-- migrate:up
CREATE SCHEMA timeline;

-- migrate:down
DROP SCHEMA timeline;
