import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('../publish-release.sh', import.meta.url), 'utf8');
const cleanup = source.slice(source.indexOf('cleanup() {'), source.indexOf('umask 077'));
const release = source.slice(source.indexOf('args=('), source.indexOf('release_id='));

for (const channel of ['stable', 'beta']) test(`${channel} Release arguments work with system Bash nounset`, () => {
  const result = spawnSync('/bin/bash', ['-c', `set -euo pipefail\nCHANNEL=${channel}\napp_name='Crux Preview'; version=1.0; build=1; RELEASE_TAG=v1.0; dist=/unused; prefix=Crux; notes_file=/unused\ngh() { printf '%s\\n' "$@"; }\n${release}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Crux Preview 1.0 \(build 1\)/);
  assert.equal(result.stdout.includes('--prerelease'), channel === 'beta');
});

for (const [name, ending, expected] of [
  ['successful publication', 'publication_complete=true', 0],
  ['command failure', 'false', 1],
  ['nounset expansion failure', 'empty=(); printf "%s" "${empty[@]}"; echo "$missing"', 1],
  ['incomplete publication', ':', 1],
]) test(`cleanup preserves failure for ${name}`, () => {
  const directory = mkdtempSync(join(tmpdir(), 'crux-publish-shell-'));
  try {
    const result = spawnSync('/bin/bash', ['-c', `set -euo pipefail\nkey_file="$TEST_DIR/key"; certificate="$TEST_DIR/cert"; notary_key="$TEST_DIR/notary"; keychain="$TEST_DIR/absent-keychain"\ntouch "$key_file" "$certificate" "$notary_key"\npublication_complete=false\n${cleanup}\n${ending}`], { encoding: 'utf8', env: { ...process.env, TEST_DIR: directory } });
    assert.equal(result.status === 0 ? 0 : 1, expected, result.stderr);
    for (const name of ['key', 'cert', 'notary']) assert.equal(existsSync(join(directory, name)), false);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
