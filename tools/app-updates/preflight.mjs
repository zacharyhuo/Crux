import { parseArgs } from 'node:util';
import { appendFile } from 'node:fs/promises';
import { parseReleaseTag, planRelease, assertMainPublisher } from './release-policy.mjs';
import { repository } from './appcast.mjs';
import { run } from './process.mjs';

const { values } = parseArgs({ options: { tag: { type: 'string' }, 'signing-mode': { type: 'string', default: 'adhoc' }, publication: { type: 'boolean', default: false } } });
const parsed = parseReleaseTag(values.tag);
const context = { repository: process.env.GITHUB_REPOSITORY, ref: process.env.GITHUB_REF, eventName: process.env.GITHUB_EVENT_NAME,
  automationSHA: process.env.GITHUB_WORKFLOW_SHA, runId: process.env.GITHUB_RUN_ID, runAttempt: process.env.GITHUB_RUN_ATTEMPT };
if (values.publication) assertMainPublisher(context);
const api = async endpoint => JSON.parse(await run('gh', ['api', `repos/${repository}${endpoint}`]));
let object = (await api(`/git/ref/tags/${encodeURIComponent(parsed.tag)}`)).object;
for (let i = 0; object.type === 'tag' && i < 4; i++) object = (await api(`/git/tags/${object.sha}`)).object;
if (object.type !== 'commit' || !/^[0-9a-f]{40}$/.test(object.sha)) throw new Error('Tag must resolve to a commit');
const main = await api('/branches/main');
const comparison = await api(`/compare/${object.sha}...${main.commit.sha}`);
const metadata = { sourceSHA: object.sha, mainSHA: main.commit.sha, mainProtected: main.protected, comparison: comparison.status };
if (values.publication) {
  metadata.automationComparison = (await api(`/compare/${context.automationSHA}...${main.commit.sha}`)).status;
  metadata.environment = await api(`/environments/crux-app-${parsed.channel}`);
  metadata.policies = (await api(`/environments/crux-app-${parsed.channel}/deployment-branch-policies`)).branch_policies;
}
const publicKey = parsed.channel === 'beta' ? process.env.BETA_PUBLIC : process.env.STABLE_PUBLIC;
if (process.env.BETA_PUBLIC && process.env.BETA_PUBLIC === process.env.STABLE_PUBLIC) throw new Error('Stable and Beta must use different public keys');
const plan = await planRelease({ tag: parsed.tag, publicKey, signingMode: values['signing-mode'], context, metadata, publication: values.publication });
if (process.env.GITHUB_OUTPUT) {
  await appendFile(process.env.GITHUB_OUTPUT, Object.entries({ channel: plan.channel, environment: plan.environment, source_sha: plan.sourceSHA,
    automation_sha: plan.automationSHA, public_key: plan.publicKey }).map(([k, v]) => `${k}=${v}\n`).join(''));
}
console.log(JSON.stringify(plan, null, 2));
