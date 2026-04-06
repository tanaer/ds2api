#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REMOTE_URL="https://github.com/CJackHwang/ds2api.git"
DEFAULT_RELEASE_API_URL="https://api.github.com/repos/CJackHwang/ds2api/releases/latest"

usage() {
  cat <<'EOF'
Usage: ./scripts/update-ds2api.sh [options]

Update the current DS2API source checkout to an official release tag.

Options:
  --version <x.y.z|vx.y.z>   Update to a specific release tag instead of latest
  --repo-dir <path>          Override repository root (default: repo containing this script)
  --remote-url <url>         Override upstream git remote URL
  --release-api-url <url>    Override latest release API URL
  --no-stash                 Refuse to update when the worktree is dirty
  --dry-run                  Print planned commands without mutating the repo
  -h, --help                 Show this help text
EOF
}

log() {
  printf '[update-ds2api] %s\n' "$*"
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

normalize_tag() {
  local raw="$1"
  raw="${raw#refs/tags/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [ -z "$raw" ]; then
    die "Resolved release tag is empty."
  fi
  if [[ "$raw" != v* ]]; then
    raw="v$raw"
  fi
  printf '%s\n' "$raw"
}

resolve_latest_tag() {
  local response
  response="$(curl -fsSL "$release_api_url")"
  local tag
  tag="$(
    printf '%s\n' "$response" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  )"
  normalize_tag "$tag"
}

print_cmd() {
  printf '[dry-run] '
  printf '%q ' "$@"
  printf '\n'
}

run_cmd() {
  if [ "$dry_run" -eq 1 ]; then
    print_cmd "$@"
    return 0
  fi
  "$@"
}

restore_stash() {
  local exit_code=$?
  if [ "$stash_pushed" -eq 1 ]; then
    log "Restoring stashed local changes."
    if ! git -C "$repo_dir" stash pop --index >/dev/null; then
      log "Update applied, but restoring the auto-stash failed. Please check 'git stash list' manually." >&2
      exit_code=1
    fi
  fi
  exit "$exit_code"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${DS2API_UPDATE_ROOT:-$(cd "$script_dir/.." && pwd)}"
repo_dir="$(cd "$repo_dir" && pwd)"
target_version=""
remote_url="$DEFAULT_REMOTE_URL"
release_api_url="$DEFAULT_RELEASE_API_URL"
dry_run=0
auto_stash=1
stash_pushed=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version requires a value."
      target_version="$2"
      shift 2
      ;;
    --repo-dir)
      [ $# -ge 2 ] || die "--repo-dir requires a value."
      repo_dir="$2"
      shift 2
      ;;
    --remote-url)
      [ $# -ge 2 ] || die "--remote-url requires a value."
      remote_url="$2"
      shift 2
      ;;
    --release-api-url)
      [ $# -ge 2 ] || die "--release-api-url requires a value."
      release_api_url="$2"
      shift 2
      ;;
    --no-stash)
      auto_stash=0
      shift
      ;;
    --dry-run)
      dry_run=1
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

require_cmd git
if [ -z "$target_version" ]; then
  require_cmd curl
fi

git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Target directory is not a git worktree: $repo_dir"

branch_name="$(git -C "$repo_dir" branch --show-current | tr -d '[:space:]')"
[ -n "$branch_name" ] || die "Detached HEAD is not supported. Please switch to a branch first."

dirty_status="$(git -C "$repo_dir" status --porcelain --untracked-files=all)"

if [ -n "$target_version" ]; then
  target_tag="$(normalize_tag "$target_version")"
else
  target_tag="$(resolve_latest_tag)"
fi

log "Repository: $repo_dir"
log "Branch: $branch_name"
log "Target tag: $target_tag"

if [ -n "$dirty_status" ] && [ "$auto_stash" -eq 0 ]; then
  die "Detected uncommitted changes. Re-run without --no-stash or clean the worktree first."
fi

trap restore_stash EXIT

if [ -n "$dirty_status" ]; then
  stash_name="ds2api-auto-update-$(date -u +%Y%m%dT%H%M%SZ)"
  log "Detected uncommitted changes, stashing before update."
  run_cmd git -C "$repo_dir" stash push --include-untracked --message "$stash_name" >/dev/null
  if [ "$dry_run" -eq 0 ]; then
    stash_pushed=1
  fi
fi

run_cmd git -C "$repo_dir" fetch "$remote_url" "refs/tags/$target_tag:refs/tags/$target_tag"
run_cmd git -C "$repo_dir" merge --ff-only "$target_tag"

log "Update flow finished."
