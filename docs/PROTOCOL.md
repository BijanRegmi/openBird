# The protocol this server implements

Pinned in `protocol/shorebird.lock`. One Shorebird CLI version fixes the
whole contract:

| Contract | Source of truth | Vendored as | Guarded by |
|---|---|---|---|
| CLI → API models | `shorebird_code_push_protocol` (generated from `openapi.yaml`) | git dependency at `SHOREBIRD_CLI_SHA` | Dart compiler |
| CLI → API operations | `packages/shorebird_code_push_protocol/openapi.yaml` | `protocol/openapi.yaml` | `test/protocol_coverage_test.dart` |
| CLI-only routes | `packages/shorebird_code_push_client/lib/src/code_push_client.dart` | `protocol/client_routes.txt` | `test/protocol_coverage_test.dart` |
| CLI behaviour | `shorebird_code_push_client` at the same SHA | dev dependency | `test/client_contract_test.dart` |
| Device → API | `updater/library/src/{network,events,yaml}.rs`, `cache/signing.rs` at the `updater_rev` in the Flutter fork's `DEPS` | `protocol/updater/` | this document + `e2e/run.sh` |
| Whole system | the real pinned CLI + engine | `.tools/shorebird` (`tool/install_cli.sh`) | `e2e/run.sh` |

Every operation's handling is listed in `protocol/operations.yaml`.

## Device contract (updater)

These routes outlive any CLI version: every release in users' hands embeds
the updater of the engine it was built with. **Only ever add optional
fields. Never remove or rename anything here.**

### `POST /api/v1/patches/check` (no auth)

Request (JSON; `PatchCheckRequest` in `network.rs`):

| field | notes |
|---|---|
| `app_id`, `channel`, `release_version`, `platform`, `arch` | always sent; `channel` defaults to `stable` |
| `client_id` | random per-install UUID; absent from very old updaters |
| `current_patch_number` | informational; must not change the answer |
| `patch_number` | legacy: only offer patches numbered above it |

Response: `{patch_available, patch?: {number, hash, download_url, hash_signature?}, rolled_back_patch_numbers?}`.

* `hash` is the sha256 of the **patched snapshot** the device ends up with,
  which the updater checks after applying the diff. It is not the hash of the
  downloaded file.
* `hash_signature`: base64 RSASSA-PKCS1-v1_5/SHA-256 over the UTF-8 bytes
  of `hash`, checked against the public key the release embeds
  (`patch_public_key`). If the key is embedded and the signature is missing,
  the device refuses the patch.
* A non-2xx response with a JSON `{code, message}` body is logged on the
  device. A non-JSON error body counts as "not our server".

### Patch download (`download_url`)

* GET, unauthenticated, `Accept-Encoding: identity`. The body must be the
  stored bytes with an exact `Content-Length` (no gzip).
* `Range: bytes=N-` is used to resume, so it must answer 206.
* The URL may be used up to a day after the check (resume after restart).

### `POST /api/v1/patches/events` (no auth)

Body `{"event": {app_id, arch, client_id, type, patch_number, platform,
release_version, timestamp (epoch s), message?, failure_category?, event_id?}}`.
`type` is `__patch_install__`, `__patch_install_failure__`, `__patch_download__`
or `__patch_update_failure__`. Deduplicate on `event_id`. Any 2xx response is
accepted. Must never fail in a way that makes devices retry forever.

### `shorebird.yaml` keys the updater reads

`app_id` (required), `channel`, `base_url` (our server), `auto_update`,
`patch_public_key`.

## CLI contract notes (beyond the spec)

* Auth: `SHOREBIRD_TOKEN=sb_api_…` is sent as `Authorization: Bearer`. The
  CLI checks only the prefix.
* JSON bodies are sent **without** a JSON content type; don't require one.
* Artifact registration (`POST …/artifacts`) is multipart/form-data with
  text fields only. `size` is a string, and `signing` is a JSON string.
* Upload URL: the client does a multipart POST (field `file`) when
  `upload_method` is absent or `multipart`, and GCS-style resumable PUTs
  (8 MiB chunks, `Content-Range`, 308 + `Range`) when it is `resumable`. We
  serve both on every upload URL and advertise `resumable`. Clients that
  predate the field ignore it and POST.
* The authenticated client also sends the bearer token to upload URLs; the
  token in the URL is what authorizes the upload.
* Release artifact `url`s are downloaded **without** credentials, so they're
  signed URLs.
* 409 from `createReleaseArtifact` means "already exists, continue". The
  server lets a draft release's artifacts be replaced; an active release's
  artifacts are final.
* 304 from rollback/rollforward means "already in that state".
* `x-version` is the client package version, which doesn't change between
  CLI releases, so don't branch on it.
* `createBuildRun` failures are ignored by the CLI. We record runs anyway.
* List responses are read as one page (no cursor following on these routes).

## Bumping the pin

```sh
tool/sync_protocol.sh 1.6.141 --check   # read the drift report
tool/sync_protocol.sh 1.6.141           # apply, regenerate, analyze, test
tool/install_cli.sh && e2e/run.sh       # real CLI + emulator
```

Then classify any new operations in `protocol/operations.yaml`. Read the
updater diff against the device contract above. If a device-facing field
changed, update this document and the handler in the same change.
