import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { Orchestrator } from '../../scripts/hub/orchestrator.mjs';
import { createHub } from '../../scripts/hub/server.mjs';
import { Sessions } from '../../scripts/hub/sessions.mjs';
import { connectWs, createStubHome, freePort, hasCommand, request, waitUntil } from './helpers.mjs';

const HUB = fileURLToPath(new URL('../../scripts/hub/', import.meta.url));
const TOKEN = '0123456789abcdef0123456789abcdef';
const HTML = '<!doctype html><title>painel</title><script nonce="__NONCE__"></script>';
const skip = hasCommand('tmux') && hasCommand('ttyd', ['--version']) ? false : 'tmux e ttyd são necessários';

async function waitForPort(port) {
  await waitUntil(
    () =>
      new Promise((resolve) => {
        const socket = net.connect({ host: '127.0.0.1', port }, () => {
          socket.destroy();
          resolve(true);
        });
        socket.on('error', () => resolve(false));
      }),
    { message: `ttyd deveria abrir a porta ${port}` },
  );
}

async function setup() {
  const stub = await createStubHome();
  const socket = `hube2e-${process.pid}-${Date.now().toString(36)}`;
  const sessions = new Sessions({ socket, config: path.join(HUB, 'tmux.conf'), minFreeMb: 0, searchPath: stub.searchPath, env: stub.env, previewTtlMs: 0 });
  const orchestrator = new Orchestrator({ dir: path.join(stub.base, 'runs'), installedAgents: () => [], persistDelayMs: 5 });
  await orchestrator.init();

  const ttydPort = await freePort();
  // Mesmos argumentos que o webui.sh usa para o terminal do painel.
  const ttyd = spawn(
    'ttyd',
    ['-i', '127.0.0.1', '-p', String(ttydPort), '-W', '-a', '-b', `/${TOKEN}/t`, '-m', '0', '-O', 'bash', path.join(HUB, 'attach.sh')],
    { env: { ...stub.env, TERMUX_AI_HUB_SOCKET: socket }, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let ttydLog = '';
  ttyd.stdout.on('data', (chunk) => (ttydLog += chunk));
  ttyd.stderr.on('data', (chunk) => (ttydLog += chunk));
  await waitForPort(ttydPort).catch((error) => {
    throw new Error(`${error.message}\n${ttydLog}`);
  });

  const hub = createHub({ token: TOKEN, root: stub.work, sessions, orchestrator, ttydPort, html: HTML, memInfo: async () => ({ totalMb: 4000, availableMb: 3000 }) });
  await new Promise((resolve) => hub.server.listen(0, '127.0.0.1', resolve));
  const port = hub.server.address().port;
  return {
    stub,
    socket,
    sessions,
    hub,
    port,
    ttydPort,
    origin: `http://127.0.0.1:${port}`,
    api: (method, route, body) => request({ port, method, path: `/${TOKEN}${route}`, body }),
    async cleanup() {
      await hub.close();
      ttyd.kill('SIGKILL');
      spawnSync('tmux', ['-L', socket, 'kill-server'], { stdio: 'ignore' });
      await stub.cleanup();
    },
  };
}

const terminalText = (client) => client.output().replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '');

test('terminal ao vivo: ttyd + tmux + proxy do painel, entrada e saída em tempo real', { skip }, async () => {
  const env = await setup();
  const clients = [];
  try {
    const session = await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    assert.equal(session.name, 'ia-claude-1');

    const page = await request({ port: env.port, path: `/${TOKEN}/t/?arg=ia-claude-1` });
    assert.equal(page.status, 200);
    assert.match(page.text, /<title>/i);
    const wsToken = await request({ port: env.port, path: `/${TOKEN}/t/token` });
    assert.equal(wsToken.status, 200);

    const terminal = await connectWs({ port: env.port, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, origin: env.origin });
    clients.push(terminal);
    assert.equal(terminal.refused, false, `o upgrade deveria funcionar (status ${terminal.status})`);
    terminal.send(JSON.stringify({ AuthToken: '', columns: 100, rows: 30 }));
    await terminal.waitFor((client) => terminalText(client).includes('PRONTO-claude'), 10000);

    terminal.send('0ola do navegador\r');
    await waitUntil(async () => (await env.stub.readLog('claude')).includes('ola do navegador'), { message: 'a digitação deve chegar ao agente' });
    await terminal.waitFor((client) => terminalText(client).includes('eco: ola do navegador'));

    await env.sessions.send('ia-claude-1', 'pela API; com ponto e vírgula;');
    await terminal.waitFor((client) => terminalText(client).includes('eco: pela API; com ponto e vírgula;'));

    terminal.send(`1${JSON.stringify({ columns: 90, rows: 20 })}`);
    await env.sessions.send('ia-claude-1', 'depois do resize');
    await terminal.waitFor((client) => terminalText(client).includes('eco: depois do resize'));

    const viewer = await connectWs({ port: env.port, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, origin: env.origin });
    clients.push(viewer);
    viewer.send(JSON.stringify({ AuthToken: '', columns: 80, rows: 24 }));
    await viewer.waitFor((client) => terminalText(client).includes('eco: depois do resize'), 10000);
  } finally {
    for (const client of clients) client.close();
    await env.cleanup();
  }
});

test('o painel recusa o que não é sessão do hub, mesmo falando direto com o proxy', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    const refused = [
      `/${TOKEN}/t/ws?arg=bash`,
      `/${TOKEN}/t/ws?arg=ia-claude-1&arg=-h`,
      `/${TOKEN}/t/ws?arg=ia-claude-1%3Becho`,
      `/${TOKEN}/t/ws`,
    ];
    for (const url of refused) {
      const attempt = await connectWs({ port: env.port, path: url, origin: env.origin });
      assert.equal(attempt.refused, true, url);
      assert.equal(attempt.status, 400, url);
    }
    const noOrigin = await connectWs({ port: env.port, path: `/${TOKEN}/t/ws?arg=ia-claude-1` });
    assert.equal(noOrigin.refused, true);
    assert.equal(noOrigin.status, 403);

    const direct = await connectWs({ port: env.ttydPort, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, origin: 'http://evil.example', allowHangup: true });
    assert.equal(direct.refused, true, 'o ttyd com -O também confere o Origin');

    const directNoOrigin = await connectWs({ port: env.ttydPort, path: `/${TOKEN}/t/ws?arg=ia-claude-1`, allowHangup: true });
    assert.equal(directNoOrigin.refused, true, 'o ttyd com -O recusa upgrade sem Origin');

    const wrongSession = await connectWs({ port: env.ttydPort, path: `/${TOKEN}/t/ws?arg=bash`, origin: `http://127.0.0.1:${env.ttydPort}` });
    assert.equal(wrongSession.refused, false);
    wrongSession.send(JSON.stringify({ AuthToken: '', columns: 80, rows: 24 }));
    await wrongSession.waitFor((client) => terminalText(client).includes('Sessao invalida.'), 10000);
    wrongSession.close();
  } finally {
    await env.cleanup();
  }
});

test('a API de sessões do hub controla o tmux real de ponta a ponta', { skip }, async () => {
  const env = await setup();
  try {
    const created = await env.api('POST', '/api/sessions', { agent: 'claude', dir: '.' });
    assert.equal(created.status, 201, created.text);
    assert.equal(created.json.name, 'ia-claude-1');
    assert.equal(created.json.dir, env.stub.work);

    await waitUntil(async () => (await env.api('GET', '/api/sessions/ia-claude-1/peek')).json.lines.some((line) => line.includes('PRONTO-claude')));
    const sent = await env.api('POST', '/api/broadcast', { names: ['ia-claude-1', 'ia-codex-1'], text: 'olá para todos' });
    assert.deepEqual(sent.json.results.map((item) => item.ok), [true, false]);
    await waitUntil(async () => (await env.stub.readLog('claude')).includes('olá para todos'));

    const state = await env.api('GET', '/api/state');
    assert.equal(state.json.tmux, true);
    assert.equal(state.json.sessions[0].name, 'ia-claude-1');
    assert.equal(state.json.agents.find((agent) => agent.id === 'claude').installed, true);

    const previews = await env.api('GET', '/api/previews?lines=5');
    assert.ok(previews.json['ia-claude-1'].some((line) => line.includes('eco: olá para todos')));

    const key = await env.api('POST', '/api/sessions/ia-claude-1/key', { key: 'C-c' });
    assert.equal(key.status, 200);
    await waitUntil(async () => (await env.api('GET', '/api/state')).json.sessions[0].state === 'dead', { message: 'a sessão deve constar como encerrada' });

    assert.equal((await env.api('POST', '/api/sessions/ia-claude-1/restart')).status, 200);
    await waitUntil(async () => (await env.api('GET', '/api/state')).json.sessions[0].state !== 'dead');
    assert.equal((await env.api('DELETE', '/api/sessions/ia-claude-1')).status, 200);
    assert.deepEqual((await env.api('GET', '/api/state')).json.sessions, []);
  } finally {
    await env.cleanup();
  }
});
