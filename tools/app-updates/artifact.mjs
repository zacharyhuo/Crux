import { parseArgs } from 'node:util';
import { lstat, mkdir, readFile, writeFile, appendFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { inflateRawSync } from 'node:zlib';
import { sha256, publicKeyObject } from './appcast.mjs';
import { parseReleaseTag } from './release-policy.mjs';
import { run } from './process.mjs';

const limit = 512 * 1024 * 1024;
const decode = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, bytes.indexOf(0) < 0 ? bytes.length : bytes.indexOf(0)));
const octal = bytes => {
  const value = decode(bytes).trim();
  if (!/^[0-7]+$/.test(value)) throw new Error('Invalid tar number');
  const number = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(number)) throw new Error('Oversized tar number');
  return number;
};
const safePath = value => value && !value.startsWith('/') && !/[\\\x00-\x1f\x7f:]/.test(value)
  && value.replace(/\/$/, '').split('/').every(part => part && part !== '.' && part !== '..');
const zipPathKey = name => name.normalize('NFC').toLowerCase();
function checkZipExtra(bytes) {
  let offset = 0;
  while (offset < bytes.length) {
    if (offset + 4 > bytes.length) throw new Error('Invalid ZIP extra field');
    const id = bytes.readUInt16LE(offset), size = bytes.readUInt16LE(offset + 2);
    if ([0x0001, 0x7075].includes(id) || offset + 4 + size > bytes.length) throw new Error('Unsupported ZIP extra field');
    offset += 4 + size;
  }
}

// Read just the real bundle's plist, in memory. Never extract an untrusted ZIP
// or let a native extractor choose between duplicate/local-vs-central names.
// ZIP64, encryption and exotic entry types are outside our bounded ZIP format.
export function readZipInfo(bytes, channel) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 22 || bytes.length > 1024 ** 3 || !['stable', 'beta'].includes(channel)) throw new Error('Invalid update ZIP');
  let end = bytes.length - 22;
  while (end >= Math.max(0, bytes.length - 65557) && (bytes.readUInt32LE(end) !== 0x06054b50 || end + 22 + bytes.readUInt16LE(end + 20) !== bytes.length)) end--;
  if (end < Math.max(0, bytes.length - 65557)) throw new Error('Missing ZIP directory');
  const count = bytes.readUInt16LE(end + 10), start = bytes.readUInt32LE(end + 16);
  if (!count || count > 50_000 || bytes.readUInt16LE(end + 4) || bytes.readUInt16LE(end + 6)
      || bytes.readUInt16LE(end + 8) !== count || start + bytes.readUInt32LE(end + 12) !== end) throw new Error('Unsupported ZIP directory');
  const root = channel === 'beta' ? 'Crux Beta.app' : 'Crux.app', plist = `${root}/Contents/Info.plist`;
  const entries = new Map(), aliases = new Set(), ranges = [];
  let offset = start, info;
  for (let i = 0; i < count; i++) {
    if (offset + 46 > end || bytes.readUInt32LE(offset) !== 0x02014b50) throw new Error('Invalid ZIP entry');
    const flags = bytes.readUInt16LE(offset + 8), method = bytes.readUInt16LE(offset + 10);
    const size = bytes.readUInt32LE(offset + 20), unpacked = bytes.readUInt32LE(offset + 24), length = bytes.readUInt16LE(offset + 28);
    const next = offset + 46 + length + bytes.readUInt16LE(offset + 30) + bytes.readUInt16LE(offset + 32);
    if (next > end || !length || flags & ~0x080e || ![0, 8].includes(method) || bytes.readUInt16LE(offset + 34)) throw new Error('Unsupported ZIP entry');
    const nameBytes = bytes.subarray(offset + 46, offset + 46 + length), name = new TextDecoder('utf-8', { fatal: true }).decode(nameBytes);
    const normalized = name.replace(/\/$/, ''), mode = bytes.readUInt32LE(offset + 38) >>> 16, type = mode & 0o170000;
    if (!safePath(name) || !(normalized === root || name.startsWith(`${root}/`) || name.startsWith('__MACOSX/'))
        || aliases.has(zipPathKey(normalized)) || ![0, 0o100000, 0o040000, 0o120000].includes(type)
        || (name.endsWith('/') && ![0, 0o040000].includes(type)) || (type === 0o040000 && !name.endsWith('/'))) throw new Error('Unsafe or duplicate ZIP path/type');
    entries.set(normalized, name.endsWith('/') ? 'directory' : type === 0o120000 ? 'symlink' : 'file');
    aliases.add(zipPathKey(normalized));
    checkZipExtra(bytes.subarray(offset + 46 + length, offset + 46 + length + bytes.readUInt16LE(offset + 30)));
    const local = bytes.readUInt32LE(offset + 42);
    if (local + 30 > start || bytes.readUInt32LE(local) !== 0x04034b50
        || bytes.readUInt16LE(local + 6) !== flags || bytes.readUInt16LE(local + 8) !== method
        || bytes.readUInt16LE(local + 26) !== length) throw new Error('ZIP local header mismatch');
    const data = local + 30 + length + bytes.readUInt16LE(local + 28);
    if (data + size > start || !bytes.subarray(local + 30, local + 30 + length).equals(nameBytes)
        || (!(flags & 8) && (bytes.readUInt32LE(local + 14) !== bytes.readUInt32LE(offset + 16)
          || bytes.readUInt32LE(local + 18) !== size || bytes.readUInt32LE(local + 22) !== unpacked))) throw new Error('ZIP local payload mismatch');
    checkZipExtra(bytes.subarray(local + 30 + length, data));
    let dataEnd = data + size;
    if (flags & 8) {
      if (dataEnd + 12 > start) throw new Error('Truncated ZIP data descriptor');
      const descriptor = dataEnd + (bytes.readUInt32LE(dataEnd) === 0x08074b50 ? 4 : 0);
      if (descriptor + 12 > start || bytes.readUInt32LE(descriptor) !== bytes.readUInt32LE(offset + 16)
          || bytes.readUInt32LE(descriptor + 4) !== size || bytes.readUInt32LE(descriptor + 8) !== unpacked) throw new Error('ZIP data descriptor mismatch');
      dataEnd = descriptor + 12;
    }
    ranges.push([local, dataEnd]);
    if (normalized === plist) {
      if (entries.get(normalized) !== 'file' || !unpacked || unpacked > 128 * 1024 || size > 128 * 1024) throw new Error('Invalid ZIP bundle plist');
      const compressed = bytes.subarray(data, data + size);
      info = method === 0 ? compressed : inflateRawSync(compressed, { maxOutputLength: 128 * 1024 });
      if (info.length !== unpacked) throw new Error('ZIP plist size mismatch');
      let crc = 0xffffffff;
      for (const byte of info) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
      if (((crc ^ 0xffffffff) >>> 0) !== bytes.readUInt32LE(offset + 16)) throw new Error('ZIP plist checksum mismatch');
    }
    offset = next;
  }
  ranges.sort((a, b) => a[0] - b[0]);
  if (offset !== end || ranges.some((range, i) => i && range[0] < ranges[i - 1][1])) throw new Error('Overlapping ZIP entries');
  if (ranges[0][0] !== 0 || ranges.at(-1)[1] !== start || ranges.some((range, i) => i && range[0] !== ranges[i - 1][1])) throw new Error('ZIP entries must be contiguous; unindexed payload rejected');
  const parents = new Map([...entries].map(([name, type]) => [zipPathKey(name), type]));
  for (const name of entries.keys()) {
    let parent = path.posix.dirname(name);
    while (parent !== '.') {
      const type = parents.get(zipPathKey(parent));
      if (type && type !== 'directory') throw new Error('ZIP entry has a non-directory parent');
      parent = path.posix.dirname(parent);
    }
  }
  if (!info) throw new Error('Missing ZIP bundle plist');
  return info;
}

// Accept only our no-xattrs USTAR transport, not arbitrary downloaded archives.
// Validate before invoking native tar on a fresh directory, before any key exists.
export function inspectTar(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1024 || bytes.length > limit || bytes.length % 512) throw new Error('Invalid build artifact size');
  const entries = new Map();
  let offset = 0, ended = false;
  while (offset + 512 <= bytes.length) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every(byte => byte === 0)) {
      if (offset + 1024 > bytes.length || !bytes.subarray(offset).every(byte => byte === 0)) throw new Error('Invalid tar end blocks');
      ended = true; break;
    }
    if (entries.size >= 50_000 || decode(header.subarray(257, 263)) !== 'ustar') throw new Error('Unsupported artifact tar format');
    const expected = octal(header.subarray(148, 156));
    const checksum = header.reduce((sum, byte, i) => sum + (i >= 148 && i < 156 ? 32 : byte), 0);
    if (checksum !== expected) throw new Error('Build artifact tar checksum mismatch');
    const leaf = decode(header.subarray(0, 100)), prefix = decode(header.subarray(345, 500));
    const name = (prefix ? `${prefix}/` : '') + leaf;
    if (!safePath(name) || (name.replace(/\/$/, '') !== 'Crux.xcarchive' && !name.startsWith('Crux.xcarchive/'))) throw new Error('Artifact path escapes the fixed archive root');
    const normalized = name.replace(/\/$/, '');
    if (entries.has(normalized)) throw new Error('Duplicate artifact entry');
    const type = String.fromCharCode(header[156] || 48), size = octal(header.subarray(124, 136));
    // libarchive treats a trailing-slash name as a directory even if the tar
    // type says regular file, then may parse its body as further headers.
    // Do not let our validator and the native extractor disagree on boundaries.
    if (name.endsWith('/') && type !== '5') throw new Error('Only a directory entry may have a trailing slash');
    if (!['0', '2', '5'].includes(type) || (type !== '0' && size !== 0) || octal(header.subarray(100, 108)) & 0o7000) throw new Error('Unsupported artifact entry type or permissions');
    if (type === '2') {
      const target = decode(header.subarray(157, 257));
      if (!safePath(target)) throw new Error('Unsafe artifact symlink');
      const resolved = path.posix.join(path.posix.dirname(normalized), target);
      if (resolved !== 'Crux.xcarchive' && !resolved.startsWith('Crux.xcarchive/')) throw new Error('Artifact symlink escapes its root');
    }
    entries.set(normalized, type);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (offset > bytes.length) throw new Error('Truncated build artifact');
  }
  if (!ended || !entries.size) throw new Error('Build artifact is incomplete');
  for (const name of entries.keys()) {
    let parent = path.posix.dirname(name);
    while (parent !== '.') {
      if (entries.has(parent) && entries.get(parent) !== '5') throw new Error('Artifact writes through a non-directory parent');
      parent = path.posix.dirname(parent);
    }
  }
  return { entries: entries.size, bytes: bytes.length };
}

export function validateBuildReceipt(receipt, expected) {
  const parsed = parseReleaseTag(expected.tag);
  publicKeyObject(expected.publicKey);
  if (parsed.channel !== expected.channel || !['adhoc', 'developer-id'].includes(expected.signingMode)
      || !/^[0-9a-f]{40}$/.test(expected.sourceSHA) || !/^[0-9a-f]{40}$/.test(expected.automationSHA)
      || !/^[1-9]\d*$/.test(expected.runId) || !/^[1-9]\d*$/.test(expected.runAttempt) || !/^[0-9a-f]{64}$/.test(expected.sha256)) throw new Error('Invalid trusted artifact inputs');
  if (receipt.schemaVersion !== 1 || !Number.isSafeInteger(receipt.bytes) || receipt.bytes < 1024 || receipt.bytes > limit
      || Object.keys(expected).some(key => receipt[key] !== expected[key])) throw new Error('Build receipt does not match trusted release inputs');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: { mode: { type: 'string' }, archive: { type: 'string' }, directory: { type: 'string' }, output: { type: 'string' },
    tag: { type: 'string' }, 'source-sha': { type: 'string' }, 'automation-sha': { type: 'string' }, 'run-id': { type: 'string' }, 'run-attempt': { type: 'string' },
    'public-key': { type: 'string' }, 'signing-mode': { type: 'string' }, sha256: { type: 'string' } } });
  const expected = { ...parseReleaseTag(values.tag), sourceSHA: values['source-sha'], automationSHA: values['automation-sha'],
    runId: values['run-id'], runAttempt: values['run-attempt'], publicKey: values['public-key'], signingMode: values['signing-mode'] };
  // Version/build are derived from the tag in both producer and consumer.
  if (!values.output) throw new Error('Explicit fresh output directory required');
  const output = path.resolve(values.output);
  await mkdir(output, { mode: 0o700 });
  if (values.mode === 'pack') {
    const archive = path.resolve(values.archive ?? '');
    if (path.basename(archive) !== 'Crux.xcarchive' || !(await lstat(archive)).isDirectory()) throw new Error('Expected the built Crux archive');
    const file = path.join(output, 'payload.tar');
    await run('/usr/bin/env', ['COPYFILE_DISABLE=1', '/usr/bin/tar', '--format=ustar', '--no-xattrs', '-cf', file, '-C', path.dirname(archive), 'Crux.xcarchive']);
    const bytes = await readFile(file);
    inspectTar(bytes);
    const receipt = { schemaVersion: 1, ...expected, sha256: sha256(bytes), bytes: bytes.length };
    validateBuildReceipt(receipt, { ...expected, sha256: receipt.sha256 });
    await writeFile(path.join(output, 'build-receipt.json'), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
    if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, `sha256=${receipt.sha256}\nrun_attempt=${receipt.runAttempt}\n`);
    console.log(JSON.stringify(receipt, null, 2));
  } else if (values.mode === 'unpack') {
    const directory = path.resolve(values.directory ?? '');
    const file = path.join(directory, 'payload.tar'), stat = await lstat(file);
    if (!stat.isFile() || stat.size > limit) throw new Error('Invalid build payload');
    const bytes = await readFile(file), receipt = JSON.parse(await readFile(path.join(directory, 'build-receipt.json')));
    validateBuildReceipt(receipt, { ...expected, sha256: values.sha256 });
    if (bytes.length !== receipt.bytes || sha256(bytes) !== values.sha256) throw new Error('Build payload changed since the candidate job');
    inspectTar(bytes);
    await run('/usr/bin/tar', ['-xpf', file, '--no-same-owner', '-C', output]);
    console.log(JSON.stringify({ status: 'verified', sourceSHA: receipt.sourceSHA, archive: path.join(output, 'Crux.xcarchive') }));
  } else throw new Error('Explicit pack/unpack mode required');
}
