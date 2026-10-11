import { publicKeyObject, repository } from './appcast.mjs';

export function parseReleaseTag(tag) {
  if (typeof tag !== 'string' || tag.length > 80) throw new Error('Invalid application release tag');
  const match = /^(beta-)?v(\d+\.\d+(?:\.\d+)?)(?:-b([1-9]\d*))?$/.exec(tag);
  if (!match || Boolean(match[1]) !== Boolean(match[3]) || match[2].split('.').some(n => !Number.isSafeInteger(Number(n)))) throw new Error('Invalid application release tag');
  const build = match[3] ? Number(match[3]) : null;
  if (build !== null && !Number.isSafeInteger(build)) throw new Error('Invalid application build number');
  return { tag, channel: match[1] ? 'beta' : 'stable', version: match[2], ...(build === null ? {} : { build }) };
}

export function assertMainPublisher(context) {
  if (context.repository !== repository || context.ref !== 'refs/heads/main'
      || !['workflow_dispatch', 'repository_dispatch'].includes(context.eventName)
      || !/^[0-9a-f]{40}$/.test(context.automationSHA)
      || !/^[1-9]\d*$/.test(context.runId) || !/^[1-9]\d*$/.test(context.runAttempt)) throw new Error('Publishing requires a trusted main workflow event');
}

export function assertEnvironmentPolicy(environment, policies, channel) {
  if (!['stable', 'beta'].includes(channel) || environment?.name !== `crux-app-${channel}`) throw new Error('Required channel environment is missing or mismatched');
  const branch = environment.deployment_branch_policy;
  if (branch?.protected_branches !== false || branch?.custom_branch_policies !== true
      || !Array.isArray(policies) || policies.length !== 1 || policies[0].type !== 'branch' || policies[0].name !== 'main') throw new Error('Release environment must allow only the main branch, never tags or wildcards');
  const reviewed = environment.protection_rules?.some(rule => rule.type === 'required_reviewers'
    && Array.isArray(rule.reviewers) && rule.reviewers.some(r => ['User', 'Team'].includes(r.type) && Number.isSafeInteger(r.reviewer?.id) && r.reviewer.id > 0));
  if (!reviewed) throw new Error('Release environment requires human approval');
}

export async function planRelease({ tag, publicKey, signingMode, context, metadata, publication = true }) {
  const parsed = parseReleaseTag(tag);
  publicKeyObject(publicKey);
  if (!['adhoc', 'developer-id'].includes(signingMode)) throw new Error('Invalid signing mode');
  if (!/^[0-9a-f]{40}$/.test(metadata.sourceSHA) || !/^[0-9a-f]{40}$/.test(metadata.mainSHA)
      || !['ahead', 'identical'].includes(metadata.comparison)) throw new Error('Release tag is not in main history');
  if (publication) {
    assertMainPublisher(context);
    if (!metadata.mainProtected || !['ahead', 'identical'].includes(metadata.automationComparison)) throw new Error('Publishing requires protected main history for automation');
    assertEnvironmentPolicy(metadata.environment, metadata.policies, parsed.channel);
  }
  return { ...parsed, publicKey, signingMode, sourceSHA: metadata.sourceSHA, automationSHA: context.automationSHA,
    runId: context.runId, runAttempt: context.runAttempt, environment: `crux-app-${parsed.channel}`, publication };
}
