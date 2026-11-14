#!/usr/bin/env bash
# Operator commands against the .env database, e.g.
#   tool/admin.sh create-user --email you@example.com
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
cd "$ROOT/server"
exec dart run bin/admin.dart "$@"
