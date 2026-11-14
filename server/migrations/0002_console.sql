-- Console: password sign-in, sessions, invitations, and device activity
-- recorded from patch checks (the source of the metrics endpoints).

ALTER TABLE users ADD COLUMN password_hash TEXT;

CREATE TABLE sessions (
  token_hash  TEXT PRIMARY KEY,
  user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL
);
CREATE INDEX sessions_user_idx ON sessions (user_id);

CREATE TABLE invitations (
  id               UUID PRIMARY KEY,
  organization_id  BIGINT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email            TEXT NOT NULL,
  role             TEXT NOT NULL,
  inviter_id       BIGINT REFERENCES users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ NOT NULL,
  -- accepted, declined or revoked; NULL while pending.
  resolution       TEXT,
  resolved_at      TIMESTAMPTZ
);
CREATE INDEX invitations_email_idx ON invitations (lower(email)) WHERE resolution IS NULL;

-- One row per install (client_id is the updater's random per-install id).
CREATE TABLE devices (
  app_id           TEXT NOT NULL,
  client_id        TEXT NOT NULL,
  first_seen       TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen        TIMESTAMPTZ NOT NULL DEFAULT now(),
  release_version  TEXT NOT NULL,
  platform         TEXT NOT NULL,
  arch             TEXT NOT NULL,
  patch_number     INTEGER,
  PRIMARY KEY (app_id, client_id)
);
CREATE INDEX devices_app_seen_idx ON devices (app_id, last_seen);

-- At most one row per install per hour: enough for unique users, active
-- hours, heatmaps and adoption curves without storing every check.
CREATE TABLE device_activity (
  app_id           TEXT NOT NULL,
  client_id        TEXT NOT NULL,
  hour             TIMESTAMPTZ NOT NULL,
  release_version  TEXT NOT NULL,
  platform         TEXT NOT NULL,
  patch_number     INTEGER,
  PRIMARY KEY (app_id, hour, client_id)
);
