import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { repository, publicKeyObject } from './appcast.mjs';
import { assertEnvironmentPolicy } from './release-policy.mjs';
import { run } from './process.mjs';

const restricted = ['SPARKLE_PRIVATE_KEY', 'SPARKLE_STABLE_PRIVATE_KEY', 'SPARKLE_BETA_PRIVATE_KEY',
  'DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64', 'DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD', 'RELEASE_KEYCHAIN_PASSWORD',
  'APPLE_DEVELOPMENT_TEAM',
  'APP_STORE_CONNECT_API_KEY_P8_BASE64', 'APP_STORE_CONNECT_API_KEY_ID', 'APP_STORE_CONNECT_API_ISSUER_ID'];

// Run with an existing repository-admin gh session. Metadata only: never reads
// secret values, credentials on disk, or a personal Keychain. This catches
// repository-secret fallback/misplacement before any long-term key is used.
export async function inspectReadiness(api) {
  const repo = await api(''), main = await api('/branches/main');
  const repoSecrets = await api('/actions/secrets?per_page=100'), variables = await api('/actions/variables?per_page=100');
  if (repoSecrets.total_count > 100 || variables.total_count > 100) throw new Error('Metadata audit requires pagination before it can certify readiness');
  const issues = [];
  if (!main.protected) issues.push('Protect main before signing releases');
  const misplaced = repoSecrets.secrets.filter(secret => restricted.includes(secret.name)).map(secret => secret.name);
  if (misplaced.length) issues.push('Move signing credentials out of Repository Secrets into their protected channel environment');
  const keys = Object.fromEntries(variables.variables.map(v => [v.name, v.value]));
  const channels = [];
  for (const channel of ['beta', 'stable']) {
    const publicKey = keys[channel === 'beta' ? 'SPARKLE_BETA_PUBLIC_KEY' : 'SPARKLE_STABLE_PUBLIC_KEY'];
    let publicKeyConfigured = false;
    try { publicKeyObject(publicKey); publicKeyConfigured = true; } catch { issues.push(`Configure ${channel} public key variable`); }
    const environment = await api(`/environments/crux-app-${channel}`, true);
    if (!environment) {
      issues.push(`Create protected crux-app-${channel} environment`);
      channels.push({ channel, publicKeyConfigured, environmentConfigured: false, privateKeyConfigured: false });
      continue;
    }
    const policies = await api(`/environments/crux-app-${channel}/deployment-branch-policies`);
    let environmentConfigured = true;
    try { assertEnvironmentPolicy(environment, policies.branch_policies, channel); }
    catch (error) { environmentConfigured = false; issues.push(`${channel}: ${error.message}`); }
    const secrets = await api(`/environments/crux-app-${channel}/secrets?per_page=100`);
    if (secrets.total_count > 100) throw new Error('Environment secret metadata audit requires pagination');
    const privateKeyConfigured = secrets.secrets.some(secret => secret.name === 'SPARKLE_PRIVATE_KEY');
    if (!privateKeyConfigured) issues.push(`Configure SPARKLE_PRIVATE_KEY inside crux-app-${channel}`);
    channels.push({ channel, publicKeyConfigured, environmentConfigured, privateKeyConfigured });
  }
  if (keys.SPARKLE_BETA_PUBLIC_KEY && keys.SPARKLE_BETA_PUBLIC_KEY === keys.SPARKLE_STABLE_PUBLIC_KEY) issues.push('Stable and Beta public keys must differ');
  return { repository, mainProtected: main.protected, repositoryCredentialsMisplaced: misplaced, channels,
    securityConfigurationReady: issues.length === 0, anonymousHostingReady: !repo.private, issues,
    manualChecks: ['Strong GitHub account authentication', 'Encrypted key backup and recovery plan', 'Review the exact candidate before environment approval'],
    limitation: 'Metadata readiness does not prove key pairing, CI permission compatibility or real HTTPS installation' };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const api = async (endpoint, missing = false) => {
    try { return JSON.parse(await run('gh', ['api', `repos/${repository}${endpoint}`])); }
    catch (error) { if (missing && error.message.includes('HTTP 404')) return null; throw error; }
  };
  console.log(JSON.stringify(await inspectReadiness(api), null, 2));
}
