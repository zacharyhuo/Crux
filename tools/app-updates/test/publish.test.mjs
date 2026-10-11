import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { publishUpdate } from '../publish.mjs';
import { makeAppcast, makeRecord, sha256, verifyArchive } from '../appcast.mjs';
import { run } from '../process.mjs';
import { candidateInfo, zipInfo } from './zip-fixture.mjs';

async function fixture(t, bytesForKey = key => zipInfo(candidateInfo(key))) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'CruxPublisherTest-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const pair = generateKeyPairSync('ed25519');
  const key = Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
  const bytes = bytesForKey(key);
  const build = { channel: 'beta', identifier: 'com.zacharyhuo.Crux.Beta', publicKey: key, file: 'Crux-Beta-1.0-arm64.zip',
    version: '1.0', build: 2, minimumSystemVersion: '26.0', bytes: bytes.length, sha256: sha256(bytes), signature: sign(null, bytes, pair.privateKey).toString('base64'), signingMode: 'adhoc' };
  const release = { id: 12, tag_name: 'beta-v1.0-b2', html_url: 'https://github.com/zacharyhuo/Crux/releases/tag/beta-v1.0-b2',
    body: '## 中文修复\n\n```swift\nlet value = 1\n```', published_at: '2026-10-06T00:00:00Z', draft: false, prerelease: true,
    assets: [{ id: 34, name: build.file, state: 'uploaded', size: bytes.length, digest: `sha256:${sha256(bytes)}`, browser_download_url: `https://github.com/zacharyhuo/Crux/releases/download/beta-v1.0-b2/${build.file}` }] };
  await writeFile(path.join(directory, build.file), bytes);
  let head = null, tree, state, previousFeed, readback = bytes, race = false, feedPrivateKey = pair.privateKey;
  const signedFeed = state => {
    const xml = Buffer.from(makeAppcast(state));
    return Buffer.concat([xml, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${sign(null, xml, pair.privateKey).toString('base64')}\nlength: ${xml.length}\n-->\n`)]);
  };
  const writes = [], signingCalls = [];
  const runCommand = async (command, args, input) => {
    if (command === '/usr/bin/plutil') return run(command, args, input);
    if (command !== 'gh') {
      signingCalls.push({ command, args });
      assert.equal(args[0], '--ed-key-file');
      assert.equal(args[1], path.join(directory, 'test-only-key'));
      const file = args[3];
      const xml = await readFile(file);
      await writeFile(file, Buffer.concat([xml, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${sign(null, xml, feedPrivateKey).toString('base64')}\nlength: ${xml.length}\n-->\n`)]));
      return '';
    }
    if (args[0] === 'release') {
      await writeFile(path.join(args[args.indexOf('--dir') + 1], build.file), readback);
      return '';
    }
    const endpoint = args[1].replace('repos/zacharyhuo/Crux', '');
    const body = input && JSON.parse(input);
    if (endpoint === '/git/ref/heads/app-updates') {
      if (race && tree) return JSON.stringify({ object: { sha: 'c'.repeat(40) } });
      if (!head) throw new Error('HTTP 404');
      return JSON.stringify({ object: { sha: head } });
    }
    if (endpoint === '/releases/12') return JSON.stringify(release);
    if (endpoint.startsWith('/git/commits/') && !body) return JSON.stringify({ tree: { sha: 'a'.repeat(40) } });
    if (endpoint.startsWith('/contents/')) {
      const content = endpoint.includes('/appcast.xml') ? previousFeed : Buffer.from(JSON.stringify(state));
      if (!content) throw new Error('HTTP 404');
      return JSON.stringify({ type: 'file', encoding: 'base64', size: content.length, content: content.toString('base64') });
    }
    writes.push({ endpoint, body });
    if (endpoint === '/git/trees') { tree = body.tree; return JSON.stringify({ sha: 'a'.repeat(40) }); }
    if (endpoint === '/git/commits') return JSON.stringify({ sha: 'b'.repeat(40) });
    if (endpoint === '/git/refs' || endpoint === '/git/refs/heads/app-updates') {
      assert.notEqual(body.force, true);
      state = JSON.parse(tree.find(r => r.path === 'beta/state.json').content);
      previousFeed = Buffer.from(tree.find(r => r.path === 'beta/appcast.xml').content);
      head = body.sha;
      return '{}';
    }
    throw new Error(`Unexpected API ${endpoint}`);
  };
  return { options: { releaseId: 12, build, directory, publicKey: key, keyFile: path.join(directory, 'test-only-key'), signTool: path.join(directory, 'sign-tool'), runCommand },
    release, writes, signingCalls, bytes, get tree() { return tree; }, corrupt() { readback = Buffer.from('bad upload'); }, race() { race = true; }, wrongSigningSecret() { feedPrivateKey = generateKeyPairSync('ed25519').privateKey; },
    seedOlderRelease() {
      const oldBytes = zipInfo(candidateInfo(key, '1'));
      const oldBuild = { ...build, build: 1 };
      const oldRelease = { ...release, id: 11, tag_name: 'beta-v1.0-b1',
        html_url: 'https://github.com/zacharyhuo/Crux/releases/tag/beta-v1.0-b1', body: '# Original historical notes' };
      const oldAsset = { ...release.assets[0], size: oldBytes.length, digest: `sha256:${sha256(oldBytes)}`,
        browser_download_url: `https://github.com/zacharyhuo/Crux/releases/download/beta-v1.0-b1/${build.file}` };
      const record = makeRecord({ release: oldRelease, bundle: oldBuild, artifact: oldAsset,
        signature: sign(null, oldBytes, pair.privateKey).toString('base64'), bytes: oldBytes, signingMode: 'adhoc' });
      state = { schemaVersion: 1, channel: 'beta', releases: [record] };
      previousFeed = signedFeed(state);
      head = 'a'.repeat(40);
    },
    alterState(change) { change(state); },
    damagePreviousFeed() { previousFeed = Buffer.from(previousFeed); previousFeed[0] ^= 1; },
    removePreviousFeed() { previousFeed = undefined; }
  };
}

for (const field of ['notes', 'signingMode']) {
  test(`unsigned history ${field} tampering is rejected before an approved publisher exposes signing authority`, async t => {
    const f = await fixture(t);
    f.seedOlderRelease();
    f.alterState(state => {
      const old = state.releases[0];
      if (field === 'notes') { old.notes = '# Attacker-supplied historical notes'; old.notesSHA256 = sha256(old.notes); }
      else { old.signingMode = 'developer-id'; old.notarized = true; }
    });
    await assert.rejects(publishUpdate(fullReleaseOptions(f)), /ledger|state|feed/i);
    assert.equal(f.signingCalls.length, 0);
    assert.equal(f.writes.length, 0);
  });
}

test('unsigned or damaged prior feed cannot authenticate persisted channel history', async t => {
  for (const mode of ['missing', 'damaged']) {
    const f = await fixture(t);
    f.seedOlderRelease();
    if (mode === 'missing') f.removePreviousFeed(); else f.damagePreviousFeed();
    await assert.rejects(publishUpdate(fullReleaseOptions(f)), /ledger|state|feed|verification/i);
    assert.equal(f.signingCalls.length, 0);
    assert.equal(f.writes.length, 0);
  }
});

test('first-promotion notes retry rejects an old valid signed ZIP with new unsigned build metadata before key or feed authority', async t => {
  const f = await fixture(t, key => zipInfo(candidateInfo(key, '1')));
  // The attack needs no signer: copy the already-signed build-1 bytes/signature
  // and claim build 2 in update-build.json under the new Release/tag.
  verifyArchive(f.bytes, f.options.build.signature, f.options.publicKey);
  await assert.rejects(publishUpdate(f.options), /first promotion.*approved.*receipt/i);
  assert.equal(f.signingCalls.length, 0);
  assert.equal(f.writes.length, 0);
});

test('even an approved source receipt cannot certify build 1 ZIP bytes as build 2', async t => {
  const f = await fixture(t, key => zipInfo(candidateInfo(key, '1')));
  verifyArchive(f.bytes, f.options.build.signature, f.options.publicKey);
  await assert.rejects(publishUpdate(fullReleaseOptions(f)), /branding\/version|archive identity/i);
  assert.equal(f.signingCalls.length, 0);
  assert.equal(f.writes.length, 0);
});

test('ordinary notes edits take executable identity from the immutable ledger, not downloaded metadata', async t => {
  const f = await fixture(t);
  await publishUpdate(fullReleaseOptions(f));
  const original = JSON.parse(f.tree[0].content).releases[0];
  f.release.body = '# 精确说明\n\n- 更正\n\n```swift\nlet value = 2\n```\n';
  assert.equal((await publishUpdate({ ...f.options, build: { ...f.options.build, publicKey: 'untrusted', version: '9.0', build: 99,
    minimumSystemVersion: '26.1', sha256: '0'.repeat(64), signature: 'untrusted', signingMode: 'developer-id' } })).status, 'published');
  const edited = JSON.parse(f.tree[0].content).releases[0];
  assert.equal(edited.notes, f.release.body);
  for (const key of ['bundleIdentifier', 'version', 'build', 'minimumSystemVersion', 'artifact', 'signingMode', 'notarized']) assert.deepEqual(edited[key], original[key]);
});

test('publisher reads actual upload, signs notes and promotes one atomic Git tree; repeated run is a no-op', async t => {
  const f = await fixture(t);
  assert.equal((await publishUpdate(fullReleaseOptions(f))).status, 'published');
  assert.deepEqual(f.tree.map(r => r.path), ['beta/state.json', 'beta/appcast.xml']);
  assert.match(f.tree[1].content, /sparkle-signatures/);
  assert.match(f.tree[1].content, /中文修复/);
  const writes = f.writes.length;
  assert.equal((await publishUpdate(f.options)).status, 'unchanged');
  assert.equal(f.writes.length, writes);
  f.release.body = '# 更正说明';
  assert.equal((await publishUpdate(f.options)).status, 'published');
  assert.equal(JSON.parse(f.tree[0].content).releases.length, 1);
  assert.match(f.tree[1].content, /更正说明/);
});

test('wrong configured key or damaged uploaded package never writes feed refs', async t => {
  const f = await fixture(t);
  await assert.rejects(publishUpdate({ ...f.options, publicKey: 'wrong-key' }), /public key/);
  f.corrupt();
  await assert.rejects(publishUpdate(fullReleaseOptions(f)), /checksum mismatch/);
  assert.equal(f.writes.length, 0);
});

test('concurrent feed change aborts before ref promotion; no force push is used', async t => {
  const f = await fixture(t);
  f.race();
  await assert.rejects(publishUpdate(fullReleaseOptions(f)), /feed changed/);
  assert.ok(f.writes.every(w => !w.endpoint.startsWith('/git/refs')));
});

test('a mismatched private Secret cannot publish a feed even when the archived release is valid', async t => {
  const f = await fixture(t);
  f.wrongSigningSecret();
  await assert.rejects(publishUpdate(fullReleaseOptions(f)), /verification failed/);
  assert.equal(f.writes.length, 0);
});

function fullReleaseOptions(f) {
  // Simulated trusted job inputs, distinct from attacker-editable update-build.
  // This tests receipt binding, not real GitHub approval or cross-job transport.
  const plan = { publication: true, tag: f.release.tag_name, channel: 'beta', version: '1.0', build: 2,
    sourceSHA: 'a'.repeat(40), automationSHA: 'b'.repeat(40), runId: '4242', runAttempt: '1',
    publicKey: f.options.publicKey, signingMode: 'adhoc' };
  const payload = Buffer.alloc(1024); // Fake transport; the real job verifies USTAR before this entry point.
  const receipt = { schemaVersion: 1, tag: plan.tag, channel: plan.channel, version: plan.version, build: plan.build,
    sourceSHA: plan.sourceSHA, automationSHA: plan.automationSHA, runId: plan.runId, runAttempt: plan.runAttempt,
    publicKey: plan.publicKey, signingMode: plan.signingMode, sha256: sha256(payload), bytes: payload.length };
  const context = { repository: 'zacharyhuo/Crux', ref: 'refs/heads/main', eventName: 'workflow_dispatch',
    automationSHA: plan.automationSHA, runId: plan.runId, runAttempt: plan.runAttempt,
    workflowRef: 'zacharyhuo/Crux/.github/workflows/release.yml@refs/heads/main' };
  return { ...f.options, approval: { plan, receipt, context, payload } };
}

test('matching ZIP identity alone cannot authorize a first notes promotion, including verify-only', async t => {
  const f = await fixture(t);
  f.options.build.sourceSHA = 'a'.repeat(40);
  f.options.build.receipt = fullReleaseOptions(f).approval.receipt;
  await assert.rejects(publishUpdate({ ...f.options, verifyOnly: true, keyFile: undefined, signTool: undefined }), /first promotion.*receipt/i);
  assert.equal(f.signingCalls.length, 0);
  assert.equal(f.writes.length, 0);
});

test('first promotion rejects substituted source/run/automation/payload receipts and notes workflow authority', async t => {
  const f = await fixture(t);
  for (const change of [
    a => { a.receipt.sourceSHA = 'd'.repeat(40); },
    a => { a.receipt.runId = '9999'; },
    a => { a.receipt.automationSHA = 'e'.repeat(40); },
    a => { a.receipt.sha256 = 'f'.repeat(64); },
    a => { a.payload[0] = 1; },
    a => { a.context.ref = 'refs/heads/develop/v1'; },
    a => { a.context.workflowRef = 'zacharyhuo/Crux/.github/workflows/app-update-notes.yml@refs/heads/main'; },
    a => { a.plan.publication = false; }
  ]) {
    const options = fullReleaseOptions(f);
    change(options.approval);
    await assert.rejects(publishUpdate(options), /receipt|trusted main/);
  }
  assert.equal(f.signingCalls.length, 0);
  assert.equal(f.writes.length, 0);
});

test('no-key notes verification validates the original archive and does not acquire feed authority', async t => {
  const f = await fixture(t);
  await publishUpdate(fullReleaseOptions(f));
  f.release.body = '# Revised before approval';
  const signingCalls = f.signingCalls.length, writes = f.writes.length;
  assert.equal((await publishUpdate({ ...f.options, build: undefined, verifyOnly: true, keyFile: undefined, signTool: undefined })).status, 'verified');
  assert.equal(f.signingCalls.length, signingCalls);
  assert.equal(f.writes.length, writes);
  f.corrupt();
  await assert.rejects(publishUpdate({ ...f.options, verifyOnly: true }), /checksum mismatch/);
  assert.equal(f.signingCalls.length, signingCalls);
  assert.equal(f.writes.length, writes);
});
