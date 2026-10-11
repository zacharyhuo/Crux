import { parseArgs } from 'node:util';
import { parseReleaseTag } from './release-policy.mjs';
import { repository } from './appcast.mjs';
import { run } from './process.mjs';

const { values } = parseArgs({ options: { tag: { type: 'string' } } });
const { tag } = parseReleaseTag(values.tag);
// The release event only forwards data; it cannot access either signing key.
await run('gh', ['api', `repos/${repository}/dispatches`, '--method', 'POST', '--input', '-'], JSON.stringify({ event_type: 'crux-app-notes', client_payload: { tag } }));
console.log(JSON.stringify({ status: 'requested', tag }));
