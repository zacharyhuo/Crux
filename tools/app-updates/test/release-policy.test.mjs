import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseReleaseTag, assertMainPublisher, assertEnvironmentPolicy, planRelease } from '../release-policy.mjs';

const sha = 'a'.repeat(40), automation = 'b'.repeat(40);
const context = { repository: 'zacharyhuo/Crux', ref: 'refs/heads/main', eventName: 'workflow_dispatch', automationSHA: automation, runId: '123', runAttempt: '1' };
const environment = channel => ({ name: `crux-app-${channel}`, protection_rules: [{ type: 'required_reviewers', reviewers: [{ type: 'User', reviewer: { id: 1 } }] }],
  deployment_branch_policy: { protected_branches: false, custom_branch_policies: true } });
const policies = [{ name: 'main', type: 'branch' }];
const key = Buffer.alloc(32, 1).toString('base64');

test('tag parser binds stable/beta and rejects shell/path injection or invalid build numbers', () => {
  assert.deepEqual(parseReleaseTag('beta-v1.0-b2'), { tag: 'beta-v1.0-b2', channel: 'beta', version: '1.0', build: 2 });
  assert.equal(parseReleaseTag('v1.0.1').channel, 'stable');
  for (const tag of ['--help', '../main', 'v1.0;echo bad', 'v1.0\nBAD=1', 'beta-v1.0-b0', 'beta-v1.0-b999999999999999999999']) assert.throws(() => parseReleaseTag(tag));
});

test('publisher authority is a main event, never a tag, develop checkout, PR or foreign repository', () => {
  assert.doesNotThrow(() => assertMainPublisher(context));
  for (const changed of [{ ref: 'refs/tags/v1.0' }, { ref: 'refs/heads/develop/v1' }, { eventName: 'push' }, { eventName: 'pull_request_target' }, { repository: 'other/Crux' }, { automationSHA: 'main' }])
    assert.throws(() => assertMainPublisher({ ...context, ...changed }));
});

test('missing reviewers, wrong environment and wildcard/tag deployment policies fail closed', () => {
  for (const channel of ['beta', 'stable']) {
    assert.doesNotThrow(() => assertEnvironmentPolicy(environment(channel), policies, channel));
    assert.throws(() => assertEnvironmentPolicy({ ...environment(channel), protection_rules: [] }, policies, channel));
    assert.throws(() => assertEnvironmentPolicy(environment(channel === 'beta' ? 'stable' : 'beta'), policies, channel));
    for (const invalid of [[{ name: '*', type: 'branch' }], [{ name: 'main', type: 'tag' }], [...policies, { name: 'develop/*', type: 'branch' }]])
      assert.throws(() => assertEnvironmentPolicy(environment(channel), invalid, channel));
  }
});

test('release plan rejects a tag outside protected main history or an unprotected main branch', async () => {
  const metadata = { sourceSHA: sha, mainSHA: automation, mainProtected: true, comparison: 'ahead', automationComparison: 'identical', environment: environment('beta'), policies };
  const good = await planRelease({ tag: 'beta-v1.0-b2', publicKey: key, signingMode: 'adhoc', context, metadata });
  assert.equal(good.sourceSHA, sha);
  assert.equal(good.environment, 'crux-app-beta');
  for (const changed of [{ comparison: 'diverged' }, { mainProtected: false }, { automationComparison: 'behind' }, { environment: null }])
    await assert.rejects(planRelease({ tag: 'beta-v1.0-b2', publicKey: key, signingMode: 'adhoc', context, metadata: { ...metadata, ...changed } }));
});
