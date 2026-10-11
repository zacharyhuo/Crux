import { lstat } from 'node:fs/promises';
import path from 'node:path';
import { publicKeyObject, repository, updateBranch } from './appcast.mjs';
import { parseReleaseTag } from './release-policy.mjs';
import { run } from './process.mjs';
import { readZipInfo } from './artifact.mjs';

export function assertCandidateInfo(info, { tag, channel, publicKey }) {
  const parsed = parseReleaseTag(tag), name = channel === 'beta' ? 'Crux Beta' : 'Crux';
  publicKeyObject(publicKey);
  const identifier = channel === 'beta' ? 'com.zacharyhuo.Crux.Beta' : 'com.zacharyhuo.Crux';
  const build = Number(info.CFBundleVersion), version = info.CFBundleShortVersionString;
  if (parsed.channel !== channel || info.CFBundleIdentifier !== identifier || info.CFBundleExecutable !== name
      || !/^[1-9]\d*$/.test(String(info.CFBundleVersion)) || !Number.isSafeInteger(build)
      || parsed.version !== version || (channel === 'beta' && parsed.build !== build)
      || info.SUPublicEDKey !== publicKey || !/^26(?:\.\d+){0,2}$/.test(info.LSMinimumSystemVersion)
      || info.SUFeedURL !== `https://raw.githubusercontent.com/${repository}/${updateBranch}/${channel}/appcast.xml`
      || info.SURequireSignedFeed !== true || info.SUVerifyUpdateBeforeExtraction !== true
      || info.SUEnableInstallerLauncherService !== true) throw new Error('Wrong bundle branding/version/updater policy');
  return { channel, identifier, version, build, minimumSystemVersion: info.LSMinimumSystemVersion, publicKey };
}

export async function inspectUpdateArchive(bytes, options, runCommand = run) {
  const plist = readZipInfo(bytes, options.channel);
  const info = JSON.parse(await runCommand('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], plist));
  return assertCandidateInfo(info, options);
}

export async function inspectCandidate(app, options) {
  const name = options.channel === 'beta' ? 'Crux Beta' : 'Crux';
  if (path.basename(app) !== `${name}.app` || !(await lstat(app)).isDirectory()) throw new Error('Wrong update bundle name');
  const info = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
  const record = assertCandidateInfo(info, options);
  if ((await run('lipo', ['-archs', path.join(app, 'Contents/MacOS', name)])).trim() !== 'arm64') throw new Error('Application must contain only arm64');
  await run('codesign', ['--verify', '--deep', '--strict', app]);
  return { info, record };
}
