// Modo auto: o Jev decide, o coordenador (Hermes, se instalado) escolhe agente e modelo por subtarefa.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { describeAgents, headlessCommand } from '../../scripts/hub/agents.mjs';
import { autoPlan, run } from '../../scripts/hub/cli.mjs';
import { saveJevConfig, saveJevKey } from '../../scripts/hub/jev.mjs';
import { sanitizePolicy } from '../../scripts/hub/models.mjs';
import { Orchestrator, parseMaestroPlan } from '../../scripts/hub/orchestrator.mjs';

test('cada agente recebe a flag de modelo conferida na sua CLI; nomes perigosos sao ignorados', () => {
  const claude = headlessCommand('claude', { prompt: 'p', dir: '/w', model: 'opus' });
  assert.deepEqual(claude.args.slice(-2), ['--model', 'opus']);
  assert.equal(claude.stdin, 'p');
  const codex = headlessCommand('codex', { prompt: 'p', dir: '/w', model: 'gpt-5.4' });
  assert.deepEqual(codex.args.slice(-3), ['-m', 'gpt-5.4', '-'], 'o "-" do prompt continua por ultimo');
  assert.deepEqual(headlessCommand('copilot', { prompt: 'p', dir: '/w', model: 'gpt-5.4' }).args.slice(-2), ['--model', 'gpt-5.4']);
  assert.deepEqual(headlessCommand('opencode', { prompt: 'p', dir: '/w', model: 'anthropic/claude-sonnet-4' }).args.slice(-2), [
    '-m',
    'anthropic/claude-sonnet-4',
  ]);
  for (const agent of ['agy', 'hermes']) {
    const plain = headlessCommand(agent, { prompt: 'p', dir: '/w' });
    assert.deepEqual(headlessCommand(agent, { prompt: 'p', dir: '/w', model: 'x' }).args, plain.args, `${agent} sem flag de modelo`);
  }
  const base = headlessCommand('claude', { prompt: 'p', dir: '/w' }).args;
  for (const bad of ['-rf', '--dangerously-skip-permissions', 'dois nomes', '', 'a'.repeat(81)]) {
    assert.deepEqual(headlessCommand('claude', { prompt: 'p', dir: '/w', model: bad }).args, base, `modelo recusado: ${bad}`);
  }
});

test('a lista de modelos so guarda agentes com flag de modelo e nomes seguros', () => {
  assert.deepEqual(sanitizePolicy({ agy: ['x'], hermes: ['y'], claude: ['opus', 'opus', '-x', 'dois nomes'], invasor: ['z'] }), { claude: ['opus'] });
  assert.deepEqual(sanitizePolicy(['claude']), {});
  assert.deepEqual(sanitizePolicy(null), {});
});

test('o plano do coordenador so leva modelos da lista permitida do agente escolhido', () => {
  const text = JSON.stringify({
    tarefas: [
      { agente: 'claude', modelo: 'opus', titulo: 'Arquitetura', prompt: 'a' },
      { agente: 'claude', modelo: 'gpt-5.4', titulo: 'Fora da lista', prompt: 'b' },
      { agente: 'copilot', modelo: 'qualquer', titulo: 'Sem lista', prompt: 'c' },
    ],
  });
  const tasks = parseMaestroPlan(text, ['claude', 'copilot'], 4, { claude: ['opus', 'sonnet'] });
  assert.equal(tasks[0].model, 'opus');
  assert.equal('model' in tasks[1], false);
  assert.equal('model' in tasks[2], false);
});

const ok = (output) => ({ ok: true, output, error: '', code: 0, timedOut: false, cancelled: false, durationMs: 5 });

function coordinatorHandler(plan) {
  return (call) => {
    if (call.prompt.includes('maestro de uma equipe')) return ok(JSON.stringify({ tarefas: plan }));
    if (call.prompt.includes('Integre os resultados')) return ok('resultado integrado');
    if (call.prompt.includes('juiz de uma comparação')) return ok('veredito do juiz');
    return ok(`resposta de ${call.agent}`);
  };
}

async function setup({ installed = ['claude', 'copilot', 'hermes'], answer, plan } = {}) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'auto-'));
  const state = path.join(base, 'state');
  const work = path.join(base, 'work');
  await mkdir(work, { recursive: true });
  let reply = { json: answer };
  const server = http.createServer(async (req, res) => {
    for await (const _chunk of req);
    res.writeHead(reply.status ?? 200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(reply.json ?? {}));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseURL = `http://127.0.0.1:${server.address().port}`;
  const call = async (argv, extra = {}) => {
    let out = '';
    let err = '';
    const calls = [];
    const asked = [];
    const coordinate = coordinatorHandler(plan ?? [{ agente: 'claude', modelo: 'opus', titulo: 'Parte 1', prompt: 'faca a parte 1' }]);
    const orchestrator = new Orchestrator({
      dir: path.join(base, 'runs'),
      runAgent: async (request) => {
        calls.push(request);
        return coordinate(request);
      },
      installedAgents: () => installed,
      persistDelayMs: 5,
    });
    const code = await run(argv, {
      out: { write: (text) => (out += text) },
      err: { write: (text) => (err += text) },
      readInput: async () => '',
      stdinIsTTY: false,
      env: { TERMUX_AI_HUB_STATE: state, TYPESAFE_BASE_URL: baseURL },
      cwd: work,
      orchestrator,
      describe: () => describeAgents('').map((agent) => ({ ...agent, installed: agent.id === 'shell' || installed.includes(agent.id) })),
      signals: new EventEmitter(),
      ask: async (question) => {
        asked.push(question);
        return extra.answer ?? false;
      },
      ...extra,
    });
    return { code, out, err, calls, asked };
  };
  return {
    state,
    call,
    reply: (value) => {
      reply = value;
    },
    enable: async () => {
      await saveJevKey(state, 'ts_test_key_0123456789abcdef');
      await saveJevConfig(state, { enabled: true });
    },
    cleanup: async () => {
      await new Promise((resolve) => server.close(resolve));
      await rm(base, { recursive: true, force: true });
    },
  };
}

function jev({ mode = 'maestro', agent = 'claude', safety = 'safe', clear = 0.9 } = {}) {
  return {
    model: 'jev-test',
    answers: {
      safety: { type: 'choice', choice: safety, confidence: 0.95, probabilities: { safe: safety === 'safe' ? 0.95 : 0.02, confirm: 0.03, block: safety === 'block' ? 0.95 : 0.02 } },
      clear: { type: 'noul', noul: clear },
      mode: { type: 'choice', choice: mode, confidence: 0.8, probabilities: {} },
      agent: { type: 'choice', choice: agent, confidence: 0.7, probabilities: {} },
    },
  };
}

test('autoPlan: o Jev escolhe o modo, o Hermes coordena e os leitores executam', () => {
  const installed = describeAgents('').map((agent) => ({ ...agent, installed: ['claude', 'copilot', 'hermes'].includes(agent.id) }));
  const readers = ['claude', 'copilot'];
  const maestro = autoPlan({ route: { mode: 'maestro', agent: 'copilot' }, installed, readers, policy: { claude: ['opus'], codex: ['x'] } });
  assert.deepEqual(maestro.spec, { mode: 'maestro', agents: ['copilot', 'claude'], coordinator: 'hermes', maxTasks: 4, models: { claude: ['opus'] } });
  assert.match(maestro.summary, /coordenador Hermes Agent/);
  assert.match(maestro.summary, /claude \(opus\)/);
  assert.equal(autoPlan({ route: { mode: 'direct', agent: 'claude' }, installed, readers, policy: {} }).spec.maxTasks, 1);
  const compare = autoPlan({ route: { mode: 'compare', agent: 'claude' }, installed, readers, policy: {} }).spec;
  assert.deepEqual(compare, { mode: 'compare', agents: ['claude', 'copilot'], judge: 'hermes' });
  const pipeline = autoPlan({ route: { mode: 'pipeline', agent: 'copilot' }, installed, readers, policy: {} }).spec;
  assert.deepEqual(pipeline.steps.map((step) => step.agent), ['copilot', 'claude', 'copilot']);
  const noHermes = installed.map((agent) => ({ ...agent, installed: agent.id !== 'hermes' && agent.installed }));
  assert.equal(autoPlan({ route: { mode: 'maestro', agent: 'copilot' }, installed: noHermes, readers, policy: {} }).spec.coordinator, 'copilot');
  assert.throws(() => autoPlan({ route: { mode: 'maestro' }, installed, readers: [], policy: {} }), /Nenhum agente que lê arquivos/);
});

test('ia orquestrar auto: precisa do Jev, mostra o plano e so executa com confirmacao', async () => {
  const env = await setup({ answer: jev({ mode: 'maestro', agent: 'claude' }) });
  try {
    let res = await env.call(['auto', 'Revisar o login']);
    assert.equal(res.code, 2, 'sem o Jev ativo nao ha decisor');
    assert.match(res.err, /precisa do Jev/);
    assert.equal(res.calls.length, 0);

    await env.enable();
    res = await env.call(['modelos', 'claude', 'opus,sonnet']);
    assert.equal(res.code, 0);
    assert.equal((await stat(path.join(env.state, 'modelos.json'))).mode & 0o777, 0o600);

    res = await env.call(['auto', 'Revisar o login']);
    assert.equal(res.code, 3, 'sem terminal e sem --sim: para no plano');
    assert.match(res.err, /Plano do Jev: maestro · coordenador Hermes Agent/);
    assert.match(res.err, /--sim/);
    assert.equal(res.calls.length, 0);

    res = await env.call(['auto', 'Revisar o login'], { stdinIsTTY: true, answer: false });
    assert.equal(res.code, 3);
    assert.deepEqual(res.asked, ['Executar este plano?']);
    assert.equal(res.calls.length, 0);

    res = await env.call(['auto', 'Revisar o login', '--sim']);
    assert.equal(res.code, 0, res.err);
    assert.equal(res.calls[0].agent, 'hermes', 'o Hermes planeja');
    assert.match(res.calls[0].prompt, /modelos permitidos: opus, sonnet/);
    const worker = res.calls.find((request) => request.prompt.includes('faca a parte 1'));
    assert.equal(worker.agent, 'claude');
    assert.equal(worker.model, 'opus', 'o modelo escolhido pelo coordenador chega a execucao');
    assert.equal(res.calls.at(-1).agent, 'hermes', 'o Hermes integra');
    assert.match(res.out, /resultado integrado/);

    env.reply({ json: jev({ safety: 'block' }) });
    res = await env.call(['auto', 'Revisar o login', '--sim', '--confirmar']);
    assert.equal(res.code, 3, 'bloqueio do Jev vence o --sim');
    assert.equal(res.calls.length, 0);

    env.reply({ json: jev({ mode: 'compare' }) });
    res = await env.call(['auto', 'Qual abordagem e melhor?', '--sim']);
    assert.equal(res.code, 0, res.err);
    assert.match(res.err, /Plano do Jev: comparar · Claude Code, GitHub Copilot · juiz Hermes Agent/);
  } finally {
    await env.cleanup();
  }
});

test('ia orquestrar modelos: lista, define, limpa e recusa entradas invalidas', async () => {
  const env = await setup();
  try {
    let res = await env.call(['modelos']);
    assert.equal(res.code, 0);
    assert.match(res.out, /claude\s+\(padrão da conta\)/);
    assert.equal((await env.call(['modelos', 'claude', 'opus, sonnet'])).code, 0);
    assert.deepEqual(JSON.parse(await readFile(path.join(env.state, 'modelos.json'), 'utf8')), { claude: ['opus', 'sonnet'] });
    res = await env.call(['modelos']);
    assert.match(res.out, /claude\s+opus, sonnet/);
    assert.equal((await env.call(['modelos', 'agy', 'x'])).code, 2, 'agente sem flag de modelo');
    assert.equal((await env.call(['modelos', 'claude', '--perigoso'])).code, 2);
    assert.equal((await env.call(['modelos', 'claude', '-x'])).code, 2);
    assert.equal((await env.call(['modelos', 'claude', 'opus,-x'])).code, 2, 'nome que viraria flag');
    assert.deepEqual(JSON.parse(await readFile(path.join(env.state, 'modelos.json'), 'utf8')), { claude: ['opus', 'sonnet'] }, 'lista anterior preservada');
    assert.equal((await env.call(['modelos', 'claude', 'limpar'])).code, 0);
    assert.deepEqual(JSON.parse(await readFile(path.join(env.state, 'modelos.json'), 'utf8')), {});
  } finally {
    await env.cleanup();
  }
});
