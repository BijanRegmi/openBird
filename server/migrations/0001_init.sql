-- Initial schema. Each migration runs once, in a transaction, in file order.

CREATE TABLE users (
  id            BIGSERIAL PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  display_name  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE organizations (
  id                 BIGSERIAL PRIMARY KEY,
  name               TEXT NOT NULL,
  organization_type  TEXT NOT NULL CHECK (organization_type IN ('personal', 'team')),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE organization_members (
  organization_id  BIGINT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role             TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, user_id)
);

-- Only the SHA-256 of a key is stored; the key itself is shown once.
CREATE TABLE api_keys (
  id            BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  key_hash      TEXT NOT NULL UNIQUE,
  prefix        TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at  TIMESTAMPTZ,
  revoked_at    TIMESTAMPTZ
);

CREATE TABLE apps (
  id               TEXT PRIMARY KEY,
  organization_id  BIGINT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  display_name     TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX apps_organization_idx ON apps (organization_id);

CREATE TABLE channels (
  id          BIGSERIAL PRIMARY KEY,
  app_id      TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (app_id, name)
);

CREATE TABLE releases (
  id                BIGSERIAL PRIMARY KEY,
  app_id            TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  version           TEXT NOT NULL,
  flutter_revision  TEXT NOT NULL,
  flutter_version   TEXT,
  display_name      TEXT,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (app_id, version)
);

-- A release's state on one platform: draft while its artifacts upload,
-- active once `shorebird release` finished.
CREATE TABLE release_platforms (
  release_id    BIGINT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
  platform      TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('draft', 'active')),
  signing_mode  TEXT,
  metadata      JSONB,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (release_id, platform)
);

CREATE TABLE signing_keys (
  id               BIGSERIAL PRIMARY KEY,
  organization_id  BIGINT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  public_key_pem   TEXT NOT NULL,
  -- The private key, AES-256-GCM encrypted under MASTER_KEY.
  private_key_enc  BYTEA NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  retired_at       TIMESTAMPTZ
);
-- At most one current key per organization.
CREATE UNIQUE INDEX signing_keys_current_idx ON signing_keys (organization_id) WHERE retired_at IS NULL;

CREATE TABLE release_artifacts (
  id                 BIGSERIAL PRIMARY KEY,
  release_id         BIGINT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
  platform           TEXT NOT NULL,
  arch               TEXT NOT NULL,
  hash               TEXT NOT NULL,
  size               BIGINT NOT NULL,
  filename           TEXT NOT NULL,
  can_sideload       BOOLEAN NOT NULL DEFAULT false,
  podfile_lock_hash  TEXT,
  signing_mode       TEXT,
  signing_key_id     BIGINT REFERENCES signing_keys(id),
  storage_key        TEXT NOT NULL,
  uploaded_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (release_id, platform, arch)
);

CREATE TABLE patches (
  id                  BIGSERIAL PRIMARY KEY,
  release_id          BIGINT NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
  number              INTEGER NOT NULL,
  channel_id          BIGINT REFERENCES channels(id) ON DELETE SET NULL,
  rollout_percentage  DOUBLE PRECISION,
  is_rolled_back      BOOLEAN NOT NULL DEFAULT false,
  notes               TEXT,
  metadata            JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (release_id, number)
);
CREATE INDEX patches_release_channel_idx ON patches (release_id, channel_id, number DESC);

CREATE TABLE patch_artifacts (
  id                 BIGSERIAL PRIMARY KEY,
  patch_id           BIGINT NOT NULL REFERENCES patches(id) ON DELETE CASCADE,
  platform           TEXT NOT NULL,
  arch               TEXT NOT NULL,
  -- sha256 of the patched snapshot the device ends up with, which the
  -- updater checks after applying the diff (not the hash of the upload).
  hash               TEXT NOT NULL,
  hash_signature     TEXT,
  podfile_lock_hash  TEXT,
  size               BIGINT NOT NULL,
  storage_key        TEXT NOT NULL,
  uploaded_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (patch_id, platform, arch)
);

-- Upload URLs handed to the CLI. The token in the URL is the credential.
CREATE TABLE upload_sessions (
  token          TEXT PRIMARY KEY,
  storage_key    TEXT NOT NULL,
  expected_size  BIGINT,
  -- For release artifacts the CLI sends the sha256 of the file itself.
  expected_hash  TEXT,
  received       BIGINT NOT NULL DEFAULT 0,
  target_kind    TEXT NOT NULL CHECK (target_kind IN ('release_artifact', 'patch_artifact')),
  target_id      BIGINT NOT NULL,
  completed_at   TIMESTAMPTZ,
  expires_at     TIMESTAMPTZ NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE build_runs (
  id          BIGSERIAL PRIMARY KEY,
  app_id      TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  run_id      TEXT NOT NULL,
  command     TEXT NOT NULL,
  platform    TEXT NOT NULL,
  outcome     TEXT NOT NULL,
  payload     JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Events the updater reports from devices. Not foreign-keyed: devices may
-- report for apps or releases that were since deleted.
CREATE TABLE patch_events (
  id                BIGSERIAL PRIMARY KEY,
  event_id          TEXT UNIQUE,
  app_id            TEXT NOT NULL,
  release_version   TEXT NOT NULL,
  patch_number      INTEGER NOT NULL,
  platform          TEXT NOT NULL,
  arch              TEXT NOT NULL,
  client_id         TEXT NOT NULL,
  type              TEXT NOT NULL,
  message           TEXT,
  failure_category  TEXT,
  occurred_at       TIMESTAMPTZ NOT NULL,
  received_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX patch_events_lookup_idx ON patch_events (app_id, release_version, patch_number, type);
