import { parseArgs } from 'node:util';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { repository, updateBranch, makeRecord, makeAppcast, addRecord, sha256, verifySignedFeed, verifyChannelState, publicKeyObject } from './appcast.mjs';
import { run } from './process.mjs';
import { validateBuildReceipt } from './artifact.mjs';
import { assertMainPublisher, parseReleaseTag } from './release-policy.mjs';
import { inspectUpdateArchive } from './candidate.mjs';

// These inputs come from the protected full Release job's local, previously
// verified candidate transport, never from downloaded Release metadata.
function validateApproval(approval, release, build, publicKey) {
  const { plan, receipt, context, payload } = approval;
  assertMainPublisher(context);
  if (context.eventName !== 'workflow_dispatch' || context.workflowRef !== `${repository}/.github/workflows/release.yml@refs/heads/main`
      || plan.publication !== true || plan.tag !== release.tag_name || plan.publicKey !== publicKey
      || plan.automationSHA !== context.automationSHA || plan.runId !== context.runId || plan.runAttempt !== context.runAttempt
      || plan.signingMode !== build.signingMode || !Buffer.isBuffer(payload) || payload.length !== receipt.bytes) throw new Error('First promotion requires the approved full Release workflow receipt');
  validateBuildReceipt(receipt, { ...parseReleaseTag(plan.tag), sourceSHA: plan.sourceSHA, automationSHA: context.automationSHA,
    runId: context.runId, runAttempt: receipt.runAttempt, publicKey, signingMode: plan.signingMode, sha256: sha256(payload) });
}

export async function publishUpdate({ releaseId, build, tag, directory: artifactDirectory, publicKey, signTool, keyFile, approval, verifyOnly = false, runCommand = run }) {
  if (!/^[1-9]\d*$/.test(String(releaseId))) throw new Error('Use an exact GitHub Release ID');
  publicKeyObject(publicKey);
  const gh = async (endpoint, body, missing = false) => {
    try {
      const text = await runCommand('gh', ['api', `repos/${repository}${endpoint}`, ...(body ? ['--method', 'POST', '--input', '-'] : [])], body ? JSON.stringify(body) : undefined);
      return text ? JSON.parse(text) : null;
    } catch (error) { if (missing && error.message.includes('HTTP 404')) return null; throw error; }
  };
  const ref = await gh(`/git/ref/heads/${updateBranch}`, null, true), head = ref?.object?.sha ?? null;
  if (head !== null && !/^[0-9a-f]{40}$/.test(head)) throw new Error('Invalid update branch');
  const release = await gh(`/releases/${releaseId}`);
  if (release.id !== Number(releaseId) || (tag !== undefined && release.tag_name !== tag)) throw new Error('Selected Release/tag changed');
  const { channel, version } = parseReleaseTag(release.tag_name);
  let state = { schemaVersion: 1, channel, releases: [] }, previous;
  if (head) {
    previous = await gh(`/git/commits/${head}`);
    const response = await gh(`/contents/${channel}/state.json?ref=${head}`, null, true);
    if (response) {
      if (response.type !== 'file' || response.encoding !== 'base64' || response.size > 1024 * 1024) throw new Error('Invalid channel ledger response');
      state = JSON.parse(Buffer.from(response.content, 'base64').toString());
      const feed = await gh(`/contents/${channel}/appcast.xml?ref=${head}`, null, true);
      if (!feed || feed.type !== 'file' || feed.encoding !== 'base64' || feed.size > 4 * 1024 * 1024) {
        throw new Error('Channel ledger requires its authenticated signed feed');
      }
      const signed = Buffer.from(feed.content, 'base64');
      if (signed.length !== feed.size) throw new Error('Invalid persisted signed feed size');
      verifyChannelState(signed, state, publicKey);
    } else if (await gh(`/contents/${channel}/appcast.xml?ref=${head}`, null, true)) {
      throw new Error('Signed feed without its channel ledger requires reviewed recovery');
    }
  }
  makeAppcast(state); // Validate the authoritative ledger before using its identity.
  if (state.channel !== channel) throw new Error('Mixed channel ledger');
  const existing = state.releases.find(old => old.releaseId === Number(releaseId));
  if (existing) {
    build = { channel, identifier: existing.bundleIdentifier, version: existing.version, build: existing.build,
      minimumSystemVersion: existing.minimumSystemVersion, publicKey, signingMode: existing.signingMode, ...existing.artifact };
  } else {
    if (!approval) throw new Error('First promotion requires an approved full Release workflow receipt; notes retry cannot prove provenance');
    if (!build || build.publicKey !== publicKey) throw new Error('Build key does not match the configured channel public key');
    validateApproval(approval, release, build, publicKey);
  }
  const file = `${channel === 'beta' ? 'Crux-Beta' : 'Crux'}-${version}-arm64.zip`;
  if (build.channel !== channel || build.file !== file) throw new Error('Invalid build metadata');
  const directory = path.resolve(artifactDirectory), archive = path.join(directory, build.file);
  const bytes = await readFile(archive);
  if (bytes.length !== build.bytes || sha256(bytes) !== build.sha256) throw new Error('Local archive differs from signed build');
  const asset = release.assets.find(a => a.name === build.file);
  if (!asset) throw new Error('Upload the signed update package before appcast promotion');
  // Read back the actual GitHub asset through gh's existing authentication. A
  // fresh child directory prevents replacement of any local or user-owned file.
  const downloaded = await mkdtemp(path.join(directory, 'readback-'));
  await runCommand('gh', ['release', 'download', release.tag_name, '--repo', repository, '--pattern', build.file, '--dir', downloaded]);
  const remoteBytes = await readFile(path.join(downloaded, build.file));
  if (remoteBytes.length !== bytes.length || sha256(remoteBytes) !== build.sha256) throw new Error('Uploaded update package checksum mismatch');
  const record = makeRecord({ release, bundle: build, artifact: asset, bytes: remoteBytes, signature: build.signature, signingMode: build.signingMode });
  const identity = await inspectUpdateArchive(remoteBytes, { tag: release.tag_name, channel: build.channel, publicKey }, runCommand);
  for (const key of ['identifier', 'version', 'build', 'minimumSystemVersion']) {
    if (identity[key] !== build[key]) throw new Error('ZIP archive identity differs from release metadata');
  }
  const next = addRecord(state, record);
  const ledger = JSON.stringify(next, null, 2) + '\n';
  if (Buffer.byteLength(ledger) > 1024 * 1024) throw new Error('Channel ledger requires a reviewed history retention migration');
  if (verifyOnly) return { status: 'verified', channel, releaseId: record.releaseId };
  if (JSON.stringify(next) === JSON.stringify(state)) return { status: 'unchanged', releaseId: record.releaseId };
  if (!signTool || !keyFile) throw new Error('Explicit sign tool and key file are required for feed promotion');
  const feed = path.join(downloaded, 'appcast.xml');
  await writeFile(feed, makeAppcast(next), { flag: 'wx' });
  // Signed feeds also bind the embedded notes to the channel's EdDSA key.
  await runCommand(path.resolve(signTool), ['--ed-key-file', path.resolve(keyFile), '-p', feed]);
  const signedFeed = await readFile(feed);
  verifySignedFeed(signedFeed, publicKey);
  const tree = await gh('/git/trees', { ...(previous ? { base_tree: previous.tree.sha } : {}), tree: [
    { path: `${build.channel}/state.json`, mode: '100644', type: 'blob', content: ledger },
    { path: `${build.channel}/appcast.xml`, mode: '100644', type: 'blob', content: signedFeed.toString('utf8') }
  ] });
  const commit = await gh('/git/commits', { message: `Publish ${build.channel} app update ${record.tag}`, tree: tree.sha, parents: head ? [head] : [] });
  const current = await gh(`/git/ref/heads/${updateBranch}`, null, true);
  if ((current?.object?.sha ?? null) !== head) throw new Error('Update feed changed; retry from a fresh publisher directory');
  if (head) await runCommand('gh', ['api', `repos/${repository}/git/refs/heads/${updateBranch}`, '--method', 'PATCH', '--input', '-'], JSON.stringify({ sha: commit.sha, force: false }));
  else await gh('/git/refs', { ref: `refs/heads/${updateBranch}`, sha: commit.sha });
  return { status: 'published', channel: build.channel, releaseId: record.releaseId, commit: commit.sha, signedFeed: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: { release: { type: 'string' }, build: { type: 'string' }, tag: { type: 'string' }, directory: { type: 'string' },
    'sign-tool': { type: 'string' }, 'key-file': { type: 'string' }, 'approved-plan': { type: 'string' }, 'candidate-receipt': { type: 'string' }, 'candidate-payload': { type: 'string' }, 'verify-only': { type: 'boolean', default: false } } });
  if (!values.release || !values.directory || (!values['verify-only'] && (!values['sign-tool'] || !values['key-file']))) throw new Error('Release ID, artifact directory and explicit signing options (or verify-only) are required');
  let approval;
  if (values['approved-plan'] || values['candidate-receipt'] || values['candidate-payload']) {
    if (!values['approved-plan'] || !values['candidate-receipt'] || !values['candidate-payload']) throw new Error('Trusted approval, candidate receipt and candidate payload are required');
    approval = { plan: JSON.parse(await readFile(values['approved-plan'])), receipt: JSON.parse(await readFile(values['candidate-receipt'])),
      payload: await readFile(values['candidate-payload']),
      context: { repository: process.env.GITHUB_REPOSITORY, ref: process.env.GITHUB_REF, eventName: process.env.GITHUB_EVENT_NAME,
        automationSHA: process.env.GITHUB_WORKFLOW_SHA, runId: process.env.GITHUB_RUN_ID, runAttempt: process.env.GITHUB_RUN_ATTEMPT, workflowRef: process.env.GITHUB_WORKFLOW_REF } };
  }
  console.log(JSON.stringify(await publishUpdate({ releaseId: values.release, tag: values.tag, build: values.build ? JSON.parse(await readFile(values.build)) : undefined, directory: values.directory,
    publicKey: process.env.SPARKLE_PUBLIC_ED_KEY, signTool: values['sign-tool'], keyFile: values['key-file'], approval, verifyOnly: values['verify-only'] })));
}
