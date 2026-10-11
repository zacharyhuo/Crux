import { createHash, createPublicKey, verify } from 'node:crypto';

export const repository = 'zacharyhuo/Crux';
export const updateBranch = 'app-updates';
const SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const xml = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
const cdata = value => '<![CDATA[' + value.replaceAll(']]>', ']]]]><![CDATA[>') + ']]>';
export const sha256 = data => createHash('sha256').update(data).digest('hex');
export const publicKeyObject = key => {
  const bytes = Buffer.from(key, 'base64');
  if (bytes.length !== 32 || bytes.toString('base64') !== key) throw new Error('Invalid Ed25519 public key');
  return createPublicKey({ format: 'der', type: 'spki', key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), bytes]) });
};

export function verifyArchive(bytes, signature, publicKey) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > 1024 ** 3) throw new Error('Invalid update archive size');
  const decoded = Buffer.from(signature, 'base64');
  if (decoded.length !== 64 || decoded.toString('base64') !== signature || !verify(null, bytes, publicKeyObject(publicKey), decoded)) throw new Error('Update archive EdDSA verification failed');
}

// Sparkle 2.10's SPUExtractAppcastContent format: sign the bytes preceding
// the final signature comment. Validate with the CONFIGURED public key,
// not merely the key used by sign_update (which could be a mistaken Secret).
export function verifySignedFeed(bytes, publicKey) {
  if (!Buffer.isBuffer(bytes) || bytes.length > 4 * 1024 * 1024) throw new Error('Invalid signed feed size');
  const prefix = Buffer.from('<!-- sparkle-signatures:\n');
  const start = bytes.lastIndexOf(prefix);
  if (start < 0) throw new Error('Unsigned update feed');
  const block = bytes.subarray(start).toString('utf8');
  const match = /^<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([1-9]\d*)\n-->\s*$/.exec(block);
  if (!match || Number(match[2]) !== start) throw new Error('Invalid signed feed block');
  verifyArchive(bytes.subarray(0, start), match[1], publicKey);
  return bytes.subarray(0, start);
}

// Authenticate the full publication ledger, including fields not rendered in
// RSS. A branch writer cannot turn edited history into an approved signed feed.
export function verifyChannelState(bytes, state, publicKey) {
  const authenticated = verifySignedFeed(bytes, publicKey);
  if (!authenticated.equals(Buffer.from(makeAppcast(state)))) {
    throw new Error('Channel ledger does not match its authenticated signed feed');
  }
}

function validate(record) {
  const brand = record.channel === 'beta' ? 'Crux Beta' : 'Crux';
  const id = record.channel === 'beta' ? 'com.zacharyhuo.Crux.Beta' : 'com.zacharyhuo.Crux';
  if (!['stable', 'beta'].includes(record.channel) || record.bundleIdentifier !== id || record.name !== brand
      || !Number.isSafeInteger(record.build) || record.build < 1 || !/^\d+\.\d+(?:\.\d+)?$/.test(record.version)
      || !/^26(?:\.\d+){0,2}$/.test(record.minimumSystemVersion) || record.arch !== 'arm64') throw new Error('Invalid app update identity');
  const tag = record.channel === 'beta' ? `beta-v${record.version}-b${record.build}` : `v${record.version}`;
  const file = `${record.channel === 'beta' ? 'Crux-Beta' : 'Crux'}-${record.version}-arm64.zip`;
  if (!Number.isSafeInteger(record.releaseId) || record.releaseId < 1 || record.tag !== tag
      || record.pageURL !== `https://github.com/${repository}/releases/tag/${tag}`
      || record.artifact.url !== `https://github.com/${repository}/releases/download/${tag}/${file}`
      || record.artifact.file !== file || !/^[0-9a-f]{64}$/.test(record.artifact.sha256)
      || !Number.isSafeInteger(record.artifact.bytes) || record.artifact.bytes < 1 || record.artifact.bytes > 1024 ** 3
      || Buffer.from(record.artifact.signature, 'base64').length !== 64) throw new Error('Release/tag/archive binding mismatch');
  if (typeof record.notes !== 'string' || Buffer.byteLength(record.notes) > 128 * 1024 || /[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(record.notes)
      || record.notesSHA256 !== sha256(record.notes) || !Number.isFinite(new Date(record.publishedAt).getTime())) throw new Error('Invalid release notes binding');
  if (!['adhoc', 'developer-id'].includes(record.signingMode) || typeof record.notarized !== 'boolean'
      || (record.signingMode === 'adhoc' && record.notarized)) throw new Error('Invalid signing provenance');
  return record;
}

// The caller supplies the actual selected Release JSON, not /releases/latest.
export function makeRecord({ release, bundle, artifact, signature, bytes, signingMode }) {
  verifyArchive(bytes, signature, bundle.publicKey);
  const notes = typeof release.body === 'string' ? release.body : '';
  const record = {
    releaseId: release.id, tag: release.tag_name, pageURL: release.html_url,
    channel: bundle.channel, name: bundle.channel === 'beta' ? 'Crux Beta' : 'Crux',
    bundleIdentifier: bundle.identifier, version: bundle.version, build: bundle.build,
    minimumSystemVersion: bundle.minimumSystemVersion, arch: 'arm64',
    publishedAt: new Date(release.published_at).toISOString(), notes, notesSHA256: sha256(notes),
    signingMode, notarized: signingMode === 'developer-id',
    artifact: { file: artifact.name, url: artifact.browser_download_url, sha256: sha256(bytes), bytes: bytes.length, signature }
  };
  if (release.draft || release.prerelease !== (bundle.channel === 'beta') || artifact.state !== 'uploaded'
      || artifact.size !== bytes.length || (artifact.digest && artifact.digest !== `sha256:${record.artifact.sha256}`)) throw new Error('GitHub release is not a matching completed upload');
  return validate(record);
}

export function addRecord(previous, record) {
  validate(record);
  if (previous?.schemaVersion !== 1 || previous.channel !== record.channel || !Array.isArray(previous.releases)) throw new Error('Invalid channel ledger');
  if (previous.releases.length > 500) throw new Error('Channel ledger exceeds the supported release history');
  previous.releases.forEach(old => { validate(old); if (old.channel !== previous.channel) throw new Error('Mixed channel ledger'); });
  const existing = previous.releases.find(r => r.releaseId === record.releaseId);
  if (existing) {
    // Notes may be edited on the same Release; executable identity remains frozen.
    const immutable = ['tag', 'pageURL', 'channel', 'bundleIdentifier', 'version', 'build', 'minimumSystemVersion', 'arch', 'artifact', 'signingMode', 'notarized'];
    if (immutable.some(key => JSON.stringify(existing[key]) !== JSON.stringify(record[key]))) throw new Error('Immutable application release conflict');
    return { ...previous, releases: previous.releases.map(r => r.releaseId === record.releaseId ? record : r) };
  }
  if (previous.releases.some(r => r.build >= record.build)) throw new Error('CFBundleVersion must increase within its channel');
  const versionParts = version => version.split('.').map(Number);
  for (const old of previous.releases) {
    const a = versionParts(old.version), b = versionParts(record.version);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      if ((b[i] ?? 0) > (a[i] ?? 0)) break;
      if ((b[i] ?? 0) < (a[i] ?? 0)) throw new Error('Automatic application version downgrade rejected');
    }
  }
  return { ...previous, releases: [...previous.releases, record] };
}

export function makeAppcast(state) {
  if (state?.schemaVersion !== 1 || !['stable', 'beta'].includes(state.channel) || !Array.isArray(state.releases)) throw new Error('Invalid appcast state');
  const seen = new Set();
  const items = [...state.releases].sort((a, b) => b.build - a.build).map(record => {
    validate(record);
    if (record.channel !== state.channel || seen.has(record.build)) throw new Error('Mixed channel or duplicate build');
    seen.add(record.build);
    const notes = record.notes.trim() ? record.notes : `No release notes were provided for this version.\n\n[View this GitHub Release](${record.pageURL})`;
    return `<item><title>${xml(record.name)} ${xml(record.version)}</title><link>${xml(record.pageURL)}</link>`
      + `<pubDate>${new Date(record.publishedAt).toUTCString()}</pubDate><sparkle:version>${record.build}</sparkle:version>`
      + `<sparkle:shortVersionString>${xml(record.version)}</sparkle:shortVersionString>`
      + `<sparkle:minimumSystemVersion>${xml(record.minimumSystemVersion)}</sparkle:minimumSystemVersion>`
      + (state.channel === 'beta' ? '<sparkle:channel>beta</sparkle:channel>' : '')
      + `<sparkle:fullReleaseNotesLink>${xml(record.pageURL)}</sparkle:fullReleaseNotesLink>`
      + `<description sparkle:format="markdown">${cdata(notes)}</description>`
      + `<enclosure url="${xml(record.artifact.url)}" length="${record.artifact.bytes}" type="application/octet-stream" sparkle:edSignature="${xml(record.artifact.signature)}" /></item>`;
  });
  const stateDigest = sha256(Buffer.from(JSON.stringify(state)));
  return `<?xml version="1.0" encoding="utf-8"?>\n<!-- crux-state-sha256: ${stateDigest} -->\n<rss version="2.0" xmlns:sparkle="${SPARKLE}"><channel><title>Crux ${xml(state.channel)} updates</title>${items.join('\n')}</channel></rss>\n`;
}
