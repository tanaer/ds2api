'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const deployScriptPath = path.resolve(__dirname, '../../scripts/deploy-ds2api.sh');
const rollbackScriptPath = path.resolve(__dirname, '../../scripts/rollback-ds2api.sh');

function writeExecutable(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, { mode: 0o755 });
}

function createTempRepo() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ds2api-deploy-test-'));
  const repoDir = path.join(tempDir, 'repo');
  fs.mkdirSync(path.join(repoDir, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(repoDir, 'static', 'admin'), { recursive: true });
  fs.mkdirSync(path.join(repoDir, 'webui'), { recursive: true });
  fs.writeFileSync(path.join(repoDir, 'VERSION'), '3.1.0\n');
  fs.writeFileSync(path.join(repoDir, 'ds2api'), 'old-binary\n', { mode: 0o755 });
  fs.writeFileSync(path.join(repoDir, 'static', 'admin', 'index.html'), 'old-webui\n');
  return { tempDir, repoDir };
}

function createFakeBin(binDir) {
  writeExecutable(
    path.join(binDir, 'systemctl'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_SYSTEMCTL_LOG:?}"
case "\${1:-}" in
  show)
    if [ "\${2:-}" = "-p" ] && [ "\${3:-}" = "FragmentPath" ] && [ "\${4:-}" = "--value" ]; then
      printf '%s\\n' "\${FAKE_SERVICE_FILE:?}"
      exit 0
    fi
    ;;
  restart)
    exit 0
    ;;
  is-active)
    if [ "\${2:-}" = "--quiet" ]; then
      exit 0
    fi
    ;;
esac
echo "unsupported fake systemctl invocation: $*" >&2
exit 1
`,
  );

  writeExecutable(
    path.join(binDir, 'curl'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_CURL_LOG:?}"
printf '%s' "\${FAKE_CURL_BODY:-ok}"
`,
  );

  writeExecutable(
    path.join(binDir, 'git'),
    `#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-C" ]; then
  shift 2
fi
printf '%s\\n' "$*" >> "\${FAKE_GIT_LOG:?}"
case "\${1:-}" in
  rev-parse)
    if [ "\${2:-}" = "HEAD" ]; then
      printf '%s\\n' "\${FAKE_GIT_HEAD:-aaaaaaaa}"
      exit 0
    fi
    ;;
  describe)
    printf '%s\\n' "\${FAKE_GIT_DESCRIBE:-v3.1.0}"
    exit 0
    ;;
esac
echo "unsupported fake git invocation: $*" >&2
exit 1
`,
  );

  writeExecutable(
    path.join(binDir, 'go'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_GO_LOG:?}"
out=""
ldflags=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -ldflags=*)
      ldflags="\${1#-ldflags=}"
      shift
      ;;
    -ldflags)
      ldflags="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out" ] || { echo "missing output file" >&2; exit 1; }
printf 'new-binary %s\\n' "$ldflags" > "$out"
chmod +x "$out"
`,
  );
}

function createHelperScripts(repoDir) {
  writeExecutable(
    path.join(repoDir, 'scripts', 'update-ds2api.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_UPDATE_LOG:?}"
printf '3.1.1\\n' > "\${DS2API_UPDATE_ROOT:?}/VERSION"
`,
  );

  writeExecutable(
    path.join(repoDir, 'scripts', 'build-webui.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_WEBUI_LOG:?}"
printf 'new-webui\\n' > "\${DS2API_DEPLOY_ROOT:?}/static/admin/index.html"
`,
  );
}

function createStashingUpdateScript(repoDir) {
  writeExecutable(
    path.join(repoDir, 'scripts', 'update-ds2api.sh'),
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "\${FAKE_UPDATE_LOG:?}"
rm -f "\${DS2API_UPDATE_ROOT:?}/scripts/build-webui.sh"
printf '3.1.1\\n' > "\${DS2API_UPDATE_ROOT:?}/VERSION"
`,
  );
}

function setupHarness() {
  const { tempDir, repoDir } = createTempRepo();
  const binDir = path.join(tempDir, 'bin');
  const serviceFile = path.join(tempDir, 'ds2api.service');
  fs.mkdirSync(binDir, { recursive: true });
  createFakeBin(binDir);
  createHelperScripts(repoDir);
  fs.writeFileSync(
    serviceFile,
    [
      '[Service]',
      `WorkingDirectory=${repoDir}`,
      `ExecStart=${path.join(repoDir, 'ds2api')}`,
      'Environment=PORT=5001',
      '',
    ].join('\n'),
  );

  return {
    repoDir,
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH}`,
      DS2API_DEPLOY_ROOT: repoDir,
      DS2API_UPDATE_ROOT: repoDir,
      FAKE_SERVICE_FILE: serviceFile,
      FAKE_SYSTEMCTL_LOG: path.join(tempDir, 'systemctl.log'),
      FAKE_CURL_LOG: path.join(tempDir, 'curl.log'),
      FAKE_GIT_LOG: path.join(tempDir, 'git.log'),
      FAKE_GO_LOG: path.join(tempDir, 'go.log'),
      FAKE_UPDATE_LOG: path.join(tempDir, 'update.log'),
      FAKE_WEBUI_LOG: path.join(tempDir, 'webui.log'),
      FAKE_GIT_HEAD: '1111111',
      FAKE_GIT_DESCRIBE: 'v3.1.0',
    },
    paths: {
      backupRoot: path.join(repoDir, '.deploy-backups'),
      systemctlLog: path.join(tempDir, 'systemctl.log'),
      curlLog: path.join(tempDir, 'curl.log'),
      gitLog: path.join(tempDir, 'git.log'),
      goLog: path.join(tempDir, 'go.log'),
      updateLog: path.join(tempDir, 'update.log'),
      webuiLog: path.join(tempDir, 'webui.log'),
    },
  };
}

function readLog(filePath) {
  if (!fs.existsSync(filePath)) {
    return [];
  }
  return fs
    .readFileSync(filePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

function latestBackupDir(backupRoot) {
  const entries = fs
    .readdirSync(backupRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== 'latest')
    .map((entry) => entry.name)
    .sort();
  assert.ok(entries.length > 0, 'expected at least one backup directory');
  return path.join(backupRoot, entries.at(-1));
}

test('deploy script backs up current program and deploys rebuilt artifacts', () => {
  const harness = setupHarness();
  const result = spawnSync('bash', [deployScriptPath, '--service-name', 'ds2api'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(harness.repoDir, 'VERSION'), 'utf8').trim(), '3.1.1');
  assert.match(fs.readFileSync(path.join(harness.repoDir, 'ds2api'), 'utf8'), /BuildVersion=v3\.1\.1/);
  assert.equal(fs.readFileSync(path.join(harness.repoDir, 'static', 'admin', 'index.html'), 'utf8').trim(), 'new-webui');

  const backupDir = latestBackupDir(harness.paths.backupRoot);
  assert.equal(fs.readFileSync(path.join(backupDir, 'ds2api'), 'utf8').trim(), 'old-binary');
  assert.equal(fs.readFileSync(path.join(backupDir, 'static', 'admin', 'index.html'), 'utf8').trim(), 'old-webui');

  const updateLog = readLog(harness.paths.updateLog);
  const webuiLog = readLog(harness.paths.webuiLog);
  const systemctlLog = readLog(harness.paths.systemctlLog);
  const curlLog = readLog(harness.paths.curlLog);

  assert.ok(updateLog.some((line) => line === '--repo-dir ' + harness.repoDir));
  assert.ok(webuiLog.some((line) => line === '--repo-dir ' + harness.repoDir));
  assert.ok(systemctlLog.some((line) => line === 'restart ds2api'));
  assert.ok(systemctlLog.some((line) => line === 'is-active --quiet ds2api'));
  assert.ok(curlLog.some((line) => line.includes('http://127.0.0.1:5001/healthz')));
});

test('rollback script restores the latest backup and restarts the service', () => {
  const harness = setupHarness();
  const deployResult = spawnSync('bash', [deployScriptPath, '--service-name', 'ds2api'], {
    encoding: 'utf8',
    env: harness.env,
  });
  assert.equal(deployResult.status, 0, deployResult.stderr);

  const rollbackResult = spawnSync('bash', [rollbackScriptPath, '--service-name', 'ds2api'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(rollbackResult.status, 0, rollbackResult.stderr);
  assert.equal(fs.readFileSync(path.join(harness.repoDir, 'ds2api'), 'utf8').trim(), 'old-binary');
  assert.equal(fs.readFileSync(path.join(harness.repoDir, 'static', 'admin', 'index.html'), 'utf8').trim(), 'old-webui');

  const systemctlLog = readLog(harness.paths.systemctlLog);
  assert.ok(systemctlLog.filter((line) => line === 'restart ds2api').length >= 2);
});

test('deploy script keeps using a staged webui builder even if update step removes repo helper', () => {
  const harness = setupHarness();
  createStashingUpdateScript(harness.repoDir);

  const result = spawnSync('bash', [deployScriptPath, '--service-name', 'ds2api'], {
    encoding: 'utf8',
    env: harness.env,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(harness.repoDir, 'static', 'admin', 'index.html'), 'utf8').trim(), 'new-webui');
});
