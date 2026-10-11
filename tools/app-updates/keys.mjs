import { generateKeyPairSync } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import path from 'node:path';

const { values } = parseArgs({ options: { directory: { type: 'string' } } });
if (!values.directory || !path.isAbsolute(values.directory)) throw new Error('Choose an absolute NEW signing-key directory');
await mkdir(values.directory, { mode: 0o700 });
const pair = generateKeyPairSync('ed25519');
const seed = Buffer.from(pair.privateKey.export({ format: 'jwk' }).d, 'base64url');
const publicKey = Buffer.from(pair.publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
await writeFile(path.join(values.directory, 'private-key.txt'), seed.toString('base64') + '\n', { flag: 'wx', mode: 0o600 });
await writeFile(path.join(values.directory, 'public-key.txt'), publicKey + '\n', { flag: 'wx', mode: 0o644 });
console.log(JSON.stringify({ directory: values.directory, publicKey, privateKeyWritten: true, keychainAccess: false }, null, 2));
