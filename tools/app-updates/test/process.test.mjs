import { test } from 'node:test';
import assert from 'node:assert/strict';
import { run } from '../process.mjs';

test('bounded subprocess execution preserves the final diagnostic after progress output', async () => {
  await assert.rejects(run(process.execPath, ['-e', 'process.stderr.write("progress\\n".repeat(1000)+"FINAL_SIGNATURE_ERROR"); process.exitCode=1']), /FINAL_SIGNATURE_ERROR/);
});

test('subprocess timeout and spawn errors reject rather than hanging', async () => {
  await assert.rejects(run(process.execPath, ['-e', 'setInterval(()=>{},1000)'], undefined, { timeout: 30 }), /timed out/);
  await assert.rejects(run('/nonexistent-crux-test-command', []), /ENOENT/);
  assert.equal(await run(process.execPath, ['-e', 'process.stdout.write("中文")']), '中文');
});
