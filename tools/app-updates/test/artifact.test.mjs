import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inspectTar, validateBuildReceipt, readZipInfo } from '../artifact.mjs';
import { zip } from './zip-fixture.mjs';

function tar(entries) {
  const blocks = [];
  for (const [name, data = '', type = '0', link = ''] of entries) {
    const bytes = Buffer.from(data), header = Buffer.alloc(512);
    header.write(name, 0, 100); header.write('0000755\0', 100); header.write('0000000\0', 108); header.write('0000000\0', 116);
    header.write(bytes.length.toString(8).padStart(11, '0') + '\0', 124); header.write('00000000000\0', 136);
    header.fill(32, 148, 156); header.write(type, 156); header.write(link, 157, 100); header.write('ustar\0', 257); header.write('00', 263);
    const checksum = header.reduce((sum, byte) => sum + byte, 0);
    header.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148);
    blocks.push(header, bytes, Buffer.alloc((512 - bytes.length % 512) % 512));
  }
  return Buffer.concat([...blocks, Buffer.alloc(1024)]);
}

test('artifact parser accepts only the fixed archive root and in-root framework symlinks', () => {
  assert.equal(inspectTar(tar([['Crux.xcarchive/', '', '5'], ['Crux.xcarchive/Info.plist', 'metadata'],
    ['Crux.xcarchive/Versions/B/file', 'binary'], ['Crux.xcarchive/Versions/Current', '', '2', 'B']])).entries, 4);
});

test('artifact parser rejects traversal, absolute paths, devices, hardlinks, symlink parents and truncation', () => {
  for (const entries of [[['../escape', 'bad']], [['/absolute', 'bad']], [['Crux.xcarchive/../escape', 'bad']],
    [['Crux.xcarchive/device', '', '3']], [['Crux.xcarchive/link', '', '1', 'other']],
    [['Crux.xcarchive/link', '', '2', '../../escape']], [['Crux.xcarchive/link', '', '2', '/tmp/escape']],
    [['Crux.xcarchive/link', '', '2', 'inside'], ['Crux.xcarchive/link/file', 'overwrite']],
    [['Crux.xcarchive/file', 'one'], ['Crux.xcarchive/file', 'two']]]) assert.throws(() => inspectTar(tar(entries)));
  assert.throws(() => inspectTar(tar([['Crux.xcarchive/file', 'data']]).subarray(0, 600)));
});

test('artifact receipt binds every trusted input, not only its self-reported hash', () => {
  const expected = { tag: 'beta-v1.0-b2', channel: 'beta', sourceSHA: 'a'.repeat(40), automationSHA: 'b'.repeat(40),
    runId: '12', runAttempt: '1', publicKey: Buffer.alloc(32, 1).toString('base64'), signingMode: 'adhoc', sha256: 'c'.repeat(64) };
  const receipt = { schemaVersion: 1, ...expected, bytes: 1024 };
  assert.doesNotThrow(() => validateBuildReceipt(receipt, expected));
  for (const changed of [{ runId: '13' }, { sourceSHA: 'd'.repeat(40) }, { channel: 'stable' }, { publicKey: 'wrong' }, { sha256: 'e'.repeat(64) }])
    assert.throws(() => validateBuildReceipt({ ...receipt, ...changed }, expected));
});

test('parser-differential regression: slash-named regular file cannot hide additional tar headers', () => {
  const hidden = tar([['outside-root', '', '2', '/tmp/escape']]);
  const smuggled = tar([['Crux.xcarchive/opaque/', hidden, '0']]);
  assert.throws(() => inspectTar(smuggled), /trailing slash/);
});

test('ZIP metadata reader accepts stored/deflated plists without extracting app files', () => {
  const data = Buffer.from('bounded plist bytes'), name = 'Crux Beta.app/Contents/Info.plist';
  for (const method of [0, 8]) for (const flags of [0, 8]) assert.deepEqual(readZipInfo(zip([{ name, data, method, flags }]), 'beta'), data);
  assert.deepEqual(readZipInfo(zip([{ name: 'Crux.app/Contents/Info.plist', data }]), 'stable'), data);
});

test('ZIP metadata reader rejects ambiguous identities, traversal and non-directory parents', () => {
  const name = 'Crux Beta.app/Contents/Info.plist', data = 'plist';
  for (const entries of [
    [{ name, data }, { name, data }],
    [{ name, data }, { name: '../escape', data }],
    [{ name: '/Crux Beta.app/Contents/Info.plist', data }],
    [{ name: 'Crux Beta.app/Contents/../Info.plist', data }],
    [{ name: 'Crux Beta.app/Contents', data: 'other', mode: 0o120777 }, { name, data }],
    [{ name, data: 'other', mode: 0o120777 }],
    [{ name, data, mode: 0o020644 }],
    [{ name: name + '/', data }],
    [{ name: 'Crux.app/Contents/Info.plist', data }],
    [{ name, data, flags: 1 }]
  ]) assert.throws(() => readZipInfo(zip(entries), 'beta'));
  const mismatch = zip([{ name, data }]); mismatch[30] = 'X'.charCodeAt(0);
  assert.throws(() => readZipInfo(mismatch, 'beta'), /local payload/);
});

test('ZIP plist size, CRC and archive structure fail closed', () => {
  const name = 'Crux Beta.app/Contents/Info.plist';
  assert.throws(() => readZipInfo(zip([{ name, data: Buffer.alloc(128 * 1024 + 1), method: 8 }]), 'beta'), /plist/);
  const corrupt = zip([{ name, data: 'plist' }]); corrupt[30 + Buffer.byteLength(name)] ^= 1;
  assert.throws(() => readZipInfo(corrupt, 'beta'), /checksum/);
  assert.throws(() => readZipInfo(corrupt.subarray(0, corrupt.length - 1), 'beta'), /directory/);
  assert.throws(() => readZipInfo(Buffer.alloc(22), 'beta'), /directory/);
});

test('ZIP reader refuses filesystem aliases and alternate Unicode-path metadata', () => {
  const name = 'Crux Beta.app/Contents/Info.plist', data = 'plist';
  assert.throws(() => readZipInfo(zip([{ name, data }, { name: 'Crux Beta.app/Contents/info.plist', data }]), 'beta'), /duplicate/);
  assert.throws(() => readZipInfo(zip([{ name, data }, { name: 'Crux Beta.app/café', data }, { name: 'Crux Beta.app/cafe\u0301', data }]), 'beta'), /duplicate/);
  // Unicode Path and ZIP64 extra fields can make native tools interpret entries
  // differently. They are outside the supported format, even on a signed ZIP.
  for (const id of [0x7075, 0x0001]) {
    const extra = Buffer.alloc(9); extra.writeUInt16LE(id); extra.writeUInt16LE(5, 2);
    assert.throws(() => readZipInfo(zip([{ name, data, extra }]), 'beta'), /extra/);
  }
});

test('ZIP reader rejects an unindexed duplicate plist that a streaming extractor could choose', () => {
  const name = 'Crux Beta.app/Contents/Info.plist';
  const bytes = zip([{ name, data: 'approved plist' }, { name, data: 'hidden plist' }]);
  const end = Buffer.from(bytes.subarray(bytes.length - 22)), start = end.readUInt32LE(16), entrySize = 46 + Buffer.byteLength(name);
  end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(entrySize, 12);
  const hidden = Buffer.concat([bytes.subarray(0, start + entrySize), end]);
  assert.throws(() => readZipInfo(hidden, 'beta'), /unindexed|contiguous/);
});
