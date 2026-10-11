import { parseArgs } from 'node:util';
import { inspectCandidate } from './candidate.mjs';

const { values } = parseArgs({ options: { app: { type: 'string' }, tag: { type: 'string' }, channel: { type: 'string' }, 'public-key': { type: 'string' } } });
if (!values.app) throw new Error('Explicit candidate app required');
const { record } = await inspectCandidate(values.app, { tag: values.tag, channel: values.channel, publicKey: values['public-key'] });
console.log(JSON.stringify({ status: 'validated', ...record }));
