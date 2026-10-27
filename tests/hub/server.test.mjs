import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { Orchestrator } from '../../scripts/hub/orchestrator.mjs';
import { createHub } from '../../scripts/hub/server.mjs';
import { KEYS } from '../../scripts/hub/sessions.mjs';
import { HubError } from '../../scripts/hub/util.mjs';
import { connectWs, request, startFakeTtyd, waitUntil } from './helpers.mjs';

const TOKEN = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const HTML = '<!doctype html><html><body><script nonce="__NONCE__">1</script><style nonce="__NONCE__"></style>__NONCE__</body></html>';
const NOW = 1000;

function fakeSessions() {
  const store = new Map();
  const calls = [];
  const need = (name) => {
    const found = store.get(name);
    if (!found) throw new HubError(404, 'Sessão não encontrada');
    return found;
  };
  return {
    tmux: '/usr/bin/tmux',
    searchPath: '',
    maxSessions: 3,
    minFreeMb: 512,
    calls,
    store,
    async list() {
      return [...store.values()];
    },
    async create({ agent, dir }) {
      if (agent === 'cheio') throw new HubError(409, 'Limite de 3 sessões simultâneas; encerre alguma antes');
      const number = store.size + 1;
      const session = { name: `ia-${agent}-${number}`, agent, dir, dead: false, exitStatus: null, activity: NOW - 1, created: NOW - 50 };
      store.set(session.name, session);
      calls.push(['create', agent, dir]);
      return session;
    },
    async kill(name) {
      need(name);
      store.delete(name);
      calls.push(['kill', name]);
    },
    async restart(name) {
      need(name);
      calls.push(['restart', name]);
    },
    async send(name, text, options) {
      need(name);
      if (name.endsWith('-9')) throw new HubError(500, 'tmux falhou');
      calls.push(['send', name, text, options]);
    },
    async key(name, key) {
      need(name);
      if (!Object.hasOwn(KEYS, key)) throw new HubError(400, `Tecla não permitida: ${key}`);
      calls.push(['key', name, key]);
    },
    async peek(name, lines) {
      need(name);
      calls.push(['peek', name, lines]);
      return Array.from({ length: Math.min(lines, 3) }, (_, index) => `linha ${index + 1} de ${name}`);
    },
    async peekAll(lines) {
      const result = {};
      for (const name of store.keys()) result[name] = await this.peek(name, lines);
      return result;
    },
  };
}

async function setup({ ttydPort = 1, runAgent, gate } = {}) {
  const base = await realpath(await mkdtemp(path.join(os.tmpdir(), 'hub-srv-')));
  const root = path.join(base, 'projetos');
  await mkdir(path.join(root, 'app', 'src'), { recursive: true });
  await mkdir(path.join(root, 'api'));
  await mkdir(path.join(root, '.git'));
  await mkdir(path.join(root, 'node_modules'));
  await writeFile(path.join(root, 'arquivo.txt'), 'x');
  const sessions = fakeSessions();
  const agentCalls = [];
  const orchestrator = new Orchestrator({
    dir: path.join(base, 'runs'),
    runAgent:
      runAgent ??
      (async (call) => {
        agentCalls.push(call);
        return { ok: true, output: `resposta de ${call.agent}`, error: '', code: 0, timedOut: false, cancelled: false, durationMs: 3 };
      }),
    installedAgents: () => ['claude', 'copilot', 'codex'],
    persistDelayMs: 5,
  });
  await orchestrator.init();
  const hub = createHub({
    token: TOKEN,
    root,
    sessions,
    orchestrator,
    html: HTML,
    version: '9.9.9',
    now: () => NOW,
    memInfo: async () => ({ totalMb: 4000, availableMb: 3000 }),
    ttydPort,
    ...(gate ? { gate } : {}),
  });
  await new Promise((resolve) => hub.server.listen(0, '127.0.0.1', resolve));
  const port = hub.server.address().port;
  const api = (method, route, { body, headers, token = TOKEN, raw } = {}) => request({ port, method, path: `/${token}${route}`, headers, body, raw });
  return {
    base,
    root,
    port,
    hub,
    sessions,
    agentCalls,
    api,
    origin: `http://127.0.0.1:${port}`,
    async cleanup() {
      await hub.close();
      await rm(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    },
  };
}

test('o token precisa ter de 32 a 128 caracteres hexadecimais', () => {
  for (const token of ['', 'curto', 'g'.repeat(32), 'A'.repeat(32), 'a'.repeat(31), 'a'.repeat(129), undefined]) {
    assert.throws(() => createHub({ token, root: '.', html: HTML, sessions: fakeSessions(), orchestrator: {} }), /Token invalido/);
  }
});

test('todas as rotas exigem o token no primeiro segmento da URL', async () => {
  const env = await setup();
  try {
    for (const url of ['/', '/api/state', `/${'0'.repeat(32)}/api/state`, `/${TOKEN}x/api/state`, `/${TOKEN.toUpperCase()}/api/state`, '//api/state', `/api/${TOKEN}/state`]) {
      const result = await request({ port: env.port, path: url });
      assert.equal(result.status, 404, url);
      assert.equal(result.text, 'Não encontrado');
    }
    const redirect = await request({ port: env.port, path: `/${TOKEN}?x=1` });
    assert.equal(redirect.status, 302);
    assert.equal(redirect.headers.location, `/${TOKEN}/?x=1`);

    const ok = await env.api('GET', '/api/state');
    assert.equal(ok.status, 200);
    const unknown = await env.api('GET', '/api/nada');
    assert.equal(unknown.status, 404);
    assert.equal(unknown.json.error, 'Não encontrado');
  } finally {
    await env.cleanup();
  }
});

test('o cabeçalho Host precisa ser de loopback (proteção contra DNS rebinding)', async () => {
  const env = await setup();
  try {
    for (const host of ['evil.example', 'evil.example:7690', '127.0.0.1.evil.com', '10.0.0.5:7690', 'localhost.evil.com', 'localhost:99999999']) {
      const result = await env.api('GET', '/api/state', { headers: { Host: host } });
      assert.equal(result.status, 403, `Host "${host}"`);
    }
    for (const host of ['127.0.0.1', '127.0.0.1:7690', 'localhost', 'localhost:8000', 'LOCALHOST:1234', '[::1]:7690']) {
      const result = await env.api('GET', '/api/state', { headers: { Host: host } });
      assert.equal(result.status, 200, `Host "${host}"`);
    }

    const withoutHost = await new Promise((resolve, reject) => {
      const socket = net.connect({ host: '127.0.0.1', port: env.port }, () => socket.write(`GET /${TOKEN}/api/state HTTP/1.0\r\n\r\n`));
      let text = '';
      socket.on('data', (chunk) => {
        text += chunk;
      });
      socket.on('close', () => resolve(text));
      socket.on('error', reject);
    });
    assert.match(withoutHost, /^HTTP\/1\.1 403 /);
  } finally {
    await env.cleanup();
  }
});

test('mutações recusam Origin diferente do Host; sem Origin (curl, CLI) é aceito', async () => {
  const env = await setup();
  try {
    const body = { agent: 'claude', dir: env.root };
    for (const origin of ['http://evil.example', 'http://127.0.0.1:9', 'null', 'não-é-url', `http://localhost:${env.port}`]) {
      const result = await env.api('POST', '/api/sessions', { body, headers: { Origin: origin } });
      assert.equal(result.status, 403, `Origin ${origin}`);
      assert.equal(result.json.error, 'Origem não permitida');
    }
    assert.equal(env.sessions.calls.length, 0);
    assert.equal((await env.api('POST', '/api/sessions', { body, headers: { Origin: env.origin } })).status, 201);
    assert.equal((await env.api('POST', '/api/sessions', { body })).status, 201);
    assert.equal((await env.api('GET', '/api/state', { headers: { Origin: 'http://evil.example' } })).status, 200);
    assert.equal((await env.api('DELETE', '/api/sessions/ia-claude-1', { headers: { Origin: 'http://evil.example' } })).status, 403);
  } finally {
    await env.cleanup();
  }
});

test('a página usa nonce novo a cada resposta e uma CSP restritiva', async () => {
  const env = await setup();
  try {
    const first = await env.api('GET', '/');
    const second = await env.api('GET', '/');
    assert.equal(first.status, 200);
    assert.match(first.headers['content-type'], /text\/html/);
    const nonce = /script-src 'nonce-([^']+)'/.exec(first.headers['content-security-policy'])[1];
    assert.ok(first.text.includes(`<script nonce="${nonce}">`));
    assert.ok(first.text.includes(`<style nonce="${nonce}">`));
    assert.ok(!first.text.includes('__NONCE__'));
    const nonce2 = /script-src 'nonce-([^']+)'/.exec(second.headers['content-security-policy'])[1];
    assert.notEqual(nonce, nonce2);

    const csp = first.headers['content-security-policy'];
    for (const directive of ["default-src 'none'", `style-src 'nonce-${nonce}'`, "connect-src 'self'", "frame-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'none'"]) {
      assert.ok(csp.includes(directive), directive);
    }
    assert.ok(!csp.includes('unsafe'));
    assert.equal(first.headers['x-frame-options'], 'DENY');
    assert.equal(first.headers['x-content-type-options'], 'nosniff');
    assert.equal(first.headers['referrer-policy'], 'no-referrer');
    assert.equal(first.headers['cache-control'], 'no-store');
  } finally {
    await env.cleanup();
  }
});

test('/api/state descreve agentes, sessões, memória e limites', async () => {
  const env = await setup();
  try {
    env.sessions.store.set('ia-claude-1', { name: 'ia-claude-1', agent: 'claude', dir: env.root, dead: false, exitStatus: null, activity: NOW - 1, created: 1 });
    env.sessions.store.set('ia-codex-1', { name: 'ia-codex-1', agent: 'codex', dir: env.root, dead: false, exitStatus: null, activity: NOW - 60, created: 2 });
    env.sessions.store.set('ia-agy-1', { name: 'ia-agy-1', agent: 'agy', dir: env.root, dead: true, exitStatus: 2, activity: NOW - 5, created: 3 });
    const { status, json } = await env.api('GET', '/api/state');
    assert.equal(status, 200);
    assert.equal(json.version, '9.9.9');
    assert.equal(json.now, NOW);
    assert.equal(json.root, env.root);
    assert.deepEqual(json.mem, { totalMb: 4000, availableMb: 3000 });
    assert.deepEqual(json.limits, { maxSessions: 3, minFreeMb: 512 });
    assert.equal(json.tmux, true);
    assert.equal(json.tmuxError, null);
    assert.equal(json.runs.active, 0);
    assert.deepEqual(json.agents.map((agent) => agent.id), ['copilot', 'claude', 'codex', 'agy', 'opencode', 'hermes', 'shell']);
    assert.deepEqual(
      Object.fromEntries(json.sessions.map((session) => [session.name, session.state])),
      { 'ia-claude-1': 'working', 'ia-codex-1': 'idle', 'ia-agy-1': 'dead' },
    );
    assert.equal(json.sessions[1].idleSec, 60);
  } finally {
    await env.cleanup();
  }
});

test('/api/state continua respondendo quando o tmux recusa o acesso e explica o motivo em tmuxError', async () => {
  const env = await setup();
  try {
    env.sessions.list = async () => {
      throw new HubError(503, 'O tmux dos agentes está em outra instância do PRoot');
    };
    const blocked = await env.api('GET', '/api/state');
    assert.equal(blocked.status, 200);
    assert.deepEqual(blocked.json.sessions, []);
    assert.equal(blocked.json.tmuxError, 'O tmux dos agentes está em outra instância do PRoot');
    env.sessions.list = async () => {
      throw new Error('detalhe interno em /data/data/segredo');
    };
    const unexpected = await env.api('GET', '/api/state');
    assert.equal(unexpected.status, 200);
    assert.equal(unexpected.json.tmuxError, 'Não foi possível consultar o tmux dos agentes');
  } finally {
    await env.cleanup();
  }
});

test('/api/dirs lista só pastas visíveis dentro da raiz e recusa fugas', async () => {
  const env = await setup();
  try {
    const top = await env.api('GET', '/api/dirs');
    assert.equal(top.status, 200);
    assert.equal(top.json.path, env.root);
    assert.equal(top.json.parent, null);
    assert.deepEqual(top.json.entries.map((entry) => entry.name), ['api', 'app']);

    const sub = await env.api('GET', `/api/dirs?path=${encodeURIComponent(path.join(env.root, 'app'))}`);
    assert.equal(sub.json.parent, env.root);
    assert.deepEqual(sub.json.entries.map((entry) => entry.name), ['src']);

    const relative = await env.api('GET', '/api/dirs?path=app/src');
    assert.equal(relative.json.path, path.join(env.root, 'app', 'src'));

    for (const bad of ['..', '../..', env.base, path.parse(env.root).root, 'arquivo.txt', 'nao-existe']) {
      const result = await env.api('GET', `/api/dirs?path=${encodeURIComponent(bad)}`);
      assert.equal(result.status, 400, bad);
      assert.match(result.json.error, /Pasta|caminho/);
    }

    try {
      await symlink(env.base, path.join(env.root, 'escape'), 'dir');
      const viaLink = await env.api('GET', '/api/dirs?path=escape');
      assert.equal(viaLink.status, 400);
      assert.match(viaLink.json.error, /fora da raiz/);
    } catch (error) {
      if (error.code !== 'EPERM') throw error;
    }
  } finally {
    await env.cleanup();
  }
});

test('API de sessões: criar, enviar, teclas, prévia, reiniciar e encerrar', async () => {
  const env = await setup();
  try {
    const created = await env.api('POST', '/api/sessions', { body: { agent: 'claude', dir: 'app' } });
    assert.equal(created.status, 201);
    assert.equal(created.json.name, 'ia-claude-1');
    assert.equal(created.json.dir, path.join(env.root, 'app'));
    assert.equal(created.json.state, 'working');
    assert.deepEqual(env.sessions.calls[0], ['create', 'claude', path.join(env.root, 'app')]);

    const outside = await env.api('POST', '/api/sessions', { body: { agent: 'claude', dir: '..' } });
    assert.equal(outside.status, 400);
    assert.match(outside.json.error, /fora da raiz/);

    const full = await env.api('POST', '/api/sessions', { body: { agent: 'cheio' } });
    assert.equal(full.status, 409);

    const sent = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: { text: 'olá; mundo' } });
    assert.equal(sent.status, 200);
    assert.deepEqual(env.sessions.calls.at(-1), ['send', 'ia-claude-1', 'olá; mundo', { enter: true }]);
    await env.api('POST', '/api/sessions/ia-claude-1/send', { body: { text: 'rascunho', enter: false } });
    assert.deepEqual(env.sessions.calls.at(-1), ['send', 'ia-claude-1', 'rascunho', { enter: false }]);

    assert.equal((await env.api('POST', '/api/sessions/ia-claude-1/key', { body: { key: 'C-c' } })).status, 200);
    const refusedKey = await env.api('POST', '/api/sessions/ia-claude-1/key', { body: { key: 'C-d' } });
    assert.equal(refusedKey.status, 400);
    assert.match(refusedKey.json.error, /Tecla não permitida/);
    for (const key of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
      const inherited = await env.api('POST', '/api/sessions/ia-claude-1/key', { body: { key } });
      assert.equal(inherited.status, 400, `a tecla "${key}" vem do protótipo do objeto, não da lista permitida`);
    }
    assert.equal(env.sessions.calls.filter((call) => call[0] === 'key').length, 1, 'só a Ctrl+C passou');
    const peek = await env.api('GET', '/api/sessions/ia-claude-1/peek?lines=2');
    assert.deepEqual(peek.json.lines, ['linha 1 de ia-claude-1', 'linha 2 de ia-claude-1', 'linha 3 de ia-claude-1']);
    assert.deepEqual(env.sessions.calls.at(-1), ['peek', 'ia-claude-1', 3], 'o mínimo é 3 linhas');
    await env.api('GET', '/api/sessions/ia-claude-1/peek?lines=999');
    assert.equal(env.sessions.calls.at(-1)[2], 40, 'o máximo é 40 linhas');
    await env.api('GET', '/api/sessions/ia-claude-1/peek');
    assert.equal(env.sessions.calls.at(-1)[2], 14);
    const previews = await env.api('GET', '/api/previews?lines=50');
    assert.deepEqual(Object.keys(previews.json), ['ia-claude-1']);

    assert.equal((await env.api('POST', '/api/sessions/ia-claude-1/restart')).status, 200);
    assert.equal((await env.api('DELETE', '/api/sessions/ia-claude-1')).status, 200);
    assert.equal((await env.api('DELETE', '/api/sessions/ia-claude-1')).status, 404);
    assert.equal((await env.api('POST', '/api/sessions/ia-claude-1/send', { body: { text: 'x' } })).status, 404);
  } finally {
    await env.cleanup();
  }
});

test('nomes de sessão inválidos e métodos errados são recusados', async () => {
  const env = await setup();
  try {
    for (const name of ['ia-claude', 'claude-1', 'ia-claude-1234', 'IA-claude-1', 'ia-cl%20aude-1', 'ia-claude-1%3Brm']) {
      const result = await env.api('DELETE', `/api/sessions/${name}`);
      assert.equal(result.status, 400, name);
    }
    assert.equal((await env.api('DELETE', '/api/sessions/..')).status, 404, '".." é normalizado pela URL e nunca chega à rota');
    assert.equal((await env.api('GET', '/api/sessions/ia-claude-1')).status, 404);
    assert.equal((await env.api('PUT', '/api/sessions/ia-claude-1/send', { body: {} })).status, 404);
    assert.equal((await env.api('GET', '/api/sessions/ia-claude-1/send')).status, 404);
  } finally {
    await env.cleanup();
  }
});

test('corpo da requisição: tipo, tamanho e JSON são validados', async () => {
  const env = await setup();
  try {
    await env.api('POST', '/api/sessions', { body: { agent: 'claude' } });
    const plain = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: '{"text":"x"}', raw: true, headers: { 'Content-Type': 'text/plain' } });
    assert.equal(plain.status, 415);
    const broken = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: '{"text":', raw: true, headers: { 'Content-Type': 'application/json' } });
    assert.equal(broken.status, 400);
    assert.equal(broken.json.error, 'JSON inválido');
    const array = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: '[1]', raw: true, headers: { 'Content-Type': 'application/json' } });
    assert.equal(array.status, 400);
    const huge = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: JSON.stringify({ text: 'x'.repeat(70 * 1024) }), raw: true, headers: { 'Content-Type': 'application/json' } });
    assert.equal(huge.status, 413);
    const empty = await env.api('POST', '/api/sessions/ia-claude-1/key');
    assert.equal(empty.status, 400);
  } finally {
    await env.cleanup();
  }
});

test('corpo acima do limite recebe 413 mesmo quando o cliente ainda está enviando', async () => {
  const env = await setup();
  try {
    await env.api('POST', '/api/sessions', { body: { agent: 'claude' } });
    const json = { 'Content-Type': 'application/json' };
    // 300 KB: o corpo é lido e descartado, então o cliente recebe a resposta em vez de uma conexão derrubada
    for (let round = 0; round < 3; round += 1) {
      const large = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: JSON.stringify({ text: 'x'.repeat(300 * 1024) }), raw: true, headers: json });
      assert.equal(large.status, 413);
      assert.equal(large.json.error, 'Corpo da requisição grande demais');
      assert.equal(large.headers.connection, 'close', 'o cliente não deve reaproveitar a conexão');
    }
    assert.equal(env.sessions.calls.filter((call) => call[0] === 'send').length, 0);

    // muito acima de 1 MB a conexão pode ser derrubada; o importante é o painel continuar de pé
    const outcome = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: 'x'.repeat(3 * 1024 * 1024), raw: true, headers: json }).then(
      (answer) => answer.status,
      (error) => error.code,
    );
    assert.ok(outcome === 413 || ['ECONNRESET', 'EPIPE'].includes(outcome), `resultado inesperado: ${outcome}`);
    assert.equal((await env.api('GET', '/api/state')).status, 200);
    const ok = await env.api('POST', '/api/sessions/ia-claude-1/send', { body: { text: 'ainda funciona' } });
    assert.equal(ok.status, 200);
  } finally {
    await env.cleanup();
  }
});

test('caminhos que começam com "//" são recusados como não encontrados, sem erro interno', async () => {
  const env = await setup();
  try {
    for (const url of ['//', '///', `//${TOKEN}/api/state`, '//evil.example/x']) {
      const result = await request({ port: env.port, path: url });
      assert.equal(result.status, 404, url);
      assert.equal(result.text, 'Não encontrado', url);
    }
    // com o token correto, uma barra a mais dentro da rota é só uma rota desconhecida (nunca 500)
    const doubled = await request({ port: env.port, path: `/${TOKEN}//api/state` });
    assert.equal(doubled.status, 404);
    assert.equal(doubled.json.error, 'Não encontrado');
  } finally {
    await env.cleanup();
  }
});

test('broadcast envia a várias sessões e informa falhas individuais', async () => {
  const env = await setup();
  try {
    for (const agent of ['claude', 'codex']) await env.api('POST', '/api/sessions', { body: { agent } });
    env.sessions.store.set('ia-agy-9', { name: 'ia-agy-9', agent: 'agy', dir: env.root, dead: false, exitStatus: null, activity: NOW, created: 9 });

    const result = await env.api('POST', '/api/broadcast', { body: { names: ['ia-claude-1', 'ia-codex-2', 'ia-nada-3', 'ia-agy-9', 'ia-claude-1'], text: 'rode os testes' } });
    assert.equal(result.status, 200);
    assert.deepEqual(
      result.json.results.map((item) => [item.name, item.ok, item.error ?? null]),
      [
        ['ia-claude-1', true, null],
        ['ia-codex-2', true, null],
        ['ia-nada-3', false, 'Sessão não encontrada'],
        ['ia-agy-9', false, 'tmux falhou'],
      ],
    );
    const sends = env.sessions.calls.filter((call) => call[0] === 'send');
    assert.deepEqual(sends.map((call) => call[1]), ['ia-claude-1', 'ia-codex-2']);
    assert.deepEqual(sends[0][3], { enter: true });

    await env.api('POST', '/api/broadcast', { body: { names: ['ia-claude-1', 'ia-codex-2'], key: 'Escape' } });
    assert.deepEqual(env.sessions.calls.filter((call) => call[0] === 'key').map((call) => call.slice(1)), [['ia-claude-1', 'Escape'], ['ia-codex-2', 'Escape']]);

    await env.api('POST', '/api/broadcast', { body: { names: ['ia-claude-1'], text: 'só colar', enter: false } });
    assert.deepEqual(env.sessions.calls.filter((call) => call[0] === 'send').at(-1)[3], { enter: false });

    assert.equal((await env.api('POST', '/api/broadcast', { body: { names: [], text: 'x' } })).status, 400);
    assert.equal((await env.api('POST', '/api/broadcast', { body: { text: 'x' } })).status, 400);
    const many = Array.from({ length: 13 }, (_, index) => `ia-claude-${index + 1}`);
    assert.equal((await env.api('POST', '/api/broadcast', { body: { names: many, text: 'x' } })).status, 400);
  } finally {
    await env.cleanup();
  }
});

test('API de execuções: iniciar, acompanhar por revisão, enviar o resultado e apagar', async () => {
  const env = await setup();
  try {
    const started = await env.api('POST', '/api/runs', { body: { mode: 'compare', prompt: 'Qual a capital?', dir: 'app', agents: ['claude', 'copilot'] } });
    assert.equal(started.status, 202);
    assert.match(started.json.id, /^\d{8}-\d{6}-[0-9a-f]{6}$/);
    assert.equal(started.json.dir, path.join(env.root, 'app'));
    assert.equal(typeof started.json.serverTime, 'number');
    const id = started.json.id;

    const done = await waitUntil(async () => {
      const current = await env.api('GET', `/api/runs/${id}`);
      return current.json.status === 'done' ? current.json : null;
    }, { message: 'a execução deveria terminar' });
    assert.equal(done.steps.length, 2);
    assert.equal(done.steps[0].output, 'resposta de claude');
    assert.ok(env.agentCalls.every((call) => call.dir === path.join(env.root, 'app')));

    const unchanged = await env.api('GET', `/api/runs/${id}?rev=${done.rev}`);
    assert.equal(unchanged.json.unchanged, true);
    assert.equal(unchanged.json.rev, done.rev);
    assert.equal(unchanged.json.steps, undefined);
    const stale = await env.api('GET', `/api/runs/${id}?rev=0`);
    assert.equal(stale.json.id, id);

    const list = await env.api('GET', '/api/runs');
    assert.equal(list.json.runs[0].id, id);
    assert.equal(typeof list.json.serverTime, 'number');

    const noResultYet = await env.api('POST', `/api/runs/${id}/send`, { body: { name: 'ia-claude-1' } });
    assert.equal(noResultYet.status, 404, 'a sessão ainda não existe');

    await env.api('POST', '/api/sessions', { body: { agent: 'claude' } });
    const sent = await env.api('POST', `/api/runs/${id}/send`, { body: { name: 'ia-claude-1' } });
    assert.equal(sent.status, 200);
    assert.deepEqual(env.sessions.calls.at(-1), ['send', 'ia-claude-1', 'resposta de copilot', { enter: false }]);
    await env.api('POST', `/api/runs/${id}/send`, { body: { name: 'ia-claude-1', enter: true } });
    assert.equal(env.sessions.calls.at(-1)[3].enter, true);

    assert.equal((await env.api('POST', `/api/runs/${id}/cancel`)).status, 409);
    assert.equal((await env.api('DELETE', `/api/runs/${id}`)).status, 200);
    assert.equal((await env.api('GET', `/api/runs/${id}`)).status, 404);
    assert.equal((await env.api('GET', '/api/runs/..%2f..%2fetc')).status, 404);
    assert.equal((await env.api('GET', '/api/runs/nao-e-id')).status, 404);
  } finally {
    await env.cleanup();
  }
});

test('API de execuções: pedidos inválidos e cancelamento', async () => {
  const waiting = ({ signal }) =>
    new Promise((resolve) => {
      signal.addEventListener('abort', () => resolve({ ok: false, output: '', error: 'Cancelado', code: null, timedOut: false, cancelled: true, durationMs: 1 }), { once: true });
    });
  const env = await setup({ runAgent: waiting });
  try {
    const cases = [
      [{ mode: 'compare', prompt: '', agents: ['claude', 'copilot'] }, /Escreva a tarefa/],
      [{ mode: 'compare', prompt: 'x', agents: ['claude'] }, /pelo menos 2/],
      [{ mode: 'compare', prompt: 'x', agents: ['claude', 'agy'] }, /Antigravity não está instalado/],
      [{ mode: 'magia', prompt: 'x' }, /Modo inválido/],
      [{ mode: 'compare', prompt: 'x', agents: ['claude', 'copilot'], dir: '..' }, /fora da raiz/],
    ];
    for (const [body, pattern] of cases) {
      const result = await env.api('POST', '/api/runs', { body });
      assert.equal(result.status, 400, JSON.stringify(body));
      assert.match(result.json.error, pattern);
    }

    const started = await env.api('POST', '/api/runs', { body: { mode: 'compare', prompt: 'x', agents: ['claude', 'copilot'] } });
    const id = started.json.id;
    const running = (await env.api('GET', '/api/state')).json;
    assert.equal(running.runs.active, 1);
    assert.equal((await env.api('DELETE', `/api/runs/${id}`)).status, 409);
    assert.equal((await env.api('POST', `/api/runs/${id}/send`, { body: { name: 'ia-claude-1' } })).status, 409);
    assert.equal((await env.api('POST', `/api/runs/${id}/cancel`)).status, 200);
    const cancelled = await waitUntil(async () => {
      const current = await env.api('GET', `/api/runs/${id}`);
      return current.json.status === 'cancelled' ? current.json : null;
    });
    assert.equal(cancelled.error, 'Execução cancelada');
  } finally {
    await env.cleanup();
  }
});

test('proxy HTTP do ttyd: só GET/HEAD, só dentro de /t/ e 502 quando o ttyd cai', async () => {
  const ttyd = await startFakeTtyd();
  const env = await setup({ ttydPort: ttyd.port });
  try {
    const page = await env.api('GET', '/t/?arg=ia-claude-1');
    assert.equal(page.status, 200);
    assert.equal(page.text, '<title>ttyd falso</title>');
    assert.equal(page.headers['x-fake-ttyd'], '1');
    assert.equal(page.headers['referrer-policy'], 'no-referrer');
    assert.equal(ttyd.requests.at(-1).url, `/${TOKEN}/t/?arg=ia-claude-1`);

    const post = await env.api('POST', '/t/token', { body: {} });
    assert.equal(post.status, 405);
    assert.equal((await request({ port: env.port, path: '/t/' })).status, 404);
    assert.equal((await request({ port: env.port, path: `/${'0'.repeat(32)}/t/` })).status, 404);
    assert.equal((await env.api('GET', '/t/', { headers: { Host: 'evil.example' } })).status, 403);

    await ttyd.close();
    const down = await env.api('GET', '/t/');
    assert.equal(down.status, 502);
  } finally {
    await env.cleanup();
    await ttyd.close();
  }
});

test('proxy WebSocket: encaminha só sessões válidas, com token e Origin corretos', async () => {
  const ttyd = await startFakeTtyd();
  const env = await setup({ ttydPort: ttyd.port });
  const good = `/${TOKEN}/t/ws?arg=ia-claude-1`;
  const clients = [];
  try {
    const socket = await connectWs({ port: env.port, path: good, origin: env.origin });
    clients.push(socket);
    assert.equal(socket.refused, false);
    assert.equal(socket.status, 101);
    assert.equal(socket.accept, socket.expectedAccept);
    await socket.waitFor((client) => client.output().includes('0pronto'));
    socket.send('hello');
    await socket.waitFor((client) => client.output().includes('0eco:hello'));
    assert.equal(ttyd.upgrades[0].url, good);
    assert.equal(ttyd.upgrades[0].headers.origin, env.origin);

    const refusals = [
      ['sem token', `/t/ws?arg=ia-claude-1`, env.origin, undefined, 404],
      ['token errado', `/${'0'.repeat(32)}/t/ws?arg=ia-claude-1`, env.origin, undefined, 404],
      ['caminho errado', `/${TOKEN}/t/outro?arg=ia-claude-1`, env.origin, undefined, 404],
      ['api como websocket', `/${TOKEN}/api/state`, env.origin, undefined, 404],
      ['Origin ausente', good, undefined, undefined, 403],
      ['Origin de outro site', good, 'http://evil.example', undefined, 403],
      ['Host estranho', good, env.origin, 'evil.example', 403],
      ['sem sessão', `/${TOKEN}/t/ws`, env.origin, undefined, 400],
      ['sessão inválida', `/${TOKEN}/t/ws?arg=bash`, env.origin, undefined, 400],
      ['injeção no nome', `/${TOKEN}/t/ws?arg=ia-claude-1%3Bid`, env.origin, undefined, 400],
      ['dois argumentos', `/${TOKEN}/t/ws?arg=ia-claude-1&arg=ia-codex-2`, env.origin, undefined, 400],
      ['argumento extra', `/${TOKEN}/t/ws?arg=ia-claude-1&arg=--help`, env.origin, undefined, 400],
    ];
    for (const [label, url, origin, host, status] of refusals) {
      const attempt = await connectWs({ port: env.port, path: url, origin, host });
      assert.equal(attempt.refused, true, label);
      assert.equal(attempt.status, status, label);
    }
    assert.equal(ttyd.upgrades.length, 1, 'nenhuma tentativa recusada chegou ao ttyd');
  } finally {
    for (const client of clients) client.close();
    await env.cleanup();
    await ttyd.close();
  }
});

// Manda o pedido de upgrade "na mão" e reinicia a conexão (RST) assim que chega a primeira linha da resposta.
function upgradeThenReset({ port, url, origin }) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    let reply = '';
    let reset = false;
    socket.on('connect', () => {
      const headers = [
        `GET ${url} HTTP/1.1`,
        `Host: 127.0.0.1:${port}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}`,
        'Sec-WebSocket-Protocol: tty',
        ...(origin ? [`Origin: ${origin}`] : []),
        '',
        '',
      ];
      socket.write(headers.join('\r\n'));
    });
    socket.on('data', (chunk) => {
      reply += chunk;
      if (!reset && reply.includes('\r\n')) {
        reset = true;
        socket.resetAndDestroy();
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => resolve(reply.split('\r\n')[0]));
  });
}

test('cliente que reinicia a conexão durante o upgrade não derruba o painel', async () => {
  const ttyd = await startFakeTtyd();
  const env = await setup({ ttydPort: ttyd.port });
  try {
    const attempts = [
      ['token errado', `/${'0'.repeat(32)}/t/ws?arg=ia-claude-1`, 'HTTP/1.1 404 Not Found'],
      ['caminho "//"', '//', 'HTTP/1.1 400 Bad Request'],
      ['host externo na URL', '//evil.example/t/ws?arg=ia-claude-1', 'HTTP/1.1 400 Bad Request'],
      ['sessão inválida', `/${TOKEN}/t/ws?arg=bash`, 'HTTP/1.1 400 Bad Request'],
      ['upgrade aceito', `/${TOKEN}/t/ws?arg=ia-claude-1`, 'HTTP/1.1 101 Switching Protocols'],
    ];
    for (const [label, url, expected] of attempts) {
      for (let round = 0; round < 3; round += 1) {
        assert.equal(await upgradeThenReset({ port: env.port, url, origin: env.origin }), expected, label);
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 150));

    assert.equal((await env.api('GET', '/api/state')).status, 200, 'o painel continua respondendo');
    const socket = await connectWs({ port: env.port, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, origin: env.origin });
    try {
      await socket.waitFor((client) => client.output().includes('0pronto'));
    } finally {
      socket.close();
    }
  } finally {
    await env.cleanup();
    await ttyd.close();
  }
});

test('close() encerra mesmo com terminais conectados', async () => {
  const ttyd = await startFakeTtyd();
  const env = await setup({ ttydPort: ttyd.port });
  try {
    const socket = await connectWs({ port: env.port, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, origin: env.origin });
    await socket.waitFor((client) => client.output().includes('0pronto'));
    const keepAlive = http.request({ host: '127.0.0.1', port: env.port, path: '/', headers: { Connection: 'keep-alive' } });
    keepAlive.on('error', () => {});
    keepAlive.end();
    const started = Date.now();
    await env.hub.close();
    assert.ok(Date.now() - started < 4000);
    await socket.waitFor((client) => client.closed, 3000);
  } finally {
    await rm(env.base, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
    await ttyd.close();
  }
});

test('frente de decisao (Jev) no servidor: bloqueio recusa, confirmacao exige confirmed=true', async () => {
  const seen = [];
  let answer = { status: 'disabled' };
  const env = await setup({
    gate: async (request) => {
      seen.push(request);
      return answer;
    },
  });
  const spec = { mode: 'compare', prompt: 'Explique o projeto', dir: 'app', agents: ['claude', 'copilot'] };
  const decided = (verdict) => ({
    status: 'decided',
    decision: {
      verdict,
      reasons: verdict === 'allow' ? [] : ['motivo de teste'],
      safety: {},
      clear: 0.9,
      route: { mode: 'compare', modeConfidence: 0.8, agent: 'claude', agentConfidence: 0.7 },
      model: 'jev-test',
    },
  });
  try {
    assert.equal((await env.api('POST', '/api/runs', { body: spec })).status, 202, 'desligado: segue como antes');
    assert.equal(seen.at(-1).task, 'Explique o projeto');
    assert.equal(seen.at(-1).dir, path.join(env.root, 'app'));
    assert.ok(Array.isArray(seen.at(-1).agents), 'o servidor informa os agentes disponiveis');

    answer = decided('block');
    const blocked = await env.api('POST', '/api/runs', { body: { ...spec, confirmed: true } });
    assert.equal(blocked.status, 403, 'bloqueio nao aceita confirmacao');
    assert.equal(blocked.json.jev, 'blocked');
    answer = { status: 'secret', secrets: ['token GitHub'] };
    assert.equal((await env.api('POST', '/api/runs', { body: { ...spec, confirmed: true } })).status, 403, 'segredo nunca segue');

    for (const pending of [decided('confirm'), decided('unclear'), { status: 'unavailable', reason: 'Sem conexao com o TypeSafe' }]) {
      answer = pending;
      const asked = await env.api('POST', '/api/runs', { body: spec });
      assert.equal(asked.status, 409);
      assert.equal(asked.json.jev, 'confirm');
      assert.match(asked.json.error, /Jev/);
      assert.equal((await env.api('POST', '/api/runs', { body: { ...spec, confirmed: 'true' } })).status, 409, 'so o booleano true confirma');
      const confirmed = await env.api('POST', '/api/runs', { body: { ...spec, confirmed: true } });
      assert.equal(confirmed.status, 202);
      assert.equal(confirmed.json.confirmed, undefined, 'a confirmacao nao entra na execucao');
    }
    answer = decided('allow');
    assert.equal((await env.api('POST', '/api/runs', { body: spec })).status, 202);
  } finally {
    await env.cleanup();
  }
});
