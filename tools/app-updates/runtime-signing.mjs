import { execFile } from 'node:child_process';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { run } from './process.mjs';

const execute = promisify(execFile);
const command = (file, args, options = {}) => execute(file, args, {
  encoding: 'utf8', timeout: 30_000, maxBuffer: 1024 * 1024, ...options
});

export function assertRuntimeSigning(app, framework, entitlements) {
  const disabled = entitlements['com.apple.security.cs.disable-library-validation'] === true;
  if (!app.hardenedRuntime || entitlements['com.apple.security.app-sandbox'] !== true
      || entitlements['com.apple.security.get-task-allow'] === true)
    throw new Error('Packaged app must retain hardened runtime and sandbox, without debugger access');
  if (app.adhoc) {
    if (!disabled) throw new Error('Ad-hoc app cannot load Sparkle with library validation enabled; build with Crux/Crux-AdHoc.entitlements');
  } else if (disabled || !app.team || app.team !== framework.team || framework.adhoc) {
    throw new Error('Certificate-signed app must validate Sparkle with the same Team ID and no ad-hoc exception');
  }
}

async function signature(bundle) {
  const { stderr } = await command('/usr/bin/codesign', ['--display', '--verbose=4', bundle]);
  const flags = /\bflags=0x([0-9a-f]+)/i.exec(stderr);
  if (!flags) throw new Error('Cannot read code-signing flags');
  const value = Number.parseInt(flags[1], 16);
  const team = /^TeamIdentifier=(.+)$/m.exec(stderr)?.[1];
  return { adhoc: (value & 2) !== 0, hardenedRuntime: (value & 0x10000) !== 0,
    team: team === 'not set' ? undefined : team };
}

export async function inspectRuntimeSigning(bundle) {
  await command('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle]);
  const app = await signature(bundle);
  const framework = await signature(path.join(bundle, 'Contents/Frameworks/Sparkle.framework'));
  const { stdout } = await command('/usr/bin/codesign', ['--display', '--entitlements', '-', '--xml', bundle]);
  // plutil reads the small public entitlement plist, never a Keychain or key file.
  const entitlements = JSON.parse(await run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], stdout));
  assertRuntimeSigning(app, framework, entitlements);
  return { signingMode: app.adhoc ? 'adhoc' : 'certificate', hardenedRuntime: true, sandbox: true,
    libraryValidation: entitlements['com.apple.security.cs.disable-library-validation'] !== true };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node runtime-signing.mjs /absolute/path/Crux.app');
  console.log(JSON.stringify(await inspectRuntimeSigning(path.resolve(process.argv[2]))));
}
