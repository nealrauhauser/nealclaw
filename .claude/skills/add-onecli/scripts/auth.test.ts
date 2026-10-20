import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const exec = vi.hoisted(() => vi.fn());
vi.mock('node:child_process', () => ({ execFileSync: exec, spawnSync: vi.fn() }));
const select = vi.hoisted(() => vi.fn());
vi.mock('@clack/prompts', () => ({ select, password: vi.fn(), isCancel: () => false, log: { success: vi.fn() } }));
import { run } from './auth.js';

let dir: string;
const cwd = process.cwd();
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'onecli-auth-'));
  process.chdir(dir);
  process.argv[2] = 'claude';
});
afterEach(() => {
  process.chdir(cwd);
  fs.rmSync(dir, { recursive: true, force: true });
  delete process.env.NANOCLAW_ANTHROPIC_BASE_URL;
  delete process.env.NANOCLAW_ANTHROPIC_AUTH_TOKEN;
  vi.resetAllMocks();
});

it('connects a keyless self-hosted endpoint without prompting or storing a secret', async () => {
  process.env.NANOCLAW_ANTHROPIC_BASE_URL = 'http://host.docker.internal:11434';
  await run();
  expect(fs.readFileSync('.env', 'utf8')).toBe('ANTHROPIC_BASE_URL=http://host.docker.internal:11434\n');
  expect(exec).not.toHaveBeenCalled();
  expect(select).not.toHaveBeenCalled();
});

it('reuses the endpoint already in .env on a re-run', async () => {
  fs.writeFileSync('.env', 'ANTHROPIC_BASE_URL=http://host.docker.internal:11434\n');
  await run();
  expect(exec).not.toHaveBeenCalled();
  expect(select).not.toHaveBeenCalled();
});
