import { parseArgs } from 'node:util';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { repository } from './appcast.mjs';
import { run } from './process.mjs';
import { parseReleaseTag } from './release-policy.mjs';

const { values } = parseArgs({ options: { tag: { type: 'string' }, directory: { type: 'string' } } });
if (!/^(?:v\d+\.\d+(?:\.\d+)?|beta-v\d+\.\d+(?:\.\d+)?-b[1-9]\d*)$/.test(values.tag ?? '') || !values.directory) throw new Error('Explicit valid release tag and fresh directory are required');
const directory = path.resolve(values.directory);
await mkdir(directory); // no replacement of prior assets
const release = JSON.parse(await run('gh', ['api', `repos/${repository}/releases/tags/${values.tag}`]));
if (release.draft || release.prerelease !== values.tag.startsWith('beta-') || release.tag_name !== values.tag) throw new Error('Release channel mismatch');
// The notes path never consumes unsigned update-build.json as authority.
const { channel, version } = parseReleaseTag(values.tag);
const file = `${channel === 'beta' ? 'Crux-Beta' : 'Crux'}-${version}-arm64.zip`;
await run('gh', ['release', 'download', values.tag, '--repo', repository, '--pattern', file, '--dir', directory]);
console.log(JSON.stringify({ releaseId: release.id, channel }));
