import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchSignerBytes, signerURL } from '../fetch-signer.mjs';

test('signing tool comes only from the fixed official URL and rejects substituted bytes before extraction', async () => {
  await assert.rejects(fetchSignerBytes(async url => { assert.equal(url, signerURL); return new Response('substituted binary'); }), /checksum mismatch/);
  await assert.rejects(fetchSignerBytes(async () => new Response('error', { status: 404 })), /Cannot fetch/);
});

test('oversized signer responses are rejected before allocating the body', async () => {
  await assert.rejects(fetchSignerBytes(async () => new Response('small', { headers: { 'content-length': String(100 * 1024 * 1024 + 1) } })), /size limit/);
});
