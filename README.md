# openBird

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Self-hosted over-the-air updates for Flutter. openBird is an open-source
server and web console that speaks Shorebird's code push protocol.
You keep the stock `shorebird` CLI and the Shorebird engine. Patches, apps,
releases, signing keys, rollouts and device metrics live on your own
infrastructure.

The only thing still fetched from Shorebird is their engine build (the
patched Flutter fork and its tools from `download.shorebird.dev`). You can
mirror it with `SHOREBIRD_DOWNLOAD_URL`.

> openBird is an independent project, not affiliated with or endorsed by
> Shorebird. It works with Shorebird's open-source CLI and engine; see
> [NOTICE](NOTICE).

* [docs/PLAN.md](docs/PLAN.md): design, decisions, roadmap
* [docs/PROTOCOL.md](docs/PROTOCOL.md): the contract, and how it's kept in step with Shorebird
* [protocol/operations.yaml](protocol/operations.yaml): every API operation and how it's handled

## Run it

One image (25 MB, from scratch) holds the server and the web console:

```sh
export MASTER_KEY=$(openssl rand -base64 32)   # keep it safe, see below
docker compose up -d                           # postgres + server (+ console) on :8080
```

Open http://localhost:8080 and create the first account. The first account
can always sign up. After that, people join by invitation, or you set
`ALLOW_SIGNUP=true`. CLI and CI use API keys you create in the console
(**API keys**).

For development, run from source:

```sh
cp .env.example .env && sed -i "s|^MASTER_KEY=$|MASTER_KEY=$(openssl rand -base64 32)|" .env
docker compose up -d postgres
(cd dashboard && bun install && bun run build)
tool/dev.sh                                           # server + console on :8080
tool/admin.sh create-user --email you@example.com     # or sign up in the console
cd dashboard && bun run dev                           # console with hot reload on :5173
```

`docker compose exec -T postgres psql -U openbird -v org=1 < tool/seed_demo.sql`
adds a "Demo Store" app with 45 days of synthetic devices, so you can look
around the charts.

**Back up `MASTER_KEY`.** It encrypts the managed patch-signing keys. Lose it
and the releases in the field can't verify any new patch.

## The console

* **Apps**: create, rename and delete apps, with the `shorebird.yaml` snippet for each.
* **Releases**: per-platform status and signing, artifacts with signed
  downloads, release notes, and delete.
* **Patches**: promote to a channel at a rollout percentage, raise the
  rollout (it only goes up), roll back and restore, and notes. Charts show
  installs by patch and adoption.
* **Channels**: what each channel serves for each release.
* **Insights**: active installs by platform or release, version distribution,
  new installs, active hours (with the quietest rollout window) and a weekly
  heatmap.
* **Device events**: a live feed of installs, downloads and failures, with
  failure categories.
* **Build history**: every `shorebird release`/`patch` run, with outcome,
  duration and environment.
* **Organizations**: team organizations, members and roles, invitations,
  usage, personal API keys, and light and dark themes.

Device metrics come from patch checks (the updater's anonymous per-install
`client_id`) and the events the updater reports.

## Use it from a Flutter app

```sh
export SHOREBIRD_TOKEN=sb_api_…                       # your key
SHOREBIRD_HOSTED_URL=https://openbird.example.com shorebird init
echo "base_url: https://openbird.example.com" >> shorebird.yaml
shorebird release android
shorebird patch android
shorebird patches rollback --release-version 1.0.0+1 --patch-number 1
```

`base_url` in `shorebird.yaml` points both the CLI and every installed app at
this server. It's baked into the release, so pick a URL you'll keep.

## Develop

```sh
cd server && dart test        # unit, protocol coverage, client contract, console (needs postgres)
cd dashboard && bun run typecheck && bun run build
e2e/run.sh                    # real CLI + real app on an emulator
tool/sync_protocol.sh <ver> --check   # protocol drift against a newer Shorebird
```

The pinned Shorebird version is in `protocol/shorebird.lock`. `tool/install_cli.sh`
installs exactly that CLI into `.tools/`, so a global Shorebird install is
never touched.

## Layout

| Path | What |
|---|---|
| `server/` | The Dart server: Shorebird's protocol, the console API, migrations, tests |
| `dashboard/` | The web console (React, Vite, TypeScript, Tailwind) |
| `protocol/` | The pinned Shorebird contract and how each operation is handled |
| `tool/` | Dev scripts, admin CLI wrapper, protocol sync, demo seed |
| `e2e/` | End-to-end test: real CLI, real Flutter app, emulator |
| `deploy/` | Config for the local S3-compatible store |

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities
privately, as described in [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
