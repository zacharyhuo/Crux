import { parseArgs } from 'node:util';
import { generateKeyPairSync } from 'node:crypto';
import { mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { run } from '../process.mjs';
import { sha256, verifyArchive } from '../appcast.mjs';

const { values } = parseArgs({ options: { output: { type: 'string' } } });
if (!values.output || !path.isAbsolute(values.output) || !values.output.startsWith(path.resolve('build/SparkleAcceptance') + path.sep)) throw new Error('Choose a NEW project-local acceptance directory');
const root = values.output;
await mkdir(root, { mode: 0o700 });
const pair = generateKeyPairSync('ed25519');
const publicKey = Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
const key = path.join(root, 'ephemeral-test-key.txt');
await writeFile(key, Buffer.from(pair.privateKey.export({ format: 'jwk' }).d, 'base64url').toString('base64'), { mode: 0o600, flag: 'wx' });
const archive = path.join(root, 'built/Crux.xcarchive');
console.log('Building a disposable Beta archive; no app will be launched or installed.');
await run('xcodebuild', ['archive', '-project', 'Crux.xcodeproj', '-scheme', 'Crux Beta', '-configuration', 'BetaRelease',
  '-archivePath', archive, '-derivedDataPath', path.resolve('build/SparkleAcceptance'), '-destination', 'generic/platform=macOS', '-jobs', '2',
  'ARCHS=arm64', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
  'CRUX_CODE_SIGN_ENTITLEMENTS=Crux/Crux-AdHoc.entitlements', `SPARKLE_PUBLIC_ED_KEY=${publicKey}`, '-quiet'], undefined, { timeout: 600_000 });
const app = path.join(archive, 'Products/Applications/Crux Beta.app');
const info = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
const tag = `beta-v${info.CFBundleShortVersionString}-b${info.CFBundleVersion}`;
// Local candidate fields exercise transport binding, not GitHub provenance.
const commit = (await run('git', ['rev-parse', 'HEAD'])).trim();
const common = ['--tag', tag, '--source-sha', commit, '--automation-sha', commit, '--run-id', '4242', '--run-attempt', '1', '--public-key', publicKey, '--signing-mode', 'adhoc'];
const artifact = path.join(root, 'candidate');
await run('node', ['tools/app-updates/artifact.mjs', '--mode', 'pack', '--archive', archive, '--output', artifact, ...common]);
const receipt = JSON.parse(await readFile(path.join(artifact, 'build-receipt.json')));
const verified = path.join(root, 'verified');
await run('node', ['tools/app-updates/artifact.mjs', '--mode', 'unpack', '--directory', artifact, '--output', verified, '--sha256', receipt.sha256, ...common]);
const verifiedApp = path.join(verified, 'Crux.xcarchive/Products/Applications/Crux Beta.app');
await run('node', ['tools/app-updates/inspect-candidate.mjs', '--app', verifiedApp, '--tag', tag, '--channel', 'beta', '--public-key', publicKey]);
console.log('Receipt, archive structure and actual app verified before using a signing key.');
const sdk = path.join(root, 'signer');
await run('node', ['tools/app-updates/fetch-signer.mjs', '--directory', sdk]);
const dist = path.join(root, 'dist');
await run('bash', ['scripts/package-release.sh', verifiedApp, info.CFBundleShortVersionString, dist]);
await run('node', ['tools/app-updates/prepare.mjs', '--app', verifiedApp, '--channel', 'beta', '--tag', tag, '--output', dist,
  '--existing-archive', '--key-file', key, '--sign-tool', path.join(sdk, 'bin/sign_update'), '--signing-mode', 'adhoc']);
const signed = JSON.parse(await readFile(path.join(dist, 'update-build.json'))), zip = await readFile(path.join(dist, signed.file));
verifyArchive(zip, signed.signature, publicKey);
const payloadPath = path.join(artifact, 'payload.tar'), bytes = await readFile(payloadPath);
bytes[1024] ^= 1;
await writeFile(payloadPath, bytes);
const rejected = path.join(root, 'rejected');
await assert.rejects(run('node', ['tools/app-updates/artifact.mjs', '--mode', 'unpack', '--directory', artifact, '--output', rejected, '--sha256', receipt.sha256, ...common]), /changed since/);
assert.equal((await readdir(rejected)).length, 0);
const result = { mode: 'local security acceptance; simulated CI identifiers', tag, channel: 'beta', sourceSHA: commit,
  artifactSHA256: receipt.sha256, signedZipSHA256: sha256(zip), signerVersion: '2.10.0', tamperedPayloadRejectedBeforeExtraction: true,
  applicationLaunched: false, installedAppsTouched: false, personalKeychainAccessed: false };
await writeFile(path.join(root, 'receipt.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' });
console.log(JSON.stringify(result, null, 2));
