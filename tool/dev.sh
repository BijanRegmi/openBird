#!/usr/bin/env bash
# Runs the server from source with .env (start dependencies first:
# docker compose up -d postgres).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
cd "$ROOT/server"
exec dart run bin/server.dart
