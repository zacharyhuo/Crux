import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { makeRecord, makeAppcast, addRecord, sha256, verifyArchive, verifyChannelState } from '../appcast.mjs';

function fixture(channel = 'stable', build = 1) {
  const pair = generateKeyPairSync('ed25519'), bytes = Buffer.from('archive bytes');
  const publicKey = Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
  const signature = sign(null, bytes, pair.privateKey).toString('base64');
  const version = '1.0', tag = channel === 'beta' ? `beta-v${version}-b${build}` : `v${version}`;
  const name = `${channel === 'beta' ? 'Crux-Beta' : 'Crux'}-${version}-arm64.zip`;
  const release = { id: build, tag_name: tag, html_url: `https://github.com/zacharyhuo/Crux/releases/tag/${tag}`,
    published_at: '2026-10-06T00:00:00Z', draft: false, prerelease: channel === 'beta',
    body: '## 中文更新\n\n- 修复问题\n\n```swift\nlet value = 1\n```\n\n[版本说明](https://example.invalid/)\n\n]]>' };
  const bundle = { channel, publicKey, identifier: channel === 'beta' ? 'com.zacharyhuo.Crux.Beta' : 'com.zacharyhuo.Crux', version, build, minimumSystemVersion: '26.0' };
  const artifact = { name, browser_download_url: `https://github.com/zacharyhuo/Crux/releases/download/${tag}/${name}`, state: 'uploaded', size: bytes.length, digest: `sha256:${sha256(bytes)}` };
  return { release, bundle, artifact, signature, bytes, signingMode: 'adhoc' };
}

test('exact Release markdown including Unicode and CDATA boundaries is embedded with the signed package', () => {
  const value = fixture(), record = makeRecord(value), state = addRecord({ schemaVersion: 1, channel: 'stable', releases: [] }, record);
  const feed = makeAppcast(state);
  assert.equal(record.notes, value.release.body);
  assert.equal(record.notesSHA256, sha256(value.release.body));
  assert.match(feed, /sparkle:format="markdown"/);
  assert.match(feed, /中文更新/);
  assert.match(feed, /]]]]><!\[CDATA\[>/);
  assert.match(feed, /sparkle:edSignature=/);
  assert.equal(record.notarized, false);
});

test('wrong signature, damaged package, wrong Release tag and mixed channel are rejected', () => {
  const value = fixture();
  assert.throws(() => verifyArchive(Buffer.from('corrupt'), value.signature, value.bundle.publicKey), /verification/);
  assert.throws(() => makeRecord({ ...value, release: { ...value.release, tag_name: 'v2.0' } }), /binding/);
  assert.throws(() => makeRecord({ ...value, release: { ...value.release, prerelease: true } }), /matching/);
  assert.throws(() => makeAppcast({ schemaVersion: 1, channel: 'beta', releases: [makeRecord(value)] }), /Mixed/);
});

test('notes edits cannot change the immutable release package and do not consume a build', () => {
  const value = fixture(), record = makeRecord(value);
  const first = addRecord({ schemaVersion: 1, channel: 'stable', releases: [] }, record);
  const edited = makeRecord({ ...value, release: { ...value.release, body: '# Corrected note' } });
  const updated = addRecord(first, edited);
  assert.equal(updated.releases.length, 1);
  assert.equal(updated.releases[0].notes, '# Corrected note');
  assert.throws(() => addRecord(first, { ...edited, build: 2 }), /Immutable/);
});

test('beta tag channel and monotonic CFBundleVersion are checked and empty notes use the exact page', () => {
  const a = makeRecord(fixture('beta', 2));
  const state = addRecord({ schemaVersion: 1, channel: 'beta', releases: [] }, a);
  assert.throws(() => addRecord(state, makeRecord(fixture('beta', 1))), /increase/);
  const value = fixture('beta', 3);
  value.release.body = '';
  const feed = makeAppcast(addRecord(state, makeRecord(value)));
  assert.match(feed, /<sparkle:channel>beta<\/sparkle:channel>/);
  assert.match(feed, /No release notes were provided/);
  assert.match(feed, /beta-v1\.0-b3/);
});


test('real Sparkle 2.10 serialized feed authenticates its unchanged ledger', () => {
  const feed = readFileSync(new URL('./fixtures/sparkle-2.10-beta-b1.xml', import.meta.url));
  const state = JSON.parse(readFileSync(new URL('./fixtures/sparkle-2.10-beta-b1.json', import.meta.url)));
  const key = 'AhTfgPsK0kUUy/aeMTTVTCkOwoVQAvzRNcX/ZkVlepc=';
  assert.doesNotThrow(() => verifyChannelState(feed, state, key));
  const edited = structuredClone(state);
  edited.releases[0].notes = 'Changed notes';
  edited.releases[0].notesSHA256 = sha256(edited.releases[0].notes);
  assert.throws(() => verifyChannelState(feed, edited, key), /authenticated/);
  assert.throws(() => verifyChannelState(Buffer.from(feed.toString().replace('Crux beta updates', 'Crux beta updateX')), state, key), /verification/);
});
