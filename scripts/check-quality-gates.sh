#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Running lint gate"
./scripts/lint.sh

echo "==> Running refactor line gate"
./tests/scripts/check-refactor-line-gate.sh

echo "==> Running unit gates"
./tests/scripts/run-unit-all.sh

echo "==> Running WebUI build gate"
npm run build --prefix webui
