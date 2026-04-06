#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/rollback-ds2api.sh [options]

Restore the last backed-up DS2API program and restart the systemd service.

Options:
  --repo-dir <path>            Repository root (default: repo containing this script)
  --service-name <name>        systemd service name (default: ds2api)
  --backup-root <path>         Backup root directory (default: <repo>/.deploy-backups)
  --backup <path|name>         Specific backup directory or backup name to restore
  --health-url <url>           Override health check URL
  --health-attempts <count>    Health check attempts after restart (default: 20)
  --skip-healthcheck           Skip HTTP health check after service restart
  -h, --help                   Show this help text
EOF
}

log() {
  printf '[rollback-ds2api] %s\n' "$*"
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
backup_arg=""
health_url=""
health_attempts=20
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
    --backup)
      [ $# -ge 2 ] || die "--backup requires a value."
      backup_arg="$2"
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

require_cmd systemctl
require_cmd install
require_cmd cp
require_cmd mkdir
require_cmd rm
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
[ -d "$backup_root" ] || die "Backup root not found: $backup_root"

if [ -z "$health_url" ]; then
  service_port="$(sed -n 's/^Environment=PORT=//p' "$service_file" | head -n 1 | tr -d '[:space:]')"
  if [ -z "$service_port" ]; then
    service_port="5001"
  fi
  health_url="http://127.0.0.1:${service_port}/healthz"
fi

if [ -n "$backup_arg" ]; then
  if [[ "$backup_arg" = /* ]]; then
    backup_dir="$backup_arg"
  else
    backup_dir="$backup_root/$backup_arg"
  fi
elif [ -L "$backup_root/latest" ] || [ -d "$backup_root/latest" ]; then
  backup_dir="$backup_root/latest"
else
  latest_name="$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1)"
  [ -n "$latest_name" ] || die "No backup directories found in $backup_root"
  backup_dir="$backup_root/$latest_name"
fi

backup_dir="$(readlink -f "$backup_dir")"
[ -d "$backup_dir" ] || die "Backup directory not found: $backup_dir"
[ -f "$backup_dir/ds2api" ] || die "Backup binary not found: $backup_dir/ds2api"
[ -d "$backup_dir/static/admin" ] || die "Backup static/admin not found: $backup_dir/static/admin"

log "Restoring backup from $backup_dir"
install -m 755 "$backup_dir/ds2api" "$binary_path"
rm -rf "$repo_dir/static/admin"
mkdir -p "$repo_dir/static"
cp -a "$backup_dir/static/admin" "$repo_dir/static/admin"

log "Restarting systemd service."
systemctl restart "$service_name"
systemctl is-active --quiet "$service_name" || die "Service did not become active: $service_name"

if [ "$skip_healthcheck" -eq 0 ]; then
  log "Waiting for health check: $health_url"
  wait_for_health "$health_url" "$health_attempts" || die "Health check failed after rollback."
fi

log "Rollback finished."
