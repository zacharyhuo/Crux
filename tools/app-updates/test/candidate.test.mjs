import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertCandidateInfo, inspectUpdateArchive } from '../candidate.mjs';
import { candidateInfo, plist } from './zip-fixture.mjs';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { run } from '../process.mjs';

test('actual app identity must match the selected public key/channel/version before signing', () => {
  const publicKey = Buffer.alloc(32, 1).toString('base64');
  const options = { tag: 'beta-v1.0-b2', channel: 'beta', publicKey };
  const info = { CFBundleIdentifier: 'com.zacharyhuo.Crux.Beta', CFBundleExecutable: 'Crux Beta', CFBundleVersion: '2', CFBundleShortVersionString: '1.0',
    SUPublicEDKey: publicKey, LSMinimumSystemVersion: '26.0', SUFeedURL: 'https://raw.githubusercontent.com/zacharyhuo/Crux/app-updates/beta/appcast.xml',
    SURequireSignedFeed: true, SUVerifyUpdateBeforeExtraction: true, SUEnableInstallerLauncherService: true };
  assert.equal(assertCandidateInfo(info, options).build, 2);
  for (const changed of [{ CFBundleIdentifier: 'com.zacharyhuo.Crux' }, { SUPublicEDKey: 'wrong' }, { CFBundleVersion: '3' },
    { CFBundleShortVersionString: '2.0' }, { SURequireSignedFeed: false }, { SUVerifyUpdateBeforeExtraction: false }, { SUEnableInstallerLauncherService: false }])
    assert.throws(() => assertCandidateInfo({ ...info, ...changed }, options));
});

test('native ditto ZIP with framework links uses the same actual-bundle identity check', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'CruxZipIdentityTest-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const app = path.join(directory, 'Crux Beta.app'), contents = path.join(app, 'Contents');
  const framework = path.join(contents, 'Frameworks/Example.framework/Versions');
  await mkdir(path.join(framework, 'A/Resources'), { recursive: true });
  const publicKey = Buffer.alloc(32, 1).toString('base64');
  await writeFile(path.join(contents, 'Info.plist'), plist(candidateInfo(publicKey)));
  await writeFile(path.join(framework, 'A/Resources/info.txt'), 'inert fixture');
  await symlink('A', path.join(framework, 'Current'));
  const archive = path.join(directory, 'fixture.zip');
  await run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
  const bytes = await readFile(archive), options = { tag: 'beta-v1.0-b2', channel: 'beta', publicKey };
  assert.equal((await inspectUpdateArchive(bytes, options)).build, 2);
  await assert.rejects(inspectUpdateArchive(bytes, { ...options, tag: 'beta-v1.0-b3' }), /branding\/version/);
});
