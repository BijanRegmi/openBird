# Contributing to openBird

Thanks for helping. Issues and pull requests are welcome.

## Setup

```sh
cp .env.example .env && sed -i "s|^MASTER_KEY=$|MASTER_KEY=$(openssl rand -base64 32)|" .env
docker compose up -d postgres s3
(cd server && dart pub get)
(cd dashboard && bun install && bun run build)
tool/dev.sh
```

## Before you open a pull request

```sh
cd server && dart format lib bin test && dart analyze --fatal-infos && dart test
cd dashboard && bun run typecheck && bun run build
```

CI runs the same checks. For changes that touch what devices or the CLI see,
also run `e2e/run.sh` against an emulator (set `DEVICE_PIN` if the emulator
has a lock-screen PIN).

## Protocol changes

openBird follows Shorebird's protocol, pinned in `protocol/shorebird.lock`.
To move to a newer Shorebird release, run `tool/sync_protocol.sh <version>`,
classify any new operations in `protocol/operations.yaml`, and read the
updater diff against [docs/PROTOCOL.md](docs/PROTOCOL.md). Never remove a
field or route that devices already in the field rely on.

## License

By contributing you agree that your contributions are licensed under the
Apache License, Version 2.0.
