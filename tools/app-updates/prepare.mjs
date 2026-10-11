import { parseArgs } from 'node:util';
import { lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { sha256, verifyArchive } from './appcast.mjs';
import { inspectCandidate, inspectUpdateArchive } from './candidate.mjs';
import { run } from './process.mjs';
import { inspectRuntimeSigning } from './runtime-signing.mjs';

const { values } = parseArgs({ options: {
  app: { type: 'string' }, channel: { type: 'string' }, tag: { type: 'string' }, output: { type: 'string' },
  'key-file': { type: 'string' }, 'sign-tool': { type: 'string' }, 'signing-mode': { type: 'string' }, 'existing-archive': { type: 'boolean', default: false }
} });
if (!['stable', 'beta'].includes(values.channel) || !['adhoc', 'developer-id'].includes(values['signing-mode'])
    || !values.app || !values.output || !values['key-file'] || !values['sign-tool']) throw new Error('Explicit app, channel, tag, output, sign tool, signing mode and key file are required');
const app = path.resolve(values.app), output = path.resolve(values.output);
const rawInfo = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
const { info, record: identity } = await inspectCandidate(app, { tag: values.tag, channel: values.channel, publicKey: rawInfo.SUPublicEDKey });
await inspectRuntimeSigning(app);
const { identifier, build, version } = identity;
if (values['signing-mode'] === 'developer-id') {
  await run('spctl', ['--assess', '--type', 'execute', app]);
  await run('xcrun', ['stapler', 'validate', app]);
}
await mkdir(output, { recursive: true });
const file = `${values.channel === 'beta' ? 'Crux-Beta' : 'Crux'}-${version}-arm64.zip`, archive = path.join(output, file);
if (values['existing-archive']) {
  if (!(await lstat(archive)).isFile()) throw new Error('Expected a regular packaged update archive');
} else {
  try { await lstat(archive); throw new Error('Update archive already exists; choose a fresh output'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
}
const archiveBytes = await readFile(archive);
const archivedIdentity = await inspectUpdateArchive(archiveBytes, { tag: values.tag, channel: values.channel, publicKey: info.SUPublicEDKey });
for (const key of ['identifier', 'version', 'build', 'minimumSystemVersion', 'publicKey']) {
  if (archivedIdentity[key] !== identity[key]) throw new Error('Packaged archive does not match the app');
}
// Supplying a key file prevents sign_update from looking in a personal Keychain.
const signature = (await run(path.resolve(values['sign-tool']), ['--ed-key-file', path.resolve(values['key-file']), '-p', archive])).trim();
const bytes = await readFile(archive);
verifyArchive(bytes, signature, info.SUPublicEDKey);
const record = { channel: values.channel, identifier, version, build, minimumSystemVersion: info.LSMinimumSystemVersion,
  publicKey: info.SUPublicEDKey, file, signature, sha256: sha256(bytes), bytes: bytes.length, signingMode: values['signing-mode'] };
await writeFile(path.join(output, 'update-build.json'), JSON.stringify(record, null, 2) + '\n', { flag: 'wx' });
console.log(JSON.stringify({ file, version, build, sha256: record.sha256, bytes: record.bytes, channel: record.channel }, null, 2));
