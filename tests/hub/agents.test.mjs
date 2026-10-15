import assert from 'node:assert/strict';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  AGENTS,
  AGENT_IDS,
  READONLY_PREAMBLE,
  SHELL,
  describeAgents,
  findExecutable,
  getAgent,
  headlessCommand,
  sessionArgv,
} from '../../scripts/hub/agents.mjs';

const DIR = '/work/projeto';
const PROMPT = 'Explique; "isto" $(echo x) `y` \\n fim';

test('catálogo tem seis agentes e o terminal', () => {
  assert.deepEqual(AGENT_IDS, ['copilot', 'claude', 'codex', 'agy', 'opencode', 'hermes']);
  assert.equal(new Set(AGENT_IDS).size, AGENT_IDS.length);
  for (const agent of AGENTS) assert.match(agent.color, /^#[0-9a-f]{6}$/);
  assert.equal(getAgent('shell'), SHELL);
  assert.equal(getAgent('inexistente'), null);
  assert.equal(describeAgents('').length, AGENTS.length + 1);
});

test('nenhum adaptador usa flags que liberam escrita ou desligam proteções', () => {
  const forbidden = /yolo|dangerous|full-auto|allow-all|bypass|accept-edits|auto-approve|workspace-write|--mode=auto/i;
  for (const agent of AGENTS) {
    const command = headlessCommand(agent.id, { prompt: 'x', dir: DIR });
    assert.ok(command, `${agent.id} sem comando headless`);
    for (const arg of command.args) assert.doesNotMatch(arg, forbidden, `${agent.id}: ${arg}`);
  }
});

test('cada agente recebe as travas de somente leitura documentadas', () => {
  const args = (id) => headlessCommand(id, { prompt: PROMPT, dir: DIR }).args;
  const pair = (list, a, b) => list.some((item, index) => item === a && list[index + 1] === b);

  assert.ok(args('copilot').includes('--deny-tool=write'));
  assert.ok(args('copilot').includes('--deny-tool=shell'));
  assert.ok(args('copilot').includes('--no-ask-user'));

  assert.ok(pair(args('claude'), '--permission-mode', 'dontAsk'));
  assert.ok(args('claude').includes('--allowedTools=Read,Grep,Glob'));
  assert.ok(args('claude').includes('--tools=Read,Grep,Glob'), 'o Claude só pode ter as ferramentas de leitura');

  assert.ok(pair(args('codex'), '-s', 'read-only'));
  assert.ok(pair(args('agy'), '--mode', 'plan'));
  assert.ok(pair(args('opencode'), '--agent', 'plan'));

  const hermes = args('hermes');
  assert.ok(pair(hermes, '-t', 'web,search'));
  const toolsets = hermes[hermes.indexOf('-t') + 1].split(',');
  for (const risky of ['file', 'terminal', 'code_execution', 'computer_use', 'browser', 'delegation']) {
    assert.ok(!toolsets.includes(risky), `Hermes não pode ter o toolset ${risky}`);
  }
});

test('o prompt vai como argumento único (sem shell) ou pela entrada padrão', () => {
  for (const id of ['copilot', 'agy', 'opencode', 'hermes']) {
    const command = headlessCommand(id, { prompt: PROMPT, dir: DIR });
    assert.equal(command.args.filter((arg) => arg === PROMPT).length, 1, id);
    assert.equal(command.stdin, null, id);
  }
  for (const id of ['claude', 'codex']) {
    const command = headlessCommand(id, { prompt: PROMPT, dir: DIR });
    assert.equal(command.stdin, PROMPT, id);
    assert.ok(!command.args.includes(PROMPT), id);
  }
  assert.ok(headlessCommand('codex', { prompt: 'x', dir: DIR }).args.includes(DIR));
  assert.ok(headlessCommand('opencode', { prompt: 'x', dir: DIR }).args.includes(DIR));
});

test('terminal e agentes desconhecidos não têm execução automática', () => {
  assert.equal(headlessCommand('shell', { prompt: 'x', dir: DIR }), null);
  assert.equal(headlessCommand('nada', { prompt: 'x', dir: DIR }), null);
  assert.equal(sessionArgv('nada'), null);
});

test('OpenCode: remove o raciocínio que antecede </think>', () => {
  const { clean } = headlessCommand('opencode', { prompt: 'x', dir: DIR });
  assert.equal(clean('pensando...</think>resposta final').trim(), 'resposta final');
  assert.equal(clean('sem marcador'), 'sem marcador');
});

test('sessões interativas usam o mesmo ambiente do launcher', () => {
  const claude = sessionArgv('claude');
  assert.deepEqual(claude.slice(0, 2), ['bash', '-lc']);
  assert.match(claude[2], /TERMUX_AI_GUEST=1/);
  assert.match(claude[2], /\.local\/bin/);
  assert.deepEqual(claude.slice(3), ['ia-sessao', 'claude']);
  assert.deepEqual(sessionArgv('codex').slice(-5), ['codex', '-s', 'workspace-write', '-a', 'on-request']);
  assert.deepEqual(sessionArgv('shell'), ['bash', '-l']);
});

test('describeAgents detecta o que está no PATH informado', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'hub-agents-'));
  try {
    for (const name of ['claude', 'hermes']) {
      const file = path.join(dir, name);
      await writeFile(file, '#!/bin/sh\nexit 0\n');
      await chmod(file, 0o755);
    }
    const byId = Object.fromEntries(describeAgents(dir).map((agent) => [agent.id, agent]));
    assert.equal(byId.claude.installed, true);
    assert.equal(byId.hermes.installed, true);
    assert.equal(byId.copilot.installed, false);
    assert.equal(byId.shell.installed, true);
    assert.equal(byId.hermes.reads, false);
    assert.ok(byId.codex.note.length > 0);
    assert.equal(JSON.stringify(byId).includes('function'), false);
    assert.ok(findExecutable('claude', dir));
    assert.equal(findExecutable('claude', ''), null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('o preâmbulo proíbe alterações', () => {
  assert.match(READONLY_PREAMBLE, /SOMENTE LEITURA/);
  assert.match(READONLY_PREAMBLE, /NÃO crie, edite, apague/);
});
