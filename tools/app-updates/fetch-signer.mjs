import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { sha256 } from './appcast.mjs';
import { run } from './process.mjs';

// Independent trust anchor: never execute Package.swift or a candidate's tool.
export const signerURL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip';
export const signerSHA256 = '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959';
export async function fetchSignerBytes(request = fetch) {
  const response = await request(signerURL, { signal: AbortSignal.timeout(120_000) });
  if (!response.ok || !response.body) throw new Error('Cannot fetch pinned Sparkle signer');
  const limit = 100 * 1024 * 1024;
  if (Number(response.headers.get('content-length')) > limit) { await response.body.cancel(); throw new Error('Sparkle signer exceeds size limit'); }
  const reader = response.body.getReader(), chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new Error('Sparkle signer exceeds size limit');
      chunks.push(Buffer.from(value));
    }
  } catch (error) { await reader.cancel(); throw error; }
  finally { reader.releaseLock(); }
  const bytes = Buffer.concat(chunks);
  if (sha256(bytes) !== signerSHA256) throw new Error('Sparkle signer checksum mismatch');
  return bytes;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: { directory: { type: 'string' } } });
  if (!values.directory || !path.isAbsolute(values.directory)) throw new Error('Explicit fresh SDK directory required');
  const directory = values.directory;
  await mkdir(directory, { mode: 0o700 });
  const bytes = await fetchSignerBytes();
  const zip = path.join(directory, 'sdk.zip');
  await writeFile(zip, bytes, { flag: 'wx' });
  await run('/usr/bin/ditto', ['-x', '-k', zip, directory]);
  console.log(JSON.stringify({ version: '2.10.0', sha256: signerSHA256, signTool: path.join(directory, 'bin/sign_update') }));
}
