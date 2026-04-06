#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-ds2api.sh [options]

Update DS2API source, back up the currently deployed program, rebuild artifacts,
restart the systemd service, and verify health.

Options:
  --repo-dir <path>            Repository root (default: repo containing this script)
  --service-name <name>        systemd service name (default: ds2api)
  --backup-root <path>         Backup root directory (default: <repo>/.deploy-backups)
  --version <x.y.z|vx.y.z>     Update to a specific release tag before deploying
  --health-url <url>           Override health check URL
  --health-attempts <count>    Health check attempts after restart (default: 20)
  --skip-update                Skip source update and deploy current checkout directly
  --skip-healthcheck           Skip HTTP health check after service restart
  -h, --help                   Show this help text
EOF
}

log() {
  printf '[deploy-ds2api] %s\n' "$*"
}

die() {
  log "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

read_unit_value() {
  local unit_file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$unit_file" | head -n 1
}

resolve_service_file() {
  local service_name="$1"
  local service_file
  service_file="$(systemctl show -p FragmentPath --value "$service_name" | tr -d '\r')"
  [ -n "$service_file" ] || die "Unable to resolve systemd unit file for $service_name"
  [ -f "$service_file" ] || die "systemd unit file not found: $service_file"
  printf '%s\n' "$service_file"
}

normalize_tag() {
  local value="$1"
  value="${value#refs/tags/}"
  value="$(printf '%s' "$value" | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    die "Version tag is empty."
  fi
  if [[ "$value" != v* ]]; then
    value="v$value"
  fi
  printf '%s\n' "$value"
}

sanitize_name() {
  printf '%s' "$1" | tr '/: ' '---'
}

wait_for_health() {
  local health_url="$1"
  local attempts="$2"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "$health_url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${DS2API_DEPLOY_ROOT:-$(cd "$script_dir/.." && pwd)}"
service_name="ds2api"
backup_root=""
target_version=""
health_url=""
health_attempts=20
skip_update=0
skip_healthcheck=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir)
      [ $# -ge 2 ] || die "--repo-dir requires a value."
      repo_dir="$2"
      shift 2
      ;;
    --service-name)
      [ $# -ge 2 ] || die "--service-name requires a value."
      service_name="$2"
      shift 2
      ;;
    --backup-root)
      [ $# -ge 2 ] || die "--backup-root requires a value."
      backup_root="$2"
      shift 2
      ;;
    --version)
      [ $# -ge 2 ] || die "--version requires a value."
      target_version="$2"
      shift 2
      ;;
    --health-url)
      [ $# -ge 2 ] || die "--health-url requires a value."
      health_url="$2"
      shift 2
      ;;
    --health-attempts)
      [ $# -ge 2 ] || die "--health-attempts requires a value."
      health_attempts="$2"
      shift 2
      ;;
    --skip-update)
      skip_update=1
      shift
      ;;
    --skip-healthcheck)
      skip_healthcheck=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

repo_dir="$(cd "$repo_dir" && pwd)"
[ -d "$repo_dir" ] || die "Repository directory not found: $repo_dir"

require_cmd git
require_cmd go
require_cmd systemctl
require_cmd install
require_cmd cp
require_cmd mkdir
require_cmd ln
if [ "$skip_healthcheck" -eq 0 ]; then
  require_cmd curl
fi

service_file="$(resolve_service_file "$service_name")"
working_directory="$(read_unit_value "$service_file" "WorkingDirectory")"
if [ -z "$working_directory" ]; then
  working_directory="$repo_dir"
fi
working_directory="$(cd "$working_directory" && pwd)"

exec_start="$(read_unit_value "$service_file" "ExecStart")"
binary_path="${exec_start%% *}"
if [ -z "$binary_path" ]; then
  binary_path="$working_directory/ds2api"
elif [[ "$binary_path" != /* ]]; then
  binary_path="$working_directory/$binary_path"
fi

if [ -z "$backup_root" ]; then
  backup_root="$repo_dir/.deploy-backups"
fi
mkdir -p "$backup_root"

if [ -z "$health_url" ]; then
  service_port="$(sed -n 's/^Environment=PORT=//p' "$service_file" | head -n 1 | tr -d '[:space:]')"
  if [ -z "$service_port" ]; then
    service_port="5001"
  fi
  health_url="http://127.0.0.1:${service_port}/healthz"
fi

[ -f "$binary_path" ] || die "Current deployed binary not found: $binary_path"
[ -d "$repo_dir/static/admin" ] || die "Current static/admin not found: $repo_dir/static/admin"
[ -f "$repo_dir/scripts/build-webui.sh" ] || die "WebUI build helper not found: $repo_dir/scripts/build-webui.sh"

current_head="$(git -C "$repo_dir" rev-parse HEAD)"
current_ref="$(git -C "$repo_dir" describe --tags --always 2>/dev/null || printf '%s' "$current_head")"
current_version="unknown"
if [ -f "$repo_dir/VERSION" ]; then
  current_version="$(tr -d '[:space:]' < "$repo_dir/VERSION")"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$backup_root/${timestamp}_$(sanitize_name "$current_ref")"
mkdir -p "$backup_dir/static"

log "Repository: $repo_dir"
log "Service: $service_name"
log "Binary path: $binary_path"
log "Backup directory: $backup_dir"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

build_webui_helper="$tmp_dir/build-webui.sh"
cp "$repo_dir/scripts/build-webui.sh" "$build_webui_helper"
chmod +x "$build_webui_helper"

cp -a "$binary_path" "$backup_dir/ds2api"
cp -a "$repo_dir/static/admin" "$backup_dir/static/admin"
cat > "$backup_dir/metadata.env" <<EOF
BACKUP_CREATED_AT=$timestamp
SERVICE_NAME=$service_name
REPO_DIR=$repo_dir
WORKING_DIRECTORY=$working_directory
BINARY_PATH=$binary_path
SOURCE_HEAD_BEFORE_DEPLOY=$current_head
SOURCE_REF_BEFORE_DEPLOY=$current_ref
VERSION_BEFORE_DEPLOY=$current_version
HEALTH_URL=$health_url
EOF
ln -sfn "$backup_dir" "$backup_root/latest"

if [ "$skip_update" -eq 0 ]; then
  log "Updating source checkout before deployment."
  update_cmd=("$repo_dir/scripts/update-ds2api.sh" --repo-dir "$repo_dir")
  if [ -n "$target_version" ]; then
    update_cmd+=(--version "$target_version")
  fi
  "${update_cmd[@]}"
else
  log "Skipping source update."
fi

log "Building WebUI."
"$build_webui_helper" --repo-dir "$repo_dir"

build_version="$(tr -d '[:space:]' < "$repo_dir/VERSION")"
[ -n "$build_version" ] || die "VERSION file is empty after update."
build_tag="$(normalize_tag "$build_version")"

tmp_binary="$tmp_dir/ds2api"
log "Building backend binary for $build_tag."
(
  cd "$repo_dir"
  go build -ldflags="-s -w -X ds2api/internal/version.BuildVersion=${build_tag}" -o "$tmp_binary" ./cmd/ds2api
)

install -m 755 "$tmp_binary" "$binary_path"

log "Restarting systemd service."
systemctl restart "$service_name"
systemctl is-active --quiet "$service_name" || die "Service did not become active: $service_name"

if [ "$skip_healthcheck" -eq 0 ]; then
  log "Waiting for health check: $health_url"
  wait_for_health "$health_url" "$health_attempts" || die "Health check failed after restart. Run ./scripts/rollback-ds2api.sh to restore the previous program."
fi

target_head="$(git -C "$repo_dir" rev-parse HEAD)"
log "Deploy finished. Backup saved at $backup_dir"
log "Current source HEAD: $target_head"
log "Rollback command: ./scripts/rollback-ds2api.sh --service-name $service_name"
