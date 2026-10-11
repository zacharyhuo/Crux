import { parseArgs } from 'node:util';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { run } from '../process.mjs';
import { verifySignedFeed, makeRecord, makeAppcast, sha256 } from '../appcast.mjs';

// Explicit disposable Beta artifacts only. This does not launch any Crux app,
// access existing signing keys, change Gatekeeper, or install under /Applications.
const { values } = parseArgs({ options: { 'base-app': { type: 'string' }, sdk: { type: 'string' }, output: { type: 'string' } } });
if (!values['base-app'] || !values.sdk || !values.output) throw new Error('Explicit built Beta app, resolved SDK and fresh output directory are required');
const base = path.resolve(values['base-app']), sdk = path.resolve(values.sdk), root = path.resolve(values.output);
if (path.basename(base) !== 'Crux Beta.app' || !(await lstat(base)).isDirectory()
    || !root.startsWith(path.resolve('build/SparkleAcceptance') + path.sep)) throw new Error('Unsafe acceptance paths');
const baseInfo = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(base, 'Contents/Info.plist')]));
if (baseInfo.CFBundleIdentifier !== 'com.zacharyhuo.Crux.Beta') throw new Error('Production app is forbidden');
await mkdir(root, { mode: 0o700 });
const pair = generateKeyPairSync('ed25519');
const publicKey = Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
const keyFile = path.join(root, 'ephemeral-test-key.txt');
await writeFile(keyFile, Buffer.from(pair.privateKey.export({ format: 'jwk' }).d, 'base64url').toString('base64'), { flag: 'wx', mode: 0o600 });
const frameworkParent = path.join(sdk, 'artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64');
const signTool = path.join(sdk, 'artifacts/sparkle/Sparkle/bin/sign_update');
const source = path.join(sdk, 'checkouts/Sparkle/sparkle-cli');
const cli = path.join(root, 'sparkle-cli'), notesUI = path.join(root, 'native-notes');
const compiler = ['-fobjc-arc', '-arch', 'arm64', '-mmacosx-version-min=26.0',
  '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))', '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))',
  '-F', frameworkParent, '-framework', 'Cocoa', '-framework', 'Sparkle', '-Wl,-rpath,' + frameworkParent];
await run('xcrun', ['clang', ...compiler, path.join(source, 'main.m'), path.join(source, 'SPUCommandLineDriver.m'), path.join(source, 'SPUCommandLineUserDriver.m'), '-o', cli]);
await run('xcrun', ['clang', ...compiler, path.resolve('tools/app-updates/test/native-notes.m'), '-o', notesUI]);
const id = `com.zacharyhuo.Crux.Beta.UpdateAcceptance.${randomUUID()}`;
const baseline = path.join(root, 'installed/Crux Beta.app'), next = path.join(root, 'candidate/Crux Beta.app');
const entitlements = path.join(root, 'fixture-entitlements.plist');
await writeFile(entitlements, `<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/><key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>${id}-spks</string><string>${id}-spki</string></array></dict></plist>`, { flag: 'wx' });
for (const [app, build] of [[baseline, 100], [next, 101]]) {
  await run('ditto', [base, app]);
  const info = { ...baseInfo, CFBundleIdentifier: id, CFBundleVersion: String(build), CFBundleShortVersionString: '1.0',
    SUPublicEDKey: publicKey, SURequireSignedFeed: true, SUVerifyUpdateBeforeExtraction: true,
    SUAutomaticallyUpdate: false, SUEnableAutomaticChecks: false };
  await writeFile(path.join(app, 'Contents/Info.plist'), JSON.stringify(info));
  await run('/usr/bin/plutil', ['-convert', 'xml1', path.join(app, 'Contents/Info.plist')]);
  await run('codesign', ['--force', '--sign', '-', '--entitlements', entitlements, app]);
  await run('codesign', ['--verify', '--deep', '--strict', app]);
}
const archive = path.join(root, 'update.zip');
await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', next, archive]);
const signature = (await run(signTool, ['--ed-key-file', keyFile, '-p', archive])).trim();
const bytes = await readFile(archive);
const notes = '## 中文更新\n\n- 修复问题\n\n```swift\nlet value = 1\n```\n\n[版本说明](https://github.com/zacharyhuo/Crux/releases/tag/beta-v1.0-b101)';
let feed, servedBytes = bytes;
const requests = [];
const server = createServer((req, res) => {
  requests.push(req.url);
  const data = req.url?.split('?')[0] === '/appcast.xml' ? feed : req.url === '/update.zip' ? servedBytes : null;
  if (!data) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': req.url.startsWith('/appcast') ? 'application/xml' : 'application/octet-stream', 'Content-Length': Buffer.byteLength(data) });
  res.end(data);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}`;
const feedPath = path.join(root, 'appcast.xml');
const artifactURL = 'https://github.com/zacharyhuo/Crux/releases/download/beta-v1.0-b101/Crux-Beta-1.0-arm64.zip';
const record = makeRecord({ release: { id: 101, tag_name: 'beta-v1.0-b101', html_url: 'https://github.com/zacharyhuo/Crux/releases/tag/beta-v1.0-b101',
  published_at: '2026-10-06T00:00:00Z', draft: false, prerelease: true, body: notes },
  bundle: { channel: 'beta', identifier: 'com.zacharyhuo.Crux.Beta', publicKey, version: '1.0', build: 101, minimumSystemVersion: '26.0' },
  artifact: { name: 'Crux-Beta-1.0-arm64.zip', browser_download_url: artifactURL, state: 'uploaded', size: bytes.length, digest: `sha256:${sha256(bytes)}` },
  bytes, signature, signingMode: 'adhoc' });
// Only the loopback transport is substituted; all version/notes/enclosure
// generation uses the real publisher module. Sign after this substitution.
const rawFeed = makeAppcast({ schemaVersion: 1, channel: 'beta', releases: [record] }).replace(artifactURL, `${url}/update.zip`);
await writeFile(feedPath, rawFeed, { flag: 'wx' });
await run(signTool, ['--ed-key-file', keyFile, '-p', feedPath]);
feed = await readFile(feedPath);
verifySignedFeed(feed, publicKey);
const args = [baseline, '--check-immediately', '--channels', 'beta', '--feed-url', `${url}/appcast.xml`, '--user-agent-name', 'Crux isolated update acceptance', '--verbose'];
const version = async () => JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(baseline, 'Contents/Info.plist')])).CFBundleVersion;
const receipts = [];
try {
  // A correctly signed feed carrying an invalid package must not install.
  servedBytes = Buffer.from(bytes);
  servedBytes[100] ^= 1; // same length: reject signature, not just byte count
  await assert.rejects(run(cli, args), /signature|verif|validat/i);
  assert.equal(await version(), '100');
  receipts.push({ test: 'tampered-archive', result: 'rejected', installedBuild: '100' });
  servedBytes = bytes;
  // Sparkle may downgrade a failed signed feed to information-only. Either
  // way, it must not install the package or trust embedded release notes.
  const validFeed = feed;
  // Never reuse the failed-archive installer cache for this independent gate.
  const feedBaseline = path.join(root, 'feed-rejection/Crux Beta.app');
  await run('ditto', [baseline, feedBaseline]);
  const feedInfoPath = path.join(feedBaseline, 'Contents/Info.plist');
  const feedInfo = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', feedInfoPath]));
  feedInfo.CFBundleIdentifier = `${id}.FeedCase`;
  await writeFile(feedInfoPath, JSON.stringify(feedInfo));
  await run('/usr/bin/plutil', ['-convert', 'xml1', feedInfoPath]);
  await run('codesign', ['--force', '--sign', '-', '--entitlements', entitlements, feedBaseline]);
  feed = Buffer.from(feed.toString().replace('中文更新', '篡改内容'));
  const requestStart = requests.length;
  let feedError = '';
  try { await run(cli, [feedBaseline, ...args.slice(1)]); } catch (error) { feedError = error.message; }
  assert.ok(requests.slice(requestStart).some(request => request.startsWith('/appcast.xml')));
  assert.ok(!requests.slice(requestStart).includes('/update.zip'), 'Invalid signed feed must be rejected before downloading its archive');
  assert.equal(JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', feedInfoPath])).CFBundleVersion, '100');
  receipts.push({ test: 'tampered-feed', result: 'rejected-before-download', installedBuild: '100', error: feedError });
  feed = validFeed;
  await run(cli, args);
  assert.equal(await version(), '101');
  await run('codesign', ['--verify', '--deep', '--strict', baseline]);
  receipts.push({ test: 'valid-signed-update', result: 'installed', installedBuild: '101' });
  await writeFile(path.join(root, 'notes-item.json'), JSON.stringify({ 'sparkle:version': String(record.build), 'sparkle:shortVersionString': record.version,
    enclosure: { url: `${url}/update.zip`, length: String(bytes.length) }, description: { content: record.notes, format: 'markdown' } }), { flag: 'wx' });
  const native = JSON.parse(await run(notesUI, [feedBaseline, path.join(root, 'notes-item.json'), path.join(root, 'native-notes.png')]));
  receipts.push({ test: 'standard-native-notes', ...native });
  // Exercise the same ZIP/DMG + signing path as CI, without launching the
  // original branded app or using any production key.
  const packageApp = path.join(root, 'packaging/Crux Beta.app');
  await run('ditto', [base, packageApp]);
  const packageInfoPath = path.join(packageApp, 'Contents/Info.plist');
  const packageInfo = { ...baseInfo, SUPublicEDKey: publicKey, CFBundleVersion: '102', CFBundleShortVersionString: '1.0' };
  await writeFile(packageInfoPath, JSON.stringify(packageInfo));
  await run('/usr/bin/plutil', ['-convert', 'xml1', packageInfoPath]);
  await run('codesign', ['--force', '--sign', '-', '--preserve-metadata=entitlements', packageApp]);
  const dist = path.join(root, 'dist');
  await run('bash', [path.resolve('scripts/package-release.sh'), packageApp, '1.0', dist]);
  await run('node', [path.resolve('tools/app-updates/prepare.mjs'), '--app', packageApp, '--channel', 'beta', '--tag', 'beta-v1.0-b102',
    '--output', dist, '--existing-archive', '--key-file', keyFile, '--sign-tool', signTool, '--signing-mode', 'adhoc']);
  const metadata = JSON.parse(await readFile(path.join(dist, 'update-build.json')));
  assert.equal(metadata.build, 102);
  assert.equal(metadata.publicKey, publicKey);
  assert.equal(metadata.sha256, sha256(await readFile(path.join(dist, metadata.file))));
  assert.ok((await lstat(path.join(dist, 'Crux-Beta-1.0-arm64.dmg'))).isFile());
  await assert.rejects(run('bash', [path.resolve('scripts/package-release.sh'), packageApp, '1.0', dist]), /already exists/);
  receipts.push({ test: 'release-packaging', zip: metadata.file, dmg: 'Crux-Beta-1.0-arm64.dmg', signingMode: metadata.signingMode, overwriteRejected: true });
  const receipt = { bundleIdentifier: id, appPath: baseline, transport: 'loopback HTTP test only; production requires HTTPS',
    applicationLaunched: false, productionTouched: false, betaUserDataTouched: false, requests, receipts };
  await writeFile(path.join(root, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  console.log(JSON.stringify(receipt, null, 2));
} finally { await new Promise(resolve => server.close(resolve)); }
