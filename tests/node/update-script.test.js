'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const scriptPath = path.resolve(__dirname, '../../scripts/update-ds2api.sh');

function writeExecutable(filePath, content) {
  fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function makeFakeGit(binDir) {
  writeExecutable(
    path.join(binDir, 'git'),
    `#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="\${FAKE_GIT_LOG:?}"
STATUS_OUTPUT="\${FAKE_GIT_STATUS:-}"
BRANCH_NAME="\${FAKE_GIT_BRANCH:-main}"

if [ "\${1:-}" = "-C" ]; then
  shift 2
fi

printf '%s\\n' "$*" >> "$LOG_FILE"

cmd="\${1:-}"
shift || true

case "$cmd" in
  rev-parse)
    if [ "\${1:-}" = "--is-inside-work-tree" ]; then
      echo true
      exit 0
    fi
    ;;
  branch)
    if [ "\${1:-}" = "--show-current" ]; then
      printf '%s\\n' "$BRANCH_NAME"
      exit 0
    fi
    ;;
  status)
    printf '%s' "$STATUS_OUTPUT"
    exit 0
    ;;
  stash)
    subcmd="\${1:-}"
    case "$subcmd" in
      push)
        echo "stash-pushed" > "\${FAKE_GIT_STASH_FLAG:?}"
        exit 0
        ;;
      pop)
        if [ ! -f "\${FAKE_GIT_STASH_FLAG:?}" ]; then
          echo "no stash entry" >&2
          exit 1
        fi
        rm -f "\${FAKE_GIT_STASH_FLAG:?}"
        exit 0
        ;;
    esac
    ;;
  fetch|merge)
    exit 0
    ;;
esac

echo "unsupported fake git invocation: $cmd $*" >&2
exit 1
`,
  );
}

function makeFakeCurl(binDir) {
  writeExecutable(
    path.join(binDir, 'curl'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s' "\${FAKE_CURL_BODY:-{\\"tag_name\\":\\"v3.1.1\\"}}"
`,
  );
}

function setupHarness(options = {}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ds2api-update-test-'));
  const repoDir = path.join(tempDir, 'repo');
  const binDir = path.join(tempDir, 'bin');
  const gitLogPath = path.join(tempDir, 'git.log');
  const stashFlagPath = path.join(tempDir, 'stash.flag');

  fs.mkdirSync(repoDir, { recursive: true });
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(path.join(repoDir, 'VERSION'), options.versionFile || '3.1.0\n');

  makeFakeGit(binDir);
  makeFakeCurl(binDir);

  return {
    repoDir,
    gitLogPath,
    stashFlagPath,
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH}`,
      DS2API_UPDATE_ROOT: repoDir,
      FAKE_GIT_LOG: gitLogPath,
      FAKE_GIT_STASH_FLAG: stashFlagPath,
      FAKE_GIT_STATUS: options.gitStatus || '',
      FAKE_GIT_BRANCH: options.gitBranch || 'main',
      FAKE_CURL_BODY: options.curlBody || '{"tag_name":"v3.1.1"}',
    },
  };
}

function readGitLog(logPath) {
  if (!fs.existsSync(logPath)) {
    return [];
  }
  return fs
    .readFileSync(logPath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

test('update script resolves latest release tag in dry-run mode', () => {
  const harness = setupHarness();
  const result = spawnSync('bash', [scriptPath, '--dry-run'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Target tag:\s+v3\.1\.1/);
  assert.match(result.stdout, /git -C .* fetch .*refs\/tags\/v3\.1\.1:refs\/tags\/v3\.1\.1/);
  assert.match(result.stdout, /git -C .* merge --ff-only v3\.1\.1/);

  const gitLog = readGitLog(harness.gitLogPath);
  assert.ok(gitLog.includes('rev-parse --is-inside-work-tree'));
  assert.ok(gitLog.includes('branch --show-current'));
  assert.ok(gitLog.includes('status --porcelain --untracked-files=all'));
  assert.equal(gitLog.some((line) => line.startsWith('fetch ')), false);
  assert.equal(gitLog.some((line) => line.startsWith('merge ')), false);
});

test('update script normalizes explicit versions without calling latest release api', () => {
  const harness = setupHarness({
    curlBody: '{"tag_name":"v9.9.9"}',
  });
  const result = spawnSync('bash', [scriptPath, '--dry-run', '--version', '3.1.1'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Target tag:\s+v3\.1\.1/);
  assert.doesNotMatch(result.stdout, /v9\.9\.9/);
});

test('update script auto-stashes dirty worktrees and restores them after update', () => {
  const harness = setupHarness({
    gitStatus: ' M webui/package-lock.json\n?? nohup.out\n',
  });
  const result = spawnSync('bash', [scriptPath, '--version', '3.1.1'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Detected uncommitted changes, stashing before update\./);
  assert.match(result.stdout, /Restoring stashed local changes\./);

  const gitLog = readGitLog(harness.gitLogPath);
  assert.ok(
    gitLog.some((line) => line.startsWith('stash push --include-untracked --message ds2api-auto-update-')),
  );
  assert.ok(gitLog.some((line) => line === 'fetch https://github.com/CJackHwang/ds2api.git refs/tags/v3.1.1:refs/tags/v3.1.1'));
  assert.ok(gitLog.some((line) => line === 'merge --ff-only v3.1.1'));
  assert.ok(gitLog.some((line) => line === 'stash pop --index'));
  assert.equal(fs.existsSync(harness.stashFlagPath), false);
});
