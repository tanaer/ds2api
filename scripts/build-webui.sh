#!/usr/bin/env bash
set -euo pipefail

repo_dir_default="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="${DS2API_DEPLOY_ROOT:-$repo_dir_default}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir)
      [ $# -ge 2 ] || {
        echo "[build-webui] --repo-dir requires a value." >&2
        exit 1
      }
      repo_dir="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/build-webui.sh [--repo-dir <path>]
EOF
      exit 0
      ;;
    *)
      echo "[build-webui] Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

repo_dir="$(cd "$repo_dir" && pwd)"
webui_dir="$repo_dir/webui"
static_index="$repo_dir/static/admin/index.html"

echo "[build-webui] Building WebUI in $repo_dir"

cd "$webui_dir"

if [ ! -d "node_modules" ]; then
  echo "[build-webui] Installing dependencies..."
  npm install
fi

echo "[build-webui] Running build..."
npm run build

if [ ! -f "$static_index" ]; then
  echo "[build-webui] WebUI build failed: $static_index not found" >&2
  exit 1
fi

echo "[build-webui] WebUI built successfully."
echo "[build-webui] Output: $repo_dir/static/admin/"
