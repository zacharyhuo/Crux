import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertRuntimeSigning } from '../runtime-signing.mjs';

const adhoc = { adhoc: true, hardenedRuntime: true };
const sandbox = { 'com.apple.security.app-sandbox': true };
const local = { ...sandbox, 'com.apple.security.cs.disable-library-validation': true };
const certificate = { adhoc: false, hardenedRuntime: true, team: 'ABCDE12345' };

test('regression: individually valid ad-hoc app and Sparkle signatures still fail library validation', () => {
  assert.throws(() => assertRuntimeSigning(adhoc, adhoc, sandbox), /Ad-hoc app cannot load Sparkle/);
  assert.doesNotThrow(() => assertRuntimeSigning(adhoc, adhoc, local));
});

test('certificate distribution requires matching framework identity and excludes the local exception', () => {
  assert.doesNotThrow(() => assertRuntimeSigning(certificate, certificate, sandbox));
  for (const framework of [adhoc, { ...certificate, team: 'OTHER12345' }])
    assert.throws(() => assertRuntimeSigning(certificate, framework, sandbox), /same Team ID/);
  assert.throws(() => assertRuntimeSigning(certificate, certificate, local), /no ad-hoc exception/);
});

test('local exception does not allow disabling runtime, sandbox or enabling debugger access', () => {
  assert.throws(() => assertRuntimeSigning({ ...adhoc, hardenedRuntime: false }, adhoc, local));
  assert.throws(() => assertRuntimeSigning(adhoc, adhoc, { ...local, 'com.apple.security.app-sandbox': false }));
  assert.throws(() => assertRuntimeSigning(adhoc, adhoc, { ...local, 'com.apple.security.get-task-allow': true }));
});
