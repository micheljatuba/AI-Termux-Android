import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { READONLY_PREAMBLE } from '../../scripts/hub/agents.mjs';
import {
  Orchestrator,
  describeFailure,
  normalizeSpec,
  parseMaestroPlan,
  runHeadless,
} from '../../scripts/hub/orchestrator.mjs';
import { HubError } from '../../scripts/hub/util.mjs';

const ALL = ['copilot', 'claude', 'codex', 'agy', 'opencode', 'hermes'];
const POSIX = process.platform !== 'win32';

const ok = (output, extra = {}) => ({ ok: true, output, error: '', code: 0, timedOut: false, cancelled: false, durationMs: 5, ...extra });
const bad = (error, extra = {}) => ({ ok: false, output: '', error, code: 1, timedOut: false, cancelled: false, durationMs: 5, ...extra });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const removeTree = (dir) => rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });

async function setup(handlers = {}, options = {}) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'hub-orch-'));
  const work = path.join(base, 'work');
  await mkdir(work);
  const calls = [];
  const runAgent = async (call) => {
    calls.push(call);
    const handler = handlers[call.agent];
    return handler ? handler(call, calls) : bad('sem handler');
  };
  const runsDir = path.join(base, 'runs');
  const orchestrator = new Orchestrator({ dir: runsDir, runAgent, installedAgents: () => ALL, persistDelayMs: 5, ...options });
  await orchestrator.init();
  return {
    base,
    work,
    calls,
    runsDir,
    orchestrator,
    cleanup: async () => {
      await orchestrator.shutdown();
      await removeTree(base);
    },
  };
}

async function deadPid() {
  const child = spawn(process.execPath, ['-e', '']);
  await new Promise((resolve) => child.on('close', resolve));
  return child.pid;
}

test('comparar: agentes respondem e o juiz recebe todas as respostas', async () => {
  const env = await setup({
    claude: () => ok('RESPOSTA-CLAUDE'),
    copilot: () => ok('RESPOSTA-COPILOT'),
    codex: ({ prompt }) => ok(`VEREDITO ${prompt.includes('RESPOSTA-CLAUDE') && prompt.includes('RESPOSTA-COPILOT')}`),
  });
  try {
    const events = [];
    env.orchestrator.on('update', (run) => events.push(run.rev));
    env.orchestrator.on('finish', (run) => events.push(`fim:${run.status}`));
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'Qual a capital?', dir: env.work, agents: ['claude', 'copilot'], judge: 'codex' });
    await env.orchestrator.wait(run.id);

    assert.equal(run.status, 'done');
    assert.deepEqual(run.steps.map((step) => [step.kind, step.agent, step.status]), [
      ['agent', 'claude', 'done'],
      ['agent', 'copilot', 'done'],
      ['judge', 'codex', 'done'],
    ]);
    assert.equal(run.result, 'VEREDITO true');
    for (const call of env.calls) {
      assert.ok(call.prompt.startsWith(READONLY_PREAMBLE), 'todo prompt começa com o aviso de somente leitura');
      assert.equal(call.dir, env.work);
      assert.equal(call.timeoutMs, 600000);
    }
    assert.ok(env.calls.find((call) => call.agent === 'claude').prompt.includes('Qual a capital?'));
    assert.equal(events.at(-1), 'fim:done');
    assert.ok(run.rev >= 6);

    const saved = JSON.parse(await readFile(path.join(env.runsDir, run.id, 'run.json'), 'utf8'));
    assert.equal(saved.status, 'done');
    assert.equal(saved.result, 'VEREDITO true');
    if (POSIX) assert.equal((await stat(path.join(env.runsDir, run.id, 'run.json'))).mode & 0o777, 0o600);
    assert.equal(env.orchestrator.list()[0].id, run.id);
    assert.deepEqual(env.orchestrator.list()[0].agents, ['claude', 'copilot', 'codex']);
  } finally {
    await env.cleanup();
  }
});

test('comparar: se só um agente responde, o juiz é ignorado', async () => {
  const env = await setup({ claude: () => ok('SO-EU'), copilot: () => bad('Saiu com código 1: ERROR boom'), codex: () => ok('NAO-DEVE-RODAR') });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'], judge: 'codex' });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.deepEqual(run.steps.map((step) => step.status), ['done', 'error', 'skipped']);
    assert.equal(run.result, 'SO-EU');
    assert.ok(!env.calls.some((call) => call.agent === 'codex'));
  } finally {
    await env.cleanup();
  }
});

test('comparar: sem respostas é erro e sem juiz não há resultado único', async () => {
  const env = await setup({ claude: () => bad('falhou'), copilot: () => bad('falhou também'), codex: () => ok('A'), agy: () => ok('B') });
  try {
    const failed = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'], judge: 'codex' });
    await env.orchestrator.wait(failed.id);
    assert.equal(failed.status, 'error');
    assert.equal(failed.error, 'Nenhum agente respondeu');
    assert.equal(failed.steps.at(-1).status, 'skipped');

    const plain = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['codex', 'agy'] });
    await env.orchestrator.wait(plain.id);
    assert.equal(plain.status, 'done');
    assert.equal(plain.result, '');
    assert.deepEqual(plain.steps.map((step) => step.output), ['A', 'B']);
  } finally {
    await env.cleanup();
  }
});

test('comparar: se o juiz falha, a execução é erro mas as respostas ficam salvas', async () => {
  const env = await setup({ claude: () => ok('A'), copilot: () => ok('B'), codex: () => bad('cota esgotada') });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'], judge: 'codex' });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'error');
    assert.match(run.error, /O juiz falhou: cota esgotada/);
    assert.equal(run.steps[0].output, 'A');
  } finally {
    await env.cleanup();
  }
});

test('pipeline: cada etapa recebe a saída da anterior', async () => {
  const env = await setup({
    claude: () => ok('PLANO-DO-CLAUDE'),
    copilot: ({ prompt }) => ok(`CODIGO[${prompt.includes('PLANO-DO-CLAUDE')}]`),
    agy: ({ prompt }) => ok(`REVISAO[${prompt.includes('CODIGO[true]')}]`),
  });
  try {
    const run = env.orchestrator.start({
      mode: 'pipeline',
      prompt: 'Criar cache',
      dir: env.work,
      steps: [
        { agent: 'claude', role: 'plan' },
        { agent: 'copilot', role: 'implement' },
        { agent: 'agy', role: 'review' },
      ],
    });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.equal(run.result, 'REVISAO[true]');
    assert.deepEqual(run.steps.map((step) => step.title), [
      '1. Planejar · Claude Code',
      '2. Propor implementação · GitHub Copilot',
      '3. Revisar · Antigravity',
    ]);
    assert.ok(env.calls[0].prompt.includes('Criar cache'));
    assert.ok(!env.calls[0].prompt.includes('Resultado da etapa anterior'));
  } finally {
    await env.cleanup();
  }
});

test('pipeline: uma etapa que falha interrompe as seguintes', async () => {
  const env = await setup({ claude: () => ok('PLANO'), copilot: () => bad('Tempo esgotado (60 s)'), agy: () => ok('nunca') });
  try {
    const run = env.orchestrator.start({
      mode: 'pipeline',
      prompt: 'x',
      dir: env.work,
      steps: [
        { agent: 'claude', role: 'plan' },
        { agent: 'copilot', role: 'implement' },
        { agent: 'agy', role: 'review' },
      ],
    });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'error');
    assert.match(run.error, /Etapa "2\. Propor implementação · GitHub Copilot" falhou: Tempo esgotado/);
    assert.deepEqual(run.steps.map((step) => step.status), ['done', 'error', 'skipped']);
    assert.equal(run.result, '');
    assert.ok(!env.calls.some((call) => call.agent === 'agy'));
  } finally {
    await env.cleanup();
  }
});

test('pipeline: etapa personalizada aceita {{tarefa}}, {{anterior}} e {{passo1}}', async () => {
  const env = await setup({ claude: () => ok('PLANO'), copilot: () => ok('FEITO') });
  try {
    const run = env.orchestrator.start({
      mode: 'pipeline',
      prompt: 'Criar cache',
      dir: env.work,
      steps: [
        { agent: 'claude', role: 'plan' },
        { agent: 'copilot', role: 'custom', prompt: 'Resuma {{passo1}} para {{tarefa}} (anterior: {{anterior}})' },
      ],
    });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.ok(env.calls[1].prompt.includes('Resuma PLANO para Criar cache (anterior: PLANO)'));
  } finally {
    await env.cleanup();
  }
});

const PLAN = '```json\n{"tarefas":[{"agente":"claude","titulo":"Mapear","prompt":"Liste os arquivos"},{"agente":"copilot","titulo":"Riscos","prompt":"Liste os riscos"}]}\n```';

test('etapa personalizada: "$&", "$\'" e marcadores dentro dos textos não são reinterpretados', async () => {
  const output = "SAIDA $& e $' e $` e $1 e {{tarefa}} e $$";
  const task = "Tarefa com $& e $' e $` e $$ e {{anterior}}";
  const env = await setup({ claude: () => ok(output), copilot: () => ok('FEITO') });
  try {
    const run = env.orchestrator.start({
      mode: 'pipeline',
      prompt: task,
      dir: env.work,
      steps: [
        { agent: 'claude', role: 'plan' },
        { agent: 'copilot', role: 'custom', prompt: 'T=<{{tarefa}}> A=<{{anterior}}> P=<{{passo1}}>' },
      ],
    });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.ok(env.calls[1].prompt.includes(`T=<${task}> A=<${output}> P=<${output}>`), env.calls[1].prompt);
  } finally {
    await env.cleanup();
  }
});

test('maestro: o coordenador divide, os agentes executam e ele integra', async () => {
  const env = await setup({
    claude: ({ prompt }) => {
      if (prompt.includes('maestro de uma equipe')) return ok(PLAN);
      if (prompt.includes('Liste os arquivos')) return ok('ARQUIVOS');
      return ok(`INTEGRADO[${prompt.includes('ARQUIVOS') && prompt.includes('RISCOS')}]`);
    },
    copilot: () => ok('RISCOS'),
  });
  try {
    const run = env.orchestrator.start({ mode: 'maestro', prompt: 'Analise o projeto', dir: env.work, agents: ['claude', 'copilot'], coordinator: 'claude' });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.deepEqual(run.steps.map((step) => step.kind), ['coordinator', 'worker', 'worker', 'integrate']);
    assert.deepEqual(run.steps.map((step) => step.id), ['s1', 's2', 's3', 's4']);
    assert.deepEqual(run.steps.slice(1, 3).map((step) => step.subtask), ['Mapear', 'Riscos']);
    assert.equal(run.result, 'INTEGRADO[true]');
    assert.ok(env.calls.every((call) => call.prompt.startsWith(READONLY_PREAMBLE)));
  } finally {
    await env.cleanup();
  }
});

test('maestro: plano inválido é pedido de novo uma vez e depois vira erro', async () => {
  const env = await setup({ claude: () => ok('não sei dividir isso') });
  try {
    const run = env.orchestrator.start({ mode: 'maestro', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'error');
    assert.equal(run.error, 'O coordenador não devolveu um plano válido');
    assert.equal(env.calls.length, 2);
    assert.equal(run.steps.at(-1).status, 'skipped');
  } finally {
    await env.cleanup();
  }
});

test('maestro: subtarefas que falham não impedem a integração', async () => {
  const env = await setup({
    claude: ({ prompt }) => (prompt.includes('maestro de uma equipe') ? ok(PLAN) : ok(prompt.includes('falhou') ? 'INTEGRADO-COM-FALHA' : 'ARQUIVOS')),
    copilot: () => bad('sem cota'),
  });
  try {
    const run = env.orchestrator.start({ mode: 'maestro', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.equal(run.result, 'INTEGRADO-COM-FALHA');
    assert.equal(run.steps.find((step) => step.agent === 'copilot').status, 'error');
  } finally {
    await env.cleanup();
  }
});

// Um unico argumento de linha de comando no Linux nao passa de 128 KB: o prompt do juiz/maestro tem de caber com folga.
const ARGUMENT_BUDGET = 96 * 1024;

test('o prompt do juiz cabe no limite de um argumento mesmo com 6 respostas enormes', async () => {
  const big = 'r'.repeat(300 * 1024);
  const answer = ({ prompt }) => ok(prompt.includes('Você é o juiz') ? 'VEREDITO' : big);
  const env = await setup(Object.fromEntries(ALL.map((agent) => [agent, answer])));
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 't'.repeat(30 * 1024), dir: env.work, agents: ALL, judge: 'claude' });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done', run.error);
    const judge = env.calls.find((call) => call.prompt.includes('Você é o juiz'));
    const size = Buffer.byteLength(judge.prompt);
    assert.ok(size <= ARGUMENT_BUDGET, `o prompt do juiz tem ${size} bytes`);
    assert.equal(judge.prompt.match(/### Resposta \d/g).length, 6, 'todas as respostas entram, cada uma resumida');
    assert.match(judge.prompt, /\[\.\.\. truncado \.\.\.\]/);
  } finally {
    await env.cleanup();
  }
});

test('o prompt da integração do maestro também cabe no limite de um argumento', async () => {
  const big = 'r'.repeat(300 * 1024);
  const plan = JSON.stringify({ tarefas: ALL.map((agent, index) => ({ agente: agent, titulo: `Parte${index + 1}`, prompt: `Faça a parte ${index + 1}` })) });
  const answer = ({ prompt }) => {
    if (prompt.includes('maestro de uma equipe')) return ok(plan);
    if (prompt.includes('Você é o maestro. Integre')) return ok('INTEGRADO');
    return ok(big);
  };
  const env = await setup(Object.fromEntries(ALL.map((agent) => [agent, answer])));
  try {
    const run = env.orchestrator.start({ mode: 'maestro', prompt: 't'.repeat(30 * 1024), dir: env.work, agents: ALL, coordinator: 'claude', maxTasks: 6 });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done', run.error);
    assert.equal(run.result, 'INTEGRADO');
    const integration = env.calls.find((call) => call.prompt.includes('Você é o maestro. Integre'));
    const size = Buffer.byteLength(integration.prompt);
    assert.ok(size <= ARGUMENT_BUDGET, `o prompt da integração tem ${size} bytes`);
    assert.equal(integration.prompt.match(/### Parte\d/g).length, 6);
  } finally {
    await env.cleanup();
  }
});

test('parseMaestroPlan valida agentes, limites e formatos', () => {
  const allowed = ['claude', 'copilot'];
  assert.deepEqual(parseMaestroPlan(PLAN, allowed, 4), [
    { agent: 'claude', title: 'Mapear', prompt: 'Liste os arquivos' },
    { agent: 'copilot', title: 'Riscos', prompt: 'Liste os riscos' },
  ]);
  const english = parseMaestroPlan('Aqui: {"tasks":[{"agent":"opencode","title":"T","prompt":"P"},{"agent":"claude","prompt":"Q"}]} fim', allowed, 4);
  assert.deepEqual(english.map((task) => task.agent), ['claude', 'claude']);
  assert.equal(english[1].title, 'Subtarefa 2');
  assert.equal(parseMaestroPlan(PLAN, allowed, 1).length, 1);
  assert.equal(parseMaestroPlan('{"tarefas":[{"agente":"claude","prompt":"  "}]}', allowed, 4), null);
  assert.equal(parseMaestroPlan('{"tarefas":[]}', allowed, 4), null);
  assert.equal(parseMaestroPlan('nada de json', allowed, 4), null);
  assert.equal(parseMaestroPlan('{"tarefas": "x"}', allowed, 4), null);
});

test('cancelar interrompe os agentes e marca tudo como cancelado', async () => {
  const waiting = ({ signal }) =>
    new Promise((resolve) => {
      signal.addEventListener('abort', () => resolve(bad('Cancelado', { cancelled: true })), { once: true });
    });
  const env = await setup({ claude: waiting, copilot: waiting, codex: () => ok('nunca') });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'], judge: 'codex' });
    await sleep(30);
    assert.equal(run.status, 'running');
    env.orchestrator.cancel(run.id);
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'cancelled');
    assert.equal(run.error, 'Execução cancelada');
    assert.deepEqual(run.steps.map((step) => step.status), ['cancelled', 'cancelled', 'cancelled']);
    assert.throws(() => env.orchestrator.cancel(run.id), (error) => error instanceof HubError && error.status === 409);
  } finally {
    await env.cleanup();
  }
});

test('cancelar enquanto espera na fila não depende de uma vaga livre', { timeout: 10000 }, async () => {
  const env = await setup({ claude: () => ok('nunca'), copilot: () => ok('nunca') }, { maxParallel: 1 });
  try {
    await env.orchestrator.semaphore.acquire();
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await sleep(30);
    assert.deepEqual(run.steps.map((step) => step.status), ['queued', 'queued']);
    env.orchestrator.cancel(run.id);
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'cancelled');
    assert.deepEqual(run.steps.map((step) => step.status), ['cancelled', 'cancelled']);
    assert.equal(env.calls.length, 0, 'nenhum agente chegou a rodar');
    assert.equal(env.orchestrator.semaphore.active, 1, 'a vaga de quem a segurava continua dele');
    assert.equal(env.orchestrator.semaphore.waiters.length, 0, 'ninguém sobra na fila');
    env.orchestrator.semaphore.release();
    assert.equal(env.orchestrator.semaphore.active, 0);
  } finally {
    await env.cleanup();
  }
});

test('o limite global de execuções simultâneas é respeitado', async () => {
  let running = 0;
  let peak = 0;
  const slow = async () => {
    running += 1;
    peak = Math.max(peak, running);
    await sleep(25);
    running -= 1;
    return ok('ok');
  };
  const env = await setup({ claude: slow, copilot: slow, codex: slow, agy: slow }, { maxParallel: 2 });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot', 'codex', 'agy'] });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.equal(peak, 2);
  } finally {
    await env.cleanup();
  }
});

test('uma exceção do executor vira erro da etapa, não derruba o painel', async () => {
  const env = await setup({
    claude: () => {
      throw new Error('quebrou');
    },
    copilot: () => ok('ok'),
  });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await env.orchestrator.wait(run.id);
    assert.equal(run.status, 'done');
    assert.equal(run.steps[0].status, 'error');
    assert.equal(run.steps[0].error, 'quebrou');
  } finally {
    await env.cleanup();
  }
});

test('histórico: remover, limites de ids e runs ativas protegidas', async () => {
  const hold = ({ signal }) => new Promise((resolve) => signal.addEventListener('abort', () => resolve(bad('Cancelado', { cancelled: true }))));
  const env = await setup({ claude: hold, copilot: () => ok('ok') });
  try {
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await assert.rejects(env.orchestrator.remove(run.id), (error) => error.status === 409);
    env.orchestrator.cancel(run.id);
    await env.orchestrator.wait(run.id);
    await env.orchestrator.remove(run.id);
    assert.equal(env.orchestrator.list().length, 0);
    assert.ok(!(await readdir(env.runsDir)).includes(run.id));
    await assert.rejects(env.orchestrator.get(run.id), (error) => error.status === 404);
    await assert.rejects(env.orchestrator.get('../../etc/passwd'), (error) => error.status === 404);
    await assert.rejects(env.orchestrator.remove('..'), (error) => error.status === 404);
  } finally {
    await env.cleanup();
  }
});

function savedRun(id, extra = {}) {
  return {
    id,
    rev: 3,
    pid: process.pid,
    mode: 'compare',
    prompt: `tarefa ${id}`,
    dir: '/',
    options: {},
    status: 'done',
    createdAt: Date.parse('2026-01-01T00:00:00Z'),
    finishedAt: Date.parse('2026-01-01T00:01:00Z'),
    steps: [],
    result: '',
    error: '',
    ...extra,
  };
}

async function writeRun(runsDir, run) {
  await mkdir(path.join(runsDir, run.id), { recursive: true });
  await writeFile(path.join(runsDir, run.id, 'run.json'), JSON.stringify(run));
}

test('init e refresh reconciliam execuções de outros processos', async () => {
  const env = await setup();
  const live = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)']);
  try {
    const step = { id: 's1', agent: 'claude', status: 'running' };
    await writeRun(env.runsDir, savedRun('20260101-000000-aaaaaa', { status: 'running', pid: await deadPid(), steps: [step] }));
    await writeRun(env.runsDir, savedRun('20260101-000001-bbbbbb', { status: 'running', pid: live.pid, steps: [step] }));
    await writeRun(env.runsDir, savedRun('20260101-000002-cccccc', { status: 'running', pid: process.pid, steps: [step] }));

    const second = new Orchestrator({ dir: env.runsDir, installedAgents: () => ALL });
    await second.init();
    const byId = Object.fromEntries(second.list().map((item) => [item.id, item.status]));
    assert.equal(byId['20260101-000000-aaaaaa'], 'error');
    assert.equal(byId['20260101-000001-bbbbbb'], 'running', 'processo vivo de outra instância continua rodando');
    assert.equal(byId['20260101-000002-cccccc'], 'error', 'run do próprio pid que não está ativa é resto de execução antiga');
    const interrupted = await second.get('20260101-000000-aaaaaa');
    assert.match(interrupted.error, /Interrompido/);
    assert.equal(interrupted.steps[0].status, 'cancelled');

    await writeRun(env.runsDir, savedRun('20260101-000003-dddddd'));
    await second.refresh();
    assert.ok(second.list().some((item) => item.id === '20260101-000003-dddddd'));

    live.kill();
    await new Promise((resolve) => live.on('close', resolve));
    await second.refresh();
    assert.equal(second.list().find((item) => item.id === '20260101-000001-bbbbbb').status, 'error');

    await rm(path.join(env.runsDir, '20260101-000003-dddddd'), { recursive: true, force: true });
    await second.refresh();
    assert.ok(!second.list().some((item) => item.id === '20260101-000003-dddddd'));
  } finally {
    live.kill();
    await env.cleanup();
  }
});

test('init mantém só as 50 execuções mais recentes e ignora lixo', async () => {
  const env = await setup();
  try {
    for (let n = 0; n < 55; n += 1) {
      await writeRun(env.runsDir, savedRun(`20260101-${String(n).padStart(6, '0')}-aaaaaa`));
    }
    await mkdir(path.join(env.runsDir, 'nao-e-run'));
    await writeFile(path.join(env.runsDir, '20260101-999999-bbbbbb'), 'arquivo solto');
    const second = new Orchestrator({ dir: env.runsDir, installedAgents: () => ALL });
    await second.init();
    const ids = second.list().map((item) => item.id);
    assert.equal(ids.length, 50);
    assert.equal(ids[0], '20260101-000054-aaaaaa');
    assert.ok(!ids.includes('20260101-000000-aaaaaa'));
    assert.ok(!(await readdir(env.runsDir)).includes('20260101-000004-aaaaaa'));
  } finally {
    await env.cleanup();
  }
});

test('cada execução concluída apaga as mais antigas além das 50 guardadas, menos as que ainda rodam', async () => {
  const env = await setup({ claude: () => ok('ok'), copilot: () => ok('ok') });
  try {
    for (let n = 0; n < 50; n += 1) {
      await writeRun(env.runsDir, savedRun(`20200101-${String(n).padStart(6, '0')}-aaaaaa`));
    }
    await writeRun(env.runsDir, savedRun('20190101-000000-cccccc', { status: 'running', pid: process.pid }));
    const run = env.orchestrator.start({ mode: 'compare', prompt: 'x', dir: env.work, agents: ['claude', 'copilot'] });
    await env.orchestrator.wait(run.id);
    const names = await readdir(env.runsDir);
    assert.ok(!names.includes('20200101-000000-aaaaaa'), 'a mais antiga concluída foi apagada');
    assert.ok(names.includes('20200101-000001-aaaaaa'));
    assert.ok(names.includes(run.id));
    assert.ok(names.includes('20190101-000000-cccccc'), 'uma execução ainda marcada como em andamento nunca é apagada');
    assert.equal(names.length, 51);
  } finally {
    await env.cleanup();
  }
});

test('normalizeSpec recusa pedidos inválidos com mensagens claras', () => {
  const installed = ['claude', 'copilot', 'codex'];
  const reject = (spec, pattern) =>
    assert.throws(() => normalizeSpec(spec, installed), (error) => error instanceof HubError && error.status === 400 && pattern.test(error.message), JSON.stringify(spec));

  reject(null, /Pedido inválido/);
  reject({ mode: 'x', prompt: 'a' }, /Modo inválido/);
  reject({ mode: 'compare', prompt: '   ' }, /Escreva a tarefa/);
  reject({ mode: 'compare', prompt: 'x'.repeat(33 * 1024), agents: ['claude', 'copilot'] }, /grande demais/);
  reject({ mode: 'compare', prompt: 'a', agents: ['claude'] }, /pelo menos 2/);
  reject({ mode: 'compare', prompt: 'a', agents: ['claude', 'agy'] }, /Antigravity não está instalado/);
  reject({ mode: 'compare', prompt: 'a', agents: ['claude', 'shell'] }, /desconhecido/);
  reject({ mode: 'compare', prompt: 'a', agents: ['claude', 'nada'] }, /desconhecido/);
  reject({ mode: 'compare', prompt: 'a', agents: ['claude', 'copilot'], judge: 'hermes' }, /Hermes Agent não está instalado/);
  reject({ mode: 'pipeline', prompt: 'a', steps: [{ agent: 'claude' }] }, /2 a 6 etapas/);
  reject({ mode: 'pipeline', prompt: 'a', steps: [{ agent: 'claude', role: 'custom' }, { agent: 'copilot' }] }, /instrução da etapa personalizada/);
  reject({ mode: 'maestro', prompt: 'a', agents: [] }, /pelo menos 1 agente/);
  reject({ mode: 'maestro', prompt: 'a', agents: ['claude'], coordinator: 'codex2' }, /Coordenador/);
});

test('normalizeSpec aplica padrões e limites', () => {
  const installed = ['claude', 'copilot', 'codex'];
  const compare = normalizeSpec({ mode: 'compare', prompt: ' oi ', agents: ['Claude', 'claude', 'copilot'], judge: 'codex', timeoutSec: 5 }, installed);
  assert.equal(compare.prompt, 'oi');
  assert.deepEqual(compare.options.agents, ['claude', 'copilot']);
  assert.equal(compare.options.judge, 'codex');
  assert.equal(compare.options.timeoutSec, 30);

  const pipeline = normalizeSpec({ mode: 'pipeline', prompt: 'x', steps: [{ agent: 'claude' }, { agent: 'copilot' }, { agent: 'codex' }, { agent: 'claude' }], timeoutSec: 99999 }, installed);
  assert.deepEqual(pipeline.options.steps.map((step) => step.role), ['plan', 'implement', 'review', 'review']);
  assert.equal(pipeline.options.timeoutSec, 1800);

  const maestro = normalizeSpec({ mode: 'maestro', prompt: 'x', agents: ['copilot', 'claude'], maxTasks: 50 }, installed);
  assert.equal(maestro.options.coordinator, 'copilot');
  assert.equal(maestro.options.maxTasks, 6);
});

test('start exige a pasta de trabalho já validada', async () => {
  const env = await setup({ claude: () => ok('a'), copilot: () => ok('b') });
  try {
    assert.throws(() => env.orchestrator.start({ mode: 'compare', prompt: 'x', agents: ['claude', 'copilot'] }), /Pasta de trabalho ausente/);
  } finally {
    await env.cleanup();
  }
});

test('describeFailure destaca a linha de erro mais útil', () => {
  assert.match(describeFailure('', 'aviso\nERROR: cota esgotada\nfim', 1), /Saiu com código 1: ERROR: cota esgotada/);
  assert.match(describeFailure('só stdout\nlinha 2', '', 2), /só stdout · linha 2/);
  assert.equal(describeFailure('', '', 3), 'Saiu com código 3 sem mensagem');
});

function fakeSpawn(script) {
  const spawned = [];
  const spawnFn = (command, args, options) => {
    const child = new EventEmitter();
    child.pid = 99999999;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.stdin = new PassThrough();
    child.signals = [];
    child.input = '';
    child.stdin.on('data', (chunk) => {
      child.input += chunk;
    });
    child.kill = (signal) => {
      child.signals.push(signal);
      setImmediate(() => child.emit('close', null, signal));
      return true;
    };
    child.command = command;
    child.args = args;
    child.options = options;
    spawned.push(child);
    setImmediate(() => script?.(child));
    return child;
  };
  return { spawnFn, spawned };
}

test('runHeadless: sucesso, ambiente sem cores e entrada por stdin', async () => {
  const fake = fakeSpawn((child) => {
    child.stdout.write('\u001b[32molá\u001b[0m mundo\n');
    child.emit('close', 0, null);
  });
  const outputs = [];
  const result = await runHeadless({ agent: 'claude', prompt: 'PERGUNTA', dir: '/tmp/x', timeoutMs: 5000, spawnFn: fake.spawnFn, onOutput: (text) => outputs.push(text) });
  assert.equal(result.ok, true);
  assert.equal(result.output, 'olá mundo');
  const child = fake.spawned[0];
  assert.equal(child.command, 'claude');
  assert.equal(child.input, 'PERGUNTA');
  assert.equal(child.options.detached, true);
  assert.equal(child.options.cwd, '/tmp/x');
  assert.equal(child.options.env.NO_COLOR, '1');
  assert.ok(outputs.length >= 1);
});

test('runHeadless: falhas explicam o motivo', async () => {
  const failed = fakeSpawn((child) => {
    child.stderr.write('ERROR: You\'ve hit your usage limit\n');
    child.emit('close', 1, null);
  });
  const result = await runHeadless({ agent: 'codex', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: failed.spawnFn });
  assert.equal(result.ok, false);
  assert.match(result.error, /código 1: ERROR: You've hit your usage limit/);

  const killed = fakeSpawn((child) => child.emit('close', null, 'SIGKILL'));
  assert.match((await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: killed.spawnFn })).error, /sinal SIGKILL/);

  const empty = fakeSpawn((child) => child.emit('close', 0, null));
  assert.match((await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: empty.spawnFn })).error, /sem resposta/);

  const missing = fakeSpawn((child) => child.emit('error', Object.assign(new Error('spawn hermes ENOENT'), { code: 'ENOENT' })));
  assert.match((await runHeadless({ agent: 'hermes', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: missing.spawnFn })).error, /hermes não encontrado no PATH/);

  const throwing = (() => {
    throw new Error('EACCES');
  });
  assert.match((await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: throwing })).error, /Não foi possível iniciar agy: EACCES/);

  const unsupported = await runHeadless({ agent: 'shell', prompt: 'x', dir: '/tmp', timeoutMs: 5000 });
  assert.match(unsupported.error, /não suporta execução automática/);
});

test('runHeadless: tempo esgotado e cancelamento encerram o processo', async () => {
  const slow = fakeSpawn();
  const timedOut = await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 30, spawnFn: slow.spawnFn });
  assert.equal(timedOut.ok, false);
  assert.equal(timedOut.timedOut, true);
  assert.match(timedOut.error, /Tempo esgotado/);
  assert.ok(slow.spawned[0].signals.includes('SIGTERM'));

  const controller = new AbortController();
  const waiting = fakeSpawn();
  const pending = runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 60000, signal: controller.signal, spawnFn: waiting.spawnFn });
  await sleep(20);
  controller.abort();
  const cancelled = await pending;
  assert.equal(cancelled.cancelled, true);
  assert.equal(cancelled.error, 'Cancelado');

  const early = new AbortController();
  early.abort();
  const instant = await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 60000, signal: early.signal, spawnFn: fakeSpawn().spawnFn });
  assert.equal(instant.cancelled, true);
});

test('runHeadless: OpenCode sem raciocínio e saídas enormes truncadas', async () => {
  const think = fakeSpawn((child) => {
    child.stdout.write('raciocinando...</think>resposta limpa\n');
    child.emit('close', 0, null);
  });
  assert.equal((await runHeadless({ agent: 'opencode', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: think.spawnFn })).output, 'resposta limpa');

  const huge = fakeSpawn((child) => {
    child.stdout.write('a'.repeat(300 * 1024));
    child.emit('close', 0, null);
  });
  const result = await runHeadless({ agent: 'agy', prompt: 'x', dir: '/tmp', timeoutMs: 5000, spawnFn: huge.spawnFn });
  assert.equal(result.ok, true);
  assert.ok(Buffer.byteLength(result.output) <= 256 * 1024);
  assert.match(result.output, /\[\.\.\. truncado \.\.\.\]$/);
});

async function stubEnvironment(scripts) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'hub-stub-'));
  const bin = path.join(base, 'bin');
  await mkdir(bin);
  for (const [name, body] of Object.entries(scripts)) {
    await writeFile(path.join(bin, name), `#!/bin/sh\n${body}\n`);
    await chmod(path.join(bin, name), 0o755);
  }
  const env = { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, STUB_DIR: base };
  return { base, env, cleanup: () => removeTree(base) };
}

test('runHeadless com processo real: lê o prompt da entrada padrão e devolve a resposta', { skip: !POSIX }, async () => {
  const stub = await stubEnvironment({ claude: 'cat > "$STUB_DIR/prompt.txt"\necho "ARGS:$*"\necho resposta-final' });
  try {
    const result = await runHeadless({ agent: 'claude', prompt: 'olá agente', dir: stub.base, timeoutMs: 10000, env: stub.env });
    assert.equal(result.ok, true, result.error);
    assert.match(result.output, /resposta-final/);
    assert.match(result.output, /--permission-mode dontAsk/);
    assert.equal(await readFile(path.join(stub.base, 'prompt.txt'), 'utf8'), 'olá agente');
  } finally {
    await stub.cleanup();
  }
});

test('runHeadless com processo real: cancelar encerra também os processos filhos', { skip: !POSIX }, async () => {
  const stub = await stubEnvironment({ agy: 'sleep 60 &\necho $! > "$STUB_DIR/filho.pid"\nwait' });
  try {
    const controller = new AbortController();
    const pending = runHeadless({ agent: 'agy', prompt: 'x', dir: stub.base, timeoutMs: 60000, signal: controller.signal, env: stub.env });
    let childPid = 0;
    for (let attempt = 0; attempt < 100 && !childPid; attempt += 1) {
      await sleep(30);
      childPid = Number.parseInt(await readFile(path.join(stub.base, 'filho.pid'), 'utf8').catch(() => ''), 10) || 0;
    }
    assert.ok(childPid > 0, 'o filho deveria ter iniciado');
    controller.abort();
    const result = await pending;
    assert.equal(result.cancelled, true);
    let alive = true;
    for (let attempt = 0; attempt < 50 && alive; attempt += 1) {
      try {
        process.kill(childPid, 0);
        await sleep(40);
      } catch {
        alive = false;
      }
    }
    assert.equal(alive, false, 'o processo filho não pode sobreviver ao cancelamento');
  } finally {
    await stub.cleanup();
  }
});

// Um zumbi (ja morto, ainda nao recolhido pelo pai) conta como encerrado.
async function isRunning(pid) {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  const stat = await readFile(`/proc/${pid}/stat`, 'utf8').catch(() => '');
  return !/^\d+ \(.*\) Z /.test(stat);
}

test('runHeadless com processo real: se o processo principal sair, os agentes não ficam soltos', { skip: !POSIX, timeout: 30000 }, async () => {
  const stub = await stubEnvironment({ agy: 'sleep 60 &\necho $! > "$STUB_DIR/filho.pid"\nwait' });
  let parent;
  let childPid = 0;
  try {
    const orchestratorUrl = new URL('../../scripts/hub/orchestrator.mjs', import.meta.url).href;
    // saida abrupta (erro nao tratado, process.exit) com um agente ainda rodando
    const driver = `
      import { existsSync } from 'node:fs';
      import { runHeadless } from ${JSON.stringify(orchestratorUrl)};
      runHeadless({ agent: 'agy', prompt: 'x', dir: process.env.STUB_DIR, timeoutMs: 60000, env: process.env });
      const timer = setInterval(() => {
        if (!existsSync(process.env.STUB_DIR + '/filho.pid')) return;
        clearInterval(timer);
        setTimeout(() => process.exit(0), 150);
      }, 30);
    `;
    parent = spawn(process.execPath, ['--input-type=module', '-e', driver], { env: stub.env, stdio: 'ignore' });
    await new Promise((resolve, reject) => {
      parent.on('error', reject);
      parent.on('close', resolve);
    });
    childPid = Number.parseInt(await readFile(path.join(stub.base, 'filho.pid'), 'utf8'), 10) || 0;
    assert.ok(childPid > 0, 'o filho deveria ter iniciado');
    for (let attempt = 0; attempt < 60 && (await isRunning(childPid)); attempt += 1) await sleep(50);
    assert.equal(await isRunning(childPid), false, 'o agente não pode sobreviver à saída do processo principal');
  } finally {
    parent?.kill('SIGKILL');
    if (childPid > 0) {
      try {
        process.kill(childPid, 'SIGKILL');
      } catch {
        // ja terminou, como esperado
      }
    }
    await stub.cleanup();
  }
});
