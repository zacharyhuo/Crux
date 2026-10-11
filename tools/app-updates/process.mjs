import { spawn } from 'node:child_process';

// No shell expansion; bound both output streams and subprocess lifetime.
export function run(command, args, input, { timeout = 120_000, binary = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = [];
    let count = 0, error;
    const timer = setTimeout(() => { error = new Error(`${command} timed out`); child.kill('SIGKILL'); }, timeout);
    const collect = destination => bytes => {
      count += bytes.length;
      if (count > 4 * 1024 * 1024) { error = new Error(`${command} exceeded output limit`); child.kill('SIGKILL'); }
      else destination.push(bytes);
    };
    child.stdout.on('data', collect(stdout));
    child.stderr.on('data', collect(stderr));
    child.stdin.on('error', err => { if (err.code !== 'EPIPE') error = err; });
    child.once('error', err => { error = err; });
    child.once('close', code => {
      clearTimeout(timer);
      const diagnostic = Buffer.concat(stderr).toString();
      const excerpt = diagnostic.length > 3000 ? diagnostic.slice(0, 1000) + '\n…\n' + diagnostic.slice(-2000) : diagnostic;
      if (error || code !== 0) reject(error ?? new Error(`${command} failed (${code}): ${excerpt}`));
      else resolve(binary ? Buffer.concat(stdout) : Buffer.concat(stdout).toString());
    });
    child.stdin.end(input);
  });
}
