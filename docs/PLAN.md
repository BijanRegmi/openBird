# Self-hosted Shorebird code push server: plan

## Goal

Run the whole code push backend ourselves. Developers use the stock,
unmodified `shorebird` CLI. Apps run the stock Shorebird engine and updater.
Both point at our server through `base_url` in `shorebird.yaml`.

**Only remaining Shorebird dependency:** their engine artifacts (the patched
Flutter fork, served from `download.shorebird.dev`, mirrorable through
`SHOREBIRD_DOWNLOAD_URL`) and the CLI's per-engine tools under the same host.
No Shorebird account, auth service, API, console or CDN is involved.

## Facts the design rests on (verified in source, CLI v1.6.140)

| Fact | Where |
|---|---|
| CLI picks its server from `SHOREBIRD_HOSTED_URL`, else `base_url` in shorebird.yaml | `shorebird_cli/lib/src/shorebird_env.dart` `hostedUri` |
| Updater on device uses `base_url` from shorebird.yaml (baked into the app) | `updater/library/src/yaml.rs`, `network.rs` |
| CLI accepts `SHOREBIRD_TOKEN=sb_api_*` and sends it as `Authorization: Bearer` with no auth-service round trip | `shorebird_cli/lib/src/auth/auth.dart` `ApiKeySource` |
| Interactive `shorebird login` is plain OAuth2 (auth code + PKCE loopback, device flow, RFC 7009 revoke) against `AUTH_SERVICE_URL` | `auth/shorebird_oauth.dart` |
| All API routes are `{base}/api/v1/...` | `code_push_client.dart` `apiBaseUri` |
| Every model is generated from Shorebird's `openapi.yaml`; the package resolves as a git dependency | `shorebird_code_push_protocol` |
| Uploads are `multipart` (a POST with field `file`) or `resumable` (GCS-style chunked PUT with `Content-Range`, 308 + `Range`) | `code_push_client.dart` `_uploadArtifact` |
| The CLI downloads release artifacts with an **unauthenticated** client, so download URLs must carry their own signature | `artifact_manager.dart` |
| Managed signing: the server holds an RSA key and signs each patch's `hash` string with RSASSA-PKCS1-v1_5/SHA-256 (base64). The release embeds the public key | `releaser.dart`, `updater/cache/signing.rs` |
| Downloads must support `Range`, must not be gzip-encoded, and need an exact `Content-Length` | `updater/network.rs` |
| Updater events go to `POST /api/v1/patches/events` as `{event:{...}}`. The route is not in openapi.yaml | `updater/events.rs` |
| `x-version` is identical (0.9.0+1) across CLI versions, so it can't select behaviour | `version.dart` |

## Architecture

```
 shorebird CLI ──HTTPS /api/v1──▶ ┌─────────────────────┐ ──▶ Postgres
 (SHOREBIRD_TOKEN=sb_api_…)        │  openbird_server    │
                                   │  (Dart, shelf)      │ ──▶ Object storage
 device updater ──/patches/check─▶ │                     │     (fs | S3 | Azure Blob)
                 ──/patches/events▶└─────────────────────┘
                 ──GET patch──────▶ signed URL (server /files, S3 presigned, Azure SAS)
```

* **Language: Dart.** The server imports `shorebird_code_push_protocol`
  pinned to the exact CLI commit, so request and response bodies use the same
  generated classes the CLI parses. Bumping the pin turns protocol drift into
  compile errors and failing tests.
* **Postgres** for state. Plain SQL migrations in `server/migrations`.
* **Storage interface** with one adapter per backend (`lib/src/storage/`):
  `fs` (served by the server with HMAC-signed, expiring URLs and Range
  support), `s3` (any S3-compatible store, with presigned GETs) and `azure`
  (Azure Blob Storage over its REST API, Shared Key auth, read-only SAS
  downloads). Uploads always enter through the server
  (upload-session URLs), because neither CLI upload method is S3-native.
* **Auth:** API keys (`sb_api_…`). Only the SHA-256 is stored. Users,
  personal orgs and keys are bootstrapped with `bin/admin.dart`.

## Data model

`users`, `organizations` (personal | team), `organization_members` (role),
`api_keys`, `apps` (string id = UUID), `channels`, `releases`
(unique app+version), `release_platforms` (status, signing mode, metadata),
`release_artifacts` (unique release+platform+arch), `patches` (number per
release, channel, rollout %, rolled back flag), `patch_artifacts` (unique
patch+platform+arch, hash, signature), `signing_keys` (per org, private key
AES-GCM encrypted with `MASTER_KEY`), `upload_sessions`, `build_runs`,
`patch_events` (unique `event_id`, for idempotency).

## Patch check algorithm (`POST /api/v1/patches/check`)

1. Find app → release by `(app_id, release_version)`. Missing → `{patch_available:false}`.
2. Candidates: the release's patches on channel `channel` that have an artifact
   for `(platform, arch)` and are not rolled back, newest first.
3. Rollout: a patch at < 100% is offered when
   `bucket(client_id, patch_id) < pct*100`, where bucket = first 4 bytes of
   `sha256("$patch_id:$client_id")` mod 10000. It's deterministic, so a device
   stays in or out of the cohort, and raising the % only adds devices. If the
   newest patch excludes the device, the next one down is tried. No
   `client_id` → only 100% patches.
4. Legacy `patch_number`: when set, only offer a patch numbered higher than it.
   `current_patch_number` never changes the answer.
5. `rolled_back_patch_numbers` = every rolled-back patch number of the release,
   so devices running one revert.
6. `download_url` = a signed URL valid for 24h (the updater resumes partial
   downloads with Range).

Old updaters already in the field (old releases embed old engines) must keep
working, so this endpoint only ever adds optional fields.

## Endpoint scope

The full list, kept by machine, is `protocol/operations.yaml` (every operation
in Shorebird's openapi.yaml plus the client-only and updater-only routes, each
marked `implemented`, `stub` or `unsupported` with a reason). A test fails when
the pinned spec has an operation that file doesn't classify, or when a route
marked `implemented` isn't routed.

MVP `implemented`: users/me, organizations (list/create/get/apps/users),
apps (CRUD), signing-key, channels (CRUD), releases (CRUD, status), release
artifacts (list/create/delete), patches (list/create/update/promote/rollout/
rollback/rollforward), patch artifacts, patch check, patch events, build runs
(recorded), plan/usage (synthetic "self-hosted, unlimited").

`stub` (answers cleanly, so CLI commands degrade gracefully): metrics, audit
logs, notification preferences, invitations lists.

`unsupported` (501 with a clear `ErrorResponse`): enterprises, billing,
App Store Connect credentials, collaborators, service accounts with OIDC trust
rules, GCP diagnostics.

## Protocol tracking (keeping this maintainable)

The contract has three sources. All three are pinned in
`protocol/shorebird.lock`:

1. **CLI ↔ server:** `openapi.yaml`, vendored at the pinned SHA into
   `protocol/openapi.yaml`.
2. **CLI client routes not in the spec** (e.g. `PUT …/rollout`): extracted
   from `code_push_client.dart` into `protocol/client_routes.txt`.
3. **Updater ↔ server:** the request and response structs in
   `updater/library/src/{network,events,yaml}.rs`. Snapshots of those files
   are vendored into `protocol/updater/`, and the contract they define is
   written out in `docs/PROTOCOL.md`.

`tool/sync_protocol.sh <version>`:
1. Resolves the tag to a SHA, fetches the spec, client and updater files at it.
2. Prints a semantic diff of operations and schemas
   (`tool/spec_diff.py`: added, removed and changed operations, plus fields
   added, removed or newly required).
3. Prints a unified diff of the updater structs.
4. Updates the lock, the pubspec git ref and the vendored files.
5. Runs `dart pub get`, `dart analyze` and the test suite.

Guards that catch drift:
* `test/protocol_coverage_test.dart`: every operation in the vendored spec
  and every client route is classified in `operations.yaml`, and everything
  marked `implemented` is routed.
* `test/client_contract_test.dart`: drives the server with Shorebird's own
  `shorebird_code_push_client` (same pinned SHA) through
  init → release → patch → promote → check → rollback.
* `e2e/run.sh`: the real pinned CLI builds a real Android app, releases,
  patches, and an emulator boots the patch. Run before each pin bump is merged.
* CI `protocol-drift.yml`: runs weekly, compares the latest Shorebird tag with
  the pin and fails or flags when they differ, so bumps happen deliberately and
  often.

Upgrade policy: bump the pin often, in small steps (a bump every few CLI
releases is cheap; fifty at once is not). Never remove server behaviour that
an older updater might rely on.

## Build order (today)

1. Repo scaffold, pin, vendored protocol, sync tooling ← started
2. DB schema and migrations, config, storage backends, signing
3. API: auth, users/orgs/apps/channels, releases and artifacts, uploads,
   patches, promote/rollout/rollback, patch check, events, build runs
4. Admin CLI (create user, key)
5. Tests: unit (rollout, signing, patch check), coverage, client contract
6. docker-compose (Postgres, MinIO, server), README
7. E2E: pinned CLI + sample Flutter app + `testlab` emulator: release →
   install → patch → restart → patched UI visible

## Status

Done (2026-11-14):
* Server: protocol MVP, managed signing, uploads, patch check, events, build runs.
* Console: React + Vite + TypeScript + Tailwind in `dashboard/`, served by
  the server from `DASHBOARD_DIR`. Types come from the vendored `openapi.yaml`.
  It calls the same `/api/v1` routes as the CLI. Console-only routes live
  under `/console/v1` (sign-in, API keys, build history, event feed, app
  summary).
* Accounts: email and password (PBKDF2-SHA256) with HttpOnly session cookies.
  Cookie-authenticated writes need `x-openbird-console` (CSRF guard). The
  first account signs up freely; later accounts need an invitation or
  `ALLOW_SIGNUP=true`.
* Members: spec invitations (an existing user is added directly), roles,
  and a guard that keeps at least one owner.
* Metrics: all ten spec metrics operations. Each patch check upserts
  `devices` and an hourly `device_activity` row (keyed by the updater's
  anonymous `client_id`), and install, download and failure counts come from
  `patch_events`.
* One 25 MB image (bun builds the console, Dart AOT builds the server, both
  shipped on `scratch`).

## Later

* OAuth2 auth service for interactive `shorebird login` (endpoints known:
  `/login`, `/token`, `/device_authorization`, `/revoke`). Deprioritised:
  API keys cover the CLI and CI.
* Audit log (the spec operation is stubbed), per-app collaborators, service
  accounts.
* Retention for `device_activity` and `patch_events` (partition by month and
  drop old partitions), and caching patch-check responses per
  release, channel, platform and arch.
* A mirror of `download.shorebird.dev` (Artifactory or a caching proxy) so
  builds survive an outage on their side.
* Signing key rotation and export.
* Code-split the console bundle (charts are the bulk).
