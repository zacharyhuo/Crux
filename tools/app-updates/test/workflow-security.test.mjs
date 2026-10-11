import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const load = name => JSON.parse(execFileSync('ruby', ['-r', 'yaml', '-r', 'json', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
  fileURLToPath(new URL(`../../../.github/workflows/${name}`, import.meta.url))], { encoding: 'utf8' }));
const release = load('release.yml'), notes = load('app-update-notes.yml'), request = load('app-update-notes-request.yml'), ci = load('ci.yml');

test('hosted CI tests use the isolated Beta configuration and an existing welcome UI case', () => {
  const runs = ci.jobs['build-and-test'].steps.map(step => step.run ?? '');
  for (const action of ['build-for-testing', 'test-without-building']) {
    const command = runs.find(run => run.includes(`xcodebuild ${action}`));
    assert.ok(command, `CI must ${action}`);
    assert.match(command, /-scheme\s+['"]Crux Beta['"]/);
    assert.match(command, /-configuration\s+BetaDebug/);
  }
  const command = runs.find(run => run.includes('xcodebuild test-without-building'));
  assert.match(command, /-only-testing:CruxUITests\/CruxUITests\/testWelcomeTabUsesTheNewPrimaryActions\b/);
});

function audit(workflow, privilegedJob) {
  assert.equal(workflow.permissions.contents, 'read');
  assert.ok(!JSON.stringify(workflow.env ?? {}).includes('secrets.'));
  for (const [name, job] of Object.entries(workflow.jobs)) {
    const body = JSON.stringify(job);
    for (const step of job.steps ?? []) {
      if (step.uses) assert.match(step.uses, /^actions\/[\w-]+@[0-9a-f]{40}$/);
    }
    if (name !== privilegedJob) {
      assert.ok(!body.includes('secrets.'), `${name} must not receive signing credentials`);
      if (name !== 'request') assert.equal(job.permissions?.contents ?? workflow.permissions.contents, 'read');
      continue;
    }
    assert.equal(job.environment.name, '${{ needs.plan.outputs.environment }}');
    assert.ok([job.needs].flat().includes('plan'));
    assert.equal(job.permissions.contents, 'write');
    assert.ok(job.if.includes("github.ref == 'refs/heads/main'"));
    const steps = job.steps;
    assert.equal(steps.at(-1).env.SPARKLE_PRIVATE_KEY, '${{ secrets.SPARKLE_PRIVATE_KEY }}');
    assert.ok(steps.slice(0, -1).every(step => !JSON.stringify(step).includes('secrets.')));
    assert.ok(!body.includes('SPARKLE_STABLE_PRIVATE_KEY') && !body.includes('SPARKLE_BETA_PRIVATE_KEY'));
    assert.ok(!body.includes('-resolvePackageDependencies') && !body.includes('swift test') && !body.includes('npm '));
    assert.ok(steps.some(step => step.run?.includes('preflight.mjs') && step.run.includes('--publication')));
    for (const step of steps.filter(step => step.uses?.startsWith('actions/checkout@'))) {
      assert.ok(['${{ needs.plan.outputs.automation_sha }}', '${{ github.workflow_sha }}'].includes(step.with.ref));
      assert.equal(step.with['persist-credentials'], false);
    }
  }
}

test('actual release, notes and CI workflows pin Actions; only main-gated final steps receive a channel key', () => {
  audit(release, 'sign-publish'); audit(notes, 'refresh'); audit(request); audit(ci);
  for (const workflow of [release, notes]) {
    assert.equal(workflow.concurrency.group, 'crux-app-update-publication');
    assert.equal(workflow.concurrency.queue, 'max');
    assert.equal(workflow.concurrency['cancel-in-progress'], false);
  }
  assert.ok(release.jobs['sign-publish'].if.includes("github.event_name == 'workflow_dispatch'"));
  assert.equal(release.jobs.build.environment, undefined);
  const download = release.jobs['sign-publish'].steps.find(step => step.uses?.startsWith('actions/download-artifact@'));
  assert.equal(download.with['artifact-ids'], '${{ needs.build.outputs.artifact_id }}');
  assert.equal(release.jobs.build.outputs.run_attempt, '${{ steps.pack.outputs.run_attempt }}');
  assert.equal(release.jobs['sign-publish'].steps.find(step => step.env?.EXPECTED_RUN_ATTEMPT).env.EXPECTED_RUN_ATTEMPT, '${{ needs.build.outputs.run_attempt }}');
  for (const job of [release.jobs['sign-publish'], notes.jobs.refresh]) {
    assert.ok(job.steps.some(step => step.run?.includes('.publicKey') && step.run.includes('SPARKLE_PUBLIC_ED_KEY')));
  }
  assert.ok(release.jobs['sign-publish'].steps.some(step => step.run?.includes('artifact.mjs') && step.run.includes('--sha256')));
  assert.equal(notes.on?.release ?? notes.true?.release, undefined);
});

test('regression: build-key exposure, missing approval binding, tag checkout or mutable Action breaks the audit', () => {
  const changes = [
    w => { w.jobs.build.env.SPARKLE_PRIVATE_KEY = '${{ secrets.SPARKLE_PRIVATE_KEY }}'; },
    w => { delete w.jobs['sign-publish'].environment; },
    w => { w.jobs['sign-publish'].steps[0].with.ref = '${{ inputs.tag }}'; },
    w => { w.jobs['sign-publish'].steps[0].uses = 'actions/checkout@v6'; },
    w => { w.jobs['sign-publish'].steps[1].env = { STABLE_PRIVATE: '${{ secrets.SPARKLE_STABLE_PRIVATE_KEY }}' }; }
  ];
  for (const change of changes) { const copy = structuredClone(release); change(copy); assert.throws(() => audit(copy, 'sign-publish')); }
});

test('notes verify established provenance and ZIP identity in a no-key step before the key-bearing publisher', () => {
  const steps = notes.jobs.refresh.steps;
  const check = steps.findIndex(step => step.run?.includes('publish.mjs') && step.run.includes('--verify-only'));
  assert.ok(check >= 0 && check < steps.length - 1);
  assert.ok(!JSON.stringify(steps[check]).includes('secrets.'));
  assert.ok(steps[check].run.includes('--tag "$RELEASE_TAG"'));
  assert.ok(!steps.at(-1).run.includes('--approved-plan') && !steps.at(-1).run.includes('--candidate-receipt'));
});
