import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inspectReadiness } from '../readiness.mjs';

const env = name => ({ name, deployment_branch_policy: { protected_branches: false, custom_branch_policies: true },
  protection_rules: [{ type: 'required_reviewers', reviewers: [{ type: 'User', reviewer: { id: 1 } }] }] });
function api({ misplaced = [], environmentMissing = false } = {}) {
  return async endpoint => {
    if (!endpoint) return { private: true };
    if (endpoint === '/branches/main') return { protected: true };
    if (endpoint.startsWith('/actions/secrets')) return { total_count: misplaced.length, secrets: misplaced.map(name => ({ name })) };
    if (endpoint.startsWith('/actions/variables')) return { total_count: 2, variables: ['BETA', 'STABLE'].map((channel, i) => ({ name: `SPARKLE_${channel}_PUBLIC_KEY`, value: Buffer.alloc(32, i + 1).toString('base64') })) };
    if (endpoint.endsWith('/deployment-branch-policies')) return { branch_policies: [{ name: 'main', type: 'branch' }] };
    if (endpoint.includes('/secrets?')) return { total_count: 1, secrets: [{ name: 'SPARKLE_PRIVATE_KEY' }] };
    if (endpoint.startsWith('/environments/')) return environmentMissing ? null : env(endpoint.split('/').at(-1));
    throw new Error('Unexpected API');
  };
}

test('owner readiness audit distinguishes private hosting from correctly isolated credential metadata', async () => {
  const result = await inspectReadiness(api());
  assert.equal(result.securityConfigurationReady, true);
  assert.equal(result.anonymousHostingReady, false);
  assert.ok(!JSON.stringify(result).includes(Buffer.alloc(32, 1).toString('base64')));
});

test('misplaced repository credentials or missing channel environments cannot be declared ready', async () => {
  for (const options of [{ misplaced: ['SPARKLE_PRIVATE_KEY'] }, { misplaced: ['SPARKLE_STABLE_PRIVATE_KEY'] }, { environmentMissing: true }]) {
    const result = await inspectReadiness(api(options));
    assert.equal(result.securityConfigurationReady, false);
    assert.ok(result.issues.length);
  }
});
