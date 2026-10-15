// Servidor HTTP do painel: API, interface web e proxy do ttyd (terminais ao vivo).
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile, readdir, realpath } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { describeAgents, findExecutable } from './agents.mjs';
import { Orchestrator } from './orchestrator.mjs';
import { SESSION_NAME, Sessions, readMemInfo } from './sessions.mjs';
import { HubError, clampInt, resolveWithin } from './util.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BODY_LIMIT = 64 * 1024;
// Acima do limite o corpo ainda e lido (e descartado) ate aqui, para o cliente receber o 413 em vez de uma conexao derrubada.
const DRAIN_LIMIT = 1024 * 1024;
const HOST_PATTERN = /^(localhost|127\.0\.0\.1|\[::1\])(:\d{1,5})?$/i;
const WORKING_WINDOW_SEC = 4;

const digest = (value) => createHash('sha256').update(String(value)).digest();

function tokenMatches(expected, given) {
  return timingSafeEqual(digest(expected), digest(given ?? ''));
}

// So caminhos simples: "//host/x" seria lido como URL com host proprio e "//" nem seria uma URL valida.
function parseUrl(raw) {
  if (typeof raw !== 'string' || !raw.startsWith('/') || raw.startsWith('//')) return null;
  try {
    return new URL(raw, 'http://hub.local');
  } catch {
    return null;
  }
}

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

function sendPlain(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(text);
}

async function readJson(req) {
  const type = String(req.headers['content-type'] ?? '');
  const chunks = [];
  let size = 0;
  let tooLarge = false;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > DRAIN_LIMIT) throw new HubError(413, 'Corpo da requisição grande demais');
    if (size > BODY_LIMIT) {
      tooLarge = true;
      chunks.length = 0;
    }
    if (!tooLarge) chunks.push(chunk);
  }
  if (tooLarge) throw new HubError(413, 'Corpo da requisição grande demais');
  if (size === 0) return {};
  if (!type.toLowerCase().startsWith('application/json')) throw new HubError(415, 'Use Content-Type: application/json');
  try {
    const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('formato');
    return data;
  } catch {
    throw new HubError(400, 'JSON inválido');
  }
}

function originAllowed(req, { required }) {
  const origin = req.headers.origin;
  if (!origin) return !required;
  try {
    return new URL(origin).host.toLowerCase() === String(req.headers.host ?? '').toLowerCase();
  } catch {
    return false;
  }
}

function decorate(session, now) {
  const idleSec = Math.max(0, now - session.activity);
  const state = session.dead ? 'dead' : idleSec < WORKING_WINDOW_SEC ? 'working' : 'idle';
  return { ...session, idleSec, state };
}

export function createHub({
  token,
  root,
  runsDir,
  sessions = new Sessions(),
  orchestrator = new Orchestrator({ dir: runsDir }),
  ttydPort = 7681,
  html,
  version = 'dev',
  now = () => Math.floor(Date.now() / 1000),
  memInfo = readMemInfo,
}) {
  if (!/^[0-9a-f]{32,128}$/.test(token ?? '')) throw new Error('Token invalido: use de 32 a 128 caracteres hexadecimais');
  const sockets = new Set();

  async function state() {
    const [list, mem] = await Promise.all([sessions.list().catch(() => []), memInfo()]);
    return {
      version,
      now: now(),
      root,
      agents: describeAgents(sessions.searchPath),
      sessions: list.map((session) => decorate(session, now())),
      limits: { maxSessions: sessions.maxSessions, minFreeMb: sessions.minFreeMb },
      mem,
      tmux: Boolean(findExecutable(sessions.tmux, sessions.searchPath) ?? sessions.tmux.includes('/')),
      runs: { active: orchestrator.list().filter((run) => run.status === 'running').length },
    };
  }

  async function listDirs(query) {
    const base = await realpath(root);
    const target = await resolveWithin(base, query || base);
    const entries = (await readdir(target, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules')
      .map((entry) => ({ name: entry.name, path: path.join(target, entry.name) }))
      .sort((a, b) => a.name.localeCompare(b.name))
      .slice(0, 300);
    const parent = target === base ? null : path.dirname(target);
    return { root: base, path: target, parent, entries };
  }

  async function route(req, res, url, rest) {
    const method = req.method;
    const mutating = method !== 'GET' && method !== 'HEAD';
    if (mutating && !originAllowed(req, { required: false })) throw new HubError(403, 'Origem não permitida');

    if (rest === '/' && method === 'GET') {
      const nonce = randomBytes(16).toString('base64');
      const page = html.replaceAll('__NONCE__', nonce);
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Content-Security-Policy': [
          "default-src 'none'",
          `script-src 'nonce-${nonce}'`,
          `style-src 'nonce-${nonce}'`,
          "connect-src 'self'",
          "img-src 'self' data:",
          "frame-src 'self'",
          "base-uri 'none'",
          "form-action 'none'",
          "frame-ancestors 'none'",
        ].join('; '),
      });
      res.end(page);
      return;
    }

    if (rest === '/api/state' && method === 'GET') return sendJson(res, 200, await state());

    if (rest === '/api/previews' && method === 'GET') {
      const lines = clampInt(url.searchParams.get('lines'), 3, 40, 14);
      return sendJson(res, 200, await sessions.peekAll(lines));
    }

    if (rest === '/api/dirs' && method === 'GET') return sendJson(res, 200, await listDirs(url.searchParams.get('path')));

    if (rest === '/api/sessions' && method === 'POST') {
      const body = await readJson(req);
      const dir = await resolveWithin(root, body.dir || root);
      const created = await sessions.create({ agent: String(body.agent ?? ''), dir });
      return sendJson(res, 201, decorate(created, now()));
    }

    const sessionRoute = /^\/api\/sessions\/([^/]+)(?:\/(restart|send|key|peek))?$/.exec(rest);
    if (sessionRoute) {
      const [, name, action] = sessionRoute;
      if (!SESSION_NAME.test(name)) throw new HubError(400, 'Nome de sessão inválido');
      if (!action && method === 'DELETE') {
        await sessions.kill(name);
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'restart' && method === 'POST') {
        await sessions.restart(name);
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'send' && method === 'POST') {
        const body = await readJson(req);
        await sessions.send(name, body.text, { enter: body.enter !== false });
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'key' && method === 'POST') {
        const body = await readJson(req);
        await sessions.key(name, String(body.key ?? ''));
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'peek' && method === 'GET') {
        return sendJson(res, 200, { lines: await sessions.peek(name, clampInt(url.searchParams.get('lines'), 3, 40, 14)) });
      }
    }

    if (rest === '/api/broadcast' && method === 'POST') {
      const body = await readJson(req);
      const names = Array.isArray(body.names) ? [...new Set(body.names.map(String))] : [];
      if (names.length === 0) throw new HubError(400, 'Escolha pelo menos uma sessão');
      if (names.length > 12) throw new HubError(400, 'Sessões demais no mesmo envio');
      const results = await Promise.all(
        names.map(async (name) => {
          try {
            if (body.key) await sessions.key(name, String(body.key));
            else await sessions.send(name, body.text, { enter: body.enter !== false });
            return { name, ok: true };
          } catch (error) {
            return { name, ok: false, error: error.message };
          }
        }),
      );
      return sendJson(res, 200, { results });
    }

    if (rest === '/api/runs' && method === 'GET') {
      await orchestrator.refresh();
      return sendJson(res, 200, { runs: orchestrator.list(), serverTime: Date.now() });
    }

    if (rest === '/api/runs' && method === 'POST') {
      const body = await readJson(req);
      const dir = await resolveWithin(root, body.dir || root);
      return sendJson(res, 202, { ...orchestrator.start({ ...body, dir }), serverTime: Date.now() });
    }

    const runRoute = /^\/api\/runs\/([^/]+)(?:\/(cancel|send))?$/.exec(rest);
    if (runRoute) {
      const [, id, action] = runRoute;
      if (!action && method === 'GET') {
        const run = await orchestrator.get(id);
        const serverTime = Date.now();
        if (url.searchParams.get('rev') === String(run.rev)) return sendJson(res, 200, { unchanged: true, rev: run.rev, serverTime });
        return sendJson(res, 200, { ...run, serverTime });
      }
      if (!action && method === 'DELETE') {
        await orchestrator.remove(id);
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'cancel' && method === 'POST') {
        orchestrator.cancel(id);
        return sendJson(res, 200, { ok: true });
      }
      if (action === 'send' && method === 'POST') {
        const body = await readJson(req);
        const run = await orchestrator.get(id);
        const text = run.result || run.steps.filter((step) => step.status === 'done').at(-1)?.output;
        if (!text) throw new HubError(409, 'Esta execução ainda não tem resultado');
        await sessions.send(String(body.name ?? ''), text, { enter: body.enter === true });
        return sendJson(res, 200, { ok: true });
      }
    }

    throw new HubError(404, 'Não encontrado');
  }

  function proxyHttp(req, res) {
    const upstream = http.request(
      { host: '127.0.0.1', port: ttydPort, method: req.method, path: req.url, headers: req.headers },
      (answer) => {
        res.writeHead(answer.statusCode ?? 502, { ...answer.headers, 'referrer-policy': 'no-referrer' });
        answer.pipe(res);
      },
    );
    upstream.on('error', () => {
      if (!res.headersSent) sendPlain(res, 502, 'Terminal indisponível');
      else res.end();
    });
    req.pipe(upstream);
  }

  const server = http.createServer(async (req, res) => {
    try {
      if (!HOST_PATTERN.test(String(req.headers.host ?? ''))) return sendPlain(res, 403, 'Host não permitido');
      const url = parseUrl(req.url);
      if (!url) return sendPlain(res, 404, 'Não encontrado');
      const segments = url.pathname.split('/');
      if (segments[0] !== '' || !tokenMatches(token, segments[1])) return sendPlain(res, 404, 'Não encontrado');
      if (segments.length === 2) {
        res.writeHead(302, { Location: `/${segments[1]}/${url.search}`, 'Cache-Control': 'no-store' });
        return res.end();
      }
      const rest = `/${segments.slice(2).join('/')}`;
      if (rest.startsWith('/t/')) {
        if (req.method !== 'GET' && req.method !== 'HEAD') return sendPlain(res, 405, 'Método não permitido');
        return proxyHttp(req, res);
      }
      await route(req, res, url, rest);
    } catch (error) {
      if (error instanceof HubError) {
        // o corpo pode ter ficado pela metade: o cliente nao deve reaproveitar esta conexao
        if (error.status === 413) res.setHeader('Connection', 'close');
        return sendJson(res, error.status, { error: error.message });
      }
      process.stderr.write(`erro interno: ${error?.stack ?? error}\n`);
      return sendJson(res, 500, { error: 'Erro interno do painel' });
    }
  });

  server.on('upgrade', (req, socket, head) => {
    // o Node tira o listener de erro do socket antes do 'upgrade': sem este, um RST derruba o processo
    socket.on('error', () => {});
    const refuse = (status, text) => {
      socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    };
    const url = parseUrl(req.url);
    if (!url) return refuse(400, 'Bad Request');
    const segments = url.pathname.split('/');
    if (!HOST_PATTERN.test(String(req.headers.host ?? ''))) return refuse(403, 'Forbidden');
    if (segments[0] !== '' || !tokenMatches(token, segments[1])) return refuse(404, 'Not Found');
    if (segments.slice(2).join('/') !== 't/ws') return refuse(404, 'Not Found');
    if (!originAllowed(req, { required: true })) return refuse(403, 'Forbidden');
    const args = url.searchParams.getAll('arg');
    if (args.length !== 1 || !SESSION_NAME.test(args[0])) return refuse(400, 'Bad Request');

    const upstream = net.connect({ host: '127.0.0.1', port: ttydPort });
    sockets.add(socket);
    sockets.add(upstream);
    const cleanup = () => {
      sockets.delete(socket);
      sockets.delete(upstream);
      socket.destroy();
      upstream.destroy();
    };
    upstream.once('connect', () => {
      const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
      for (let index = 0; index < req.rawHeaders.length; index += 2) {
        lines.push(`${req.rawHeaders[index]}: ${req.rawHeaders[index + 1]}`);
      }
      upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
      if (head?.length) upstream.write(head);
      socket.setNoDelay(true);
      upstream.setNoDelay(true);
      socket.pipe(upstream);
      upstream.pipe(socket);
    });
    upstream.on('error', cleanup);
    socket.on('error', cleanup);
    upstream.on('close', cleanup);
    socket.on('close', cleanup);
  });

  return {
    server,
    sessions,
    orchestrator,
    async close() {
      for (const socket of sockets) socket.destroy();
      await orchestrator.shutdown();
      await new Promise((resolve) => {
        server.close(resolve);
        server.closeIdleConnections?.();
        setTimeout(() => server.closeAllConnections?.(), 500).unref();
      });
    },
  };
}

async function main() {
  const env = process.env;
  const state = env.TERMUX_AI_HUB_STATE || path.join(os.homedir(), '.local', 'share', 'termux-ai');
  const tokenFile = env.TERMUX_AI_HUB_TOKEN_FILE || path.join(state, 'web', 'token');
  const token = (env.TERMUX_AI_HUB_TOKEN || (await readFile(tokenFile, 'utf8'))).trim();
  const host = env.TERMUX_AI_HUB_HOST || '127.0.0.1';
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    throw new Error('O painel so pode escutar em loopback (127.0.0.1)');
  }
  const port = clampInt(env.TERMUX_AI_HUB_PORT, 1024, 65535, 7690);
  const root = await resolveWithin(env.TERMUX_AI_HUB_ROOT || process.cwd(), '.');
  const sessions = new Sessions({
    tmux: env.TERMUX_AI_HUB_TMUX || 'tmux',
    socket: env.TERMUX_AI_HUB_SOCKET || 'termux-ai',
    config: path.join(HERE, 'tmux.conf'),
    maxSessions: clampInt(env.TERMUX_AI_HUB_MAX_SESSIONS, 1, 12, 6),
    minFreeMb: clampInt(env.TERMUX_AI_HUB_MIN_FREE_MB, 0, 4096, 512),
  });
  const orchestrator = new Orchestrator({
    dir: path.join(state, 'runs'),
    maxParallel: clampInt(env.TERMUX_AI_HUB_MAX_PARALLEL, 1, 8, 4),
  });
  await orchestrator.init();
  const hub = createHub({
    token,
    root,
    sessions,
    orchestrator,
    ttydPort: clampInt(env.TERMUX_AI_HUB_TTYD_PORT, 1024, 65535, 7681),
    html: await readFile(path.join(HERE, 'index.html'), 'utf8'),
    version: env.TERMUX_AI_VERSION || 'dev',
  });
  await new Promise((resolve, reject) => {
    hub.server.once('error', reject);
    hub.server.listen(port, host, resolve);
  });
  process.stderr.write(`painel ativo em ${host}:${port} (raiz: ${root})\n`);

  let closing = false;
  const stop = () => {
    if (closing) return;
    closing = true;
    setTimeout(() => process.exit(0), 3000).unref();
    hub.close().finally(() => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`painel: ${error.message}\n`);
    process.exit(1);
  });
}
