// Frente de decisao com TypeSafe Jev: cliente, politica e CLI contra um TypeSafe simulado local.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { describeAgents } from '../../scripts/hub/agents.mjs';
import { run } from '../../scripts/hub/cli.mjs';
import {
  buildRequest,
  decide,
  findSecrets,
  gateTask,
  listProjectFiles,
  loadJevConfig,
  saveJevConfig,
  saveJevKey,
} from '../../scripts/hub/jev.mjs';
import { Orchestrator } from '../../scripts/hub/orchestrator.mjs';

const KEY = 'ts_test_key_0123456789abcdef';
const fakeToken = () => `ghp_${'a'.repeat(36)}`;

function answers({ safety = 'safe', block = 0.02, confidence = 0.95, clear = 0.9, mode = 'compare', agent = 'claude' } = {}) {
  const others = { safe: 0, confirm: 0, block };
  others[safety] = Math.max(others[safety], confidence);
  return {
    model: 'jev-test',
    answers: {
      safety: { type: 'choice', choice: safety, confidence, probabilities: others },
      clear: { type: 'noul', noul: clear },
      mode: { type: 'choice', choice: mode, confidence: 0.8, probabilities: { direct: 0.1, compare: 0.8, pipeline: 0.05, maestro: 0.05 } },
      agent: { type: 'choice', choice: agent, confidence: 0.7, probabilities: { [agent]: 0.7 } },
    },
    usage: { input_tokens: 10, output_tokens: 2 },
  };
}

async function fakeTypeSafe(handler) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const entry = { method: req.method, url: req.url, headers: req.headers, body: raw ? JSON.parse(raw) : null, raw };
    requests.push(entry);
    const reply = await handler(entry);
    if (reply.delayMs) await new Promise((resolve) => setTimeout(resolve, reply.delayMs));
    res.writeHead(reply.status ?? 200, { 'Content-Type': 'application/json', ...(reply.headers ?? {}) });
    res.end(reply.text ?? JSON.stringify(reply.json ?? {}));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    requests,
    baseURL: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

async function workspace() {
  const base = await mkdtemp(path.join(os.tmpdir(), 'jev-'));
  const state = path.join(base, 'state');
  const project = path.join(base, 'projeto');
  await mkdir(path.join(project, 'src', 'deep', 'deeper', 'deepest'), { recursive: true });
  await mkdir(path.join(project, 'node_modules', 'pkg'), { recursive: true });
  await mkdir(path.join(project, '.git'), { recursive: true });
  await writeFile(path.join(project, 'src', 'app.js'), 'CONTEUDO_SECRETO_DO_ARQUIVO');
  await writeFile(path.join(project, 'src', 'deep', 'deeper', 'deepest', 'longe.js'), 'x');
  await writeFile(path.join(project, 'README.md'), 'readme');
  await writeFile(path.join(project, '.env'), 'X=1');
  await writeFile(path.join(project, 'id_rsa'), 'chave');
  await writeFile(path.join(project, 'node_modules', 'pkg', 'index.js'), 'x');
  return { base, state, project, cleanup: () => rm(base, { recursive: true, force: true }) };
}

async function enable(state, key = KEY) {
  await saveJevKey(state, key);
  await saveJevConfig(state, { enabled: true });
}

test('nomes de arquivos: sem pastas ocultas, node_modules, credenciais e com limite de profundidade', async () => {
  const ws = await workspace();
  try {
    const { names, truncated } = await listProjectFiles(ws.project);
    assert.deepEqual(names, ['README.md', 'src/app.js']);
    assert.equal(truncated, false);
    const limited = await listProjectFiles(ws.project, { limit: 1 });
    assert.equal(limited.names.length, 1);
    assert.equal(limited.truncated, true);
  } finally {
    await ws.cleanup();
  }
});

test('segredos conhecidos sao detectados sem repetir o valor', () => {
  assert.deepEqual(findSecrets(`use ${fakeToken()} no deploy`), ['token GitHub']);
  assert.deepEqual(findSecrets('explique o modulo de login'), []);
  assert.deepEqual(findSecrets('task-manager-description-longer-than-twenty'), []);
});

test('a requisicao leva tarefa, nomes de arquivos e perguntas tipadas, nunca o conteudo dos arquivos', () => {
  const body = buildRequest({ task: 'Revise o login', files: ['src/app.js'], truncated: false, agents: ['claude', 'hermes', 'shell'], model: 'jev-latest' });
  assert.equal(body.model, 'jev-latest');
  assert.deepEqual(body.state, { task: 'Revise o login', project_files: ['src/app.js'], project_files_truncated: false, available_agents: ['claude', 'hermes'] });
  assert.deepEqual(Object.keys(body.questions).sort(), ['agent', 'clear', 'mode', 'safety']);
  assert.equal(body.questions.safety.type, 'choice');
  assert.deepEqual(Object.keys(body.questions.safety.criteria), ['safe', 'confirm', 'block']);
  assert.equal(body.questions.clear.type, 'noul');
  assert.equal('criteria' in body.questions.clear, false, 'como o SDK oficial: noul sem criterios omite o campo');
  assert.deepEqual(Object.keys(body.questions.agent.criteria), ['claude', 'hermes']);
  const noAgents = buildRequest({ task: 't', files: [], truncated: false, agents: [], model: 'm' });
  assert.equal(noAgents.questions.agent, undefined);
});

test('politica de decisao: conservadora e com falha fechada para respostas estranhas', () => {
  const body = buildRequest({ task: 't', files: [], truncated: false, agents: ['claude'], model: 'm' });
  assert.equal(decide(answers(), body).verdict, 'allow');
  assert.equal(decide(answers({ safety: 'confirm', block: 0.05 }), body).verdict, 'confirm');
  assert.equal(decide(answers({ safety: 'safe', block: 0.2 }), body).verdict, 'confirm', 'probabilidade de bloqueio relevante');
  assert.equal(decide(answers({ confidence: 0.5 }), body).verdict, 'confirm', 'risco incerto');
  assert.equal(decide(answers({ safety: 'block' }), body).verdict, 'block');
  assert.equal(decide(answers({ safety: 'safe', block: 0.55, confidence: 0.4 }), body).verdict, 'block');
  assert.equal(decide(answers({ clear: 0.2 }), body).verdict, 'unclear');
  assert.equal(decide(answers({ safety: 'block', clear: 0.1 }), body).verdict, 'block', 'bloqueio vence a falta de clareza');
  const route = decide(answers({ mode: 'pipeline', agent: 'claude' }), body).route;
  assert.equal(route.mode, 'pipeline');
  assert.equal(route.agent, 'claude');
  for (const broken of [{}, { answers: {} }, answers({ agent: 'invasor' }), { answers: { ...answers().answers, clear: { type: 'noul', noul: 2 } } }]) {
    assert.throws(() => decide(broken, body), /formato inesperado/);
  }
});

test('gateTask: chamada real ao TypeSafe simulado, com Bearer e sem conteudo de arquivos', async () => {
  const ws = await workspace();
  const api = await fakeTypeSafe(() => ({ json: answers({ mode: 'maestro', agent: 'hermes' }) }));
  const env = { TYPESAFE_BASE_URL: api.baseURL };
  try {
    assert.deepEqual(await gateTask({ task: 'x', dir: ws.project, agents: ['claude'], state: ws.state, env }), { status: 'disabled' });
    assert.equal(api.requests.length, 0, 'desligado nao envia nada');

    await enable(ws.state);
    const result = await gateTask({ task: 'Mapear riscos do projeto', dir: ws.project, agents: ['claude', 'hermes'], state: ws.state, env });
    assert.equal(result.status, 'decided');
    assert.equal(result.decision.verdict, 'allow');
    assert.equal(result.decision.route.agent, 'hermes');
    const [sent] = api.requests;
    assert.equal(sent.method, 'POST');
    assert.equal(sent.url, '/v1/systemone');
    assert.equal(sent.headers.authorization, `Bearer ${KEY}`);
    assert.equal(sent.body.state.task, 'Mapear riscos do projeto');
    assert.deepEqual(sent.body.state.project_files, ['README.md', 'src/app.js']);
    assert.ok(!sent.raw.includes('CONTEUDO_SECRETO_DO_ARQUIVO'), 'o conteudo dos arquivos nao sai do aparelho');
    assert.ok(!sent.raw.includes('.env') && !sent.raw.includes('id_rsa'), 'nomes de credenciais nao saem');

    const log = await readFile(path.join(ws.state, 'typesafe', 'decisoes.jsonl'), 'utf8');
    assert.ok(!log.includes('Mapear riscos'), 'o registro local nao guarda o texto da tarefa');
    assert.match(log, /"verdict":"allow"/);
    assert.equal((await stat(path.join(ws.state, 'typesafe', 'decisoes.jsonl'))).mode & 0o777, 0o600);
  } finally {
    await api.close();
    await ws.cleanup();
  }
});

test('gateTask: segredo na tarefa ou em nome de arquivo nao gera requisicao', async () => {
  const ws = await workspace();
  const api = await fakeTypeSafe(() => ({ json: answers() }));
  const env = { TYPESAFE_BASE_URL: api.baseURL };
  try {
    await enable(ws.state);
    const inTask = await gateTask({ task: `publique com ${fakeToken()}`, dir: ws.project, agents: [], state: ws.state, env });
    assert.equal(inTask.status, 'secret');
    assert.deepEqual(inTask.secrets, ['token GitHub']);
    await writeFile(path.join(ws.project, `${fakeToken()}.txt`), 'x');
    assert.equal((await gateTask({ task: 'ok', dir: ws.project, agents: [], state: ws.state, env })).status, 'secret');
    assert.equal(api.requests.length, 0);
  } finally {
    await api.close();
    await ws.cleanup();
  }
});

test('gateTask: indisponivel em erro, chave recusada, tempo esgotado, redirecionamento e resposta invalida', async () => {
  const ws = await workspace();
  let reply = { status: 500 };
  // O destino do redirecionamento responde "pode seguir": se o cliente seguisse, a decisao mudaria.
  const api = await fakeTypeSafe((request) => (request.url === '/desvio/v1/systemone' ? { json: answers() } : reply));
  const env = { TYPESAFE_BASE_URL: api.baseURL, TYPESAFE_TIMEOUT_MS: '2000' };
  const gate = () => gateTask({ task: 'tarefa', dir: ws.project, agents: [], state: ws.state, env });
  try {
    await saveJevConfig(ws.state, { enabled: true });
    let result = await gate();
    assert.equal(result.status, 'unavailable', 'ativo sem chave: indisponivel');
    assert.match(result.reason, /ia typesafe configurar/);
    assert.equal(api.requests.length, 0);

    await saveJevKey(ws.state, KEY);
    for (const [answer, reason] of [
      [{ status: 500 }, /erro 500/],
      [{ status: 401 }, /recusada/],
      [{ status: 429 }, /Limite/],
      [{ status: 307, headers: { Location: `${api.baseURL}/desvio/v1/systemone` } }, /Sem conexao/],
      [{ text: 'nao e json' }, /ilegivel/],
      [{ json: { answers: {} } }, /formato inesperado/],
      [{ json: answers(), delayMs: 2600 }, /Sem resposta do Jev/],
    ]) {
      reply = answer;
      result = await gate();
      assert.equal(result.status, 'unavailable');
      assert.match(result.reason, reason);
    }
    const outside = await gateTask({ task: 'x', dir: ws.project, agents: [], state: ws.state, env: { TYPESAFE_BASE_URL: 'http://example.com' } });
    assert.equal(outside.status, 'unavailable');
    assert.match(outside.reason, /https/);
  } finally {
    await api.close();
    await ws.cleanup();
  }
});

test('chave: arquivo privado, formato validado e variavel de ambiente com prioridade', async () => {
  const ws = await workspace();
  try {
    await assert.rejects(saveJevKey(ws.state, 'curta'), /Chave invalida/);
    await assert.rejects(saveJevKey(ws.state, 'tem espaco no meio 123456'), /Chave invalida/);
    await saveJevKey(ws.state, KEY);
    assert.equal((await stat(path.join(ws.state, 'typesafe', 'key'))).mode & 0o777, 0o600);
    assert.equal((await stat(path.join(ws.state, 'typesafe'))).mode & 0o777, 0o700);
    assert.equal((await loadJevConfig({ state: ws.state, env: {} })).keySource, 'arquivo');
    const fromEnv = await loadJevConfig({ state: ws.state, env: { TYPESAFE_API_KEY: 'ts_env_key_0123456789' } });
    assert.equal(fromEnv.key, 'ts_env_key_0123456789');
    assert.equal(fromEnv.keySource, 'ambiente');
  } finally {
    await ws.cleanup();
  }
});

async function cli(ws, api, argv, extra = {}) {
  let out = '';
  let err = '';
  const calls = [];
  const asked = [];
  const orchestrator = new Orchestrator({
    dir: path.join(ws.base, 'runs'),
    runAgent: async (call) => {
      calls.push(call);
      return { ok: true, output: `resposta de ${call.agent}`, error: '', code: 0, timedOut: false, cancelled: false, durationMs: 5 };
    },
    installedAgents: () => ['claude', 'copilot'],
    persistDelayMs: 5,
  });
  const code = await run(argv, {
    out: { write: (text) => (out += text) },
    err: { write: (text) => (err += text) },
    readInput: async () => '',
    stdinIsTTY: false,
    env: { TERMUX_AI_HUB_STATE: ws.state, TYPESAFE_BASE_URL: api.baseURL },
    cwd: ws.project,
    orchestrator,
    describe: () => describeAgents('').map((agent) => ({ ...agent, installed: ['claude', 'copilot', 'shell'].includes(agent.id) })),
    signals: new EventEmitter(),
    ask: async (question) => {
      asked.push(question);
      return extra.answer ?? false;
    },
    ...extra,
  });
  return { code, out, err, calls, asked };
}

test('ia orquestrar: o Jev decide antes de qualquer agente rodar', async () => {
  const ws = await workspace();
  let reply = { json: answers() };
  const api = await fakeTypeSafe(() => reply);
  const task = ['comparar', '-a', 'claude,copilot', 'Explique o projeto'];
  try {
    await enable(ws.state);

    reply = { json: answers({ safety: 'block' }) };
    let res = await cli(ws, api, [...task, '--confirmar', '--sem-jev']);
    assert.equal(res.code, 3);
    assert.equal(res.calls.length, 0, 'bloqueio: nenhum agente roda, nem com --confirmar');
    assert.match(res.err, /bloqueada/);

    reply = { json: answers({ safety: 'confirm', block: 0.05 }) };
    res = await cli(ws, api, task);
    assert.equal(res.code, 3, 'sem terminal e sem --confirmar: para');
    assert.match(res.err, /--confirmar/);
    assert.equal(res.calls.length, 0);
    res = await cli(ws, api, [...task, '--confirmar']);
    assert.equal(res.code, 0);
    assert.ok(res.calls.length > 0);
    res = await cli(ws, api, task, { stdinIsTTY: true, answer: false });
    assert.equal(res.code, 3, 'no terminal a pessoa recusou');
    assert.deepEqual(res.asked, ['Seguir mesmo assim?']);
    res = await cli(ws, api, task, { stdinIsTTY: true, answer: true });
    assert.equal(res.code, 0, 'no terminal a pessoa confirmou');

    reply = { json: answers({ clear: 0.1 }) };
    res = await cli(ws, api, task);
    assert.equal(res.code, 3);
    assert.match(res.err, /mais detalhes/);

    reply = { status: 503 };
    res = await cli(ws, api, [...task, '--confirmar']);
    assert.equal(res.code, 3, '--confirmar nao substitui a decisao ausente');
    assert.match(res.err, /--sem-jev/);
    res = await cli(ws, api, [...task, '--sem-jev']);
    assert.equal(res.code, 0);
    assert.match(res.err, /Seguindo sem a decisão do Jev/);

    res = await cli(ws, api, ['comparar', '-a', 'claude,copilot', `envie ${fakeToken()}`, '--confirmar', '--sem-jev']);
    assert.equal(res.code, 3, 'segredo: nunca segue');
    assert.ok(!res.err.includes(fakeToken()), 'a mensagem nao repete o segredo');

    reply = { json: answers() };
    const before = api.requests.length;
    res = await cli(ws, api, task);
    assert.equal(res.code, 0);
    assert.equal(api.requests.length, before + 1);
  } finally {
    await api.close();
    await ws.cleanup();
  }
});

test('ia decidir e ia typesafe: sugestao, codigos de saida e chave que nunca aparece', async () => {
  const ws = await workspace();
  let reply = { json: answers({ mode: 'pipeline', agent: 'claude' }) };
  const api = await fakeTypeSafe((request) => (request.url === '/v1/models' ? { json: { models: [{ id: 'jev-test' }] } } : reply));
  try {
    let res = await cli(ws, api, ['decidir', 'Adicionar cache']);
    assert.equal(res.code, 4, 'sem chave: indisponivel');

    res = await cli(ws, api, ['typesafe', 'configurar'], { readSecret: async () => KEY });
    assert.equal(res.code, 0);
    assert.equal((await stat(path.join(ws.state, 'typesafe', 'key'))).mode & 0o777, 0o600);
    res = await cli(ws, api, ['typesafe', 'status']);
    assert.match(res.out, /ativo/);
    assert.ok(!res.out.includes(KEY) && !res.err.includes(KEY), 'status nunca mostra a chave');
    res = await cli(ws, api, ['typesafe', 'testar']);
    assert.equal(res.code, 0);
    assert.match(res.out, /jev-test/);
    assert.equal(api.requests.at(-1).headers.authorization, `Bearer ${KEY}`);

    res = await cli(ws, api, ['decidir', 'Adicionar cache ao cliente HTTP']);
    assert.equal(res.code, 0);
    assert.match(res.out, /ia orquestrar pipeline -a claude/);
    assert.equal(res.calls.length, 0, 'decidir nao executa agentes');
    reply = { json: answers({ safety: 'block' }) };
    assert.equal((await cli(ws, api, ['decidir', 'x'])).code, 3);

    res = await cli(ws, api, ['typesafe', 'desativar']);
    assert.equal(res.code, 0);
    const before = api.requests.length;
    res = await cli(ws, api, ['comparar', '-a', 'claude,copilot', 'Explique']);
    assert.equal(res.code, 0);
    assert.equal(api.requests.length, before, 'desativado: nada vai ao TypeSafe');
    res = await cli(ws, api, ['typesafe', 'esquecer']);
    assert.equal(res.code, 0);
    await assert.rejects(stat(path.join(ws.state, 'typesafe', 'key')));
    assert.equal((await cli(ws, api, ['typesafe', 'ativar'])).code, 2, 'ativar sem chave falha');
    assert.equal((await cli(ws, api, ['typesafe', 'xyz'])).code, 2);
  } finally {
    await api.close();
    await ws.cleanup();
  }
});
