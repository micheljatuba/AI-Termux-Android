import { createHash, randomBytes } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

export const hasCommand = (name, args = ['-V']) => spawnSync(name, args, { stdio: 'ignore' }).status === 0;

export async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

// REPL interativo de mentira: registra cada linha recebida em $STUB_DIR/<nome>.log.
const STUB_SCRIPT = `#!/bin/sh
name=$(basename "$0")
printf 'PRONTO-%s dir=%s\\n' "$name" "$(pwd)"
while IFS= read -r line; do
  printf '%s\\n' "$line" >> "$STUB_DIR/$name.log"
  case "$line" in
    /sair) exit 3 ;;
  esac
  printf 'eco: %s\\n' "$line"
done
`;

export async function createStubHome(names = ['claude', 'codex']) {
  const base = await realpath(await mkdtemp(path.join(os.tmpdir(), 'hub-home-')));
  const home = path.join(base, 'home');
  const bin = path.join(home, '.local', 'bin');
  const logs = path.join(base, 'logs');
  const work = path.join(base, 'work');
  await Promise.all([mkdir(bin, { recursive: true }), mkdir(logs), mkdir(work)]);
  for (const name of names) {
    await writeFile(path.join(bin, name), STUB_SCRIPT);
    await chmod(path.join(bin, name), 0o755);
  }
  return {
    base,
    home,
    bin,
    logs,
    work,
    // LANG vazio reproduz o guest do PRoot, onde o tmux so entende UTF-8 com a opcao -u.
    env: { ...process.env, HOME: home, STUB_DIR: logs, LANG: '', LC_ALL: '', LC_CTYPE: '' },
    searchPath: `${bin}${path.delimiter}${process.env.PATH ?? ''}`,
    readLog: (name) => readFile(path.join(logs, `${name}.log`), 'utf8').catch(() => ''),
    cleanup: () => rm(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }),
  };
}

export function request({ port, method = 'GET', path = '/', headers = {}, body, raw = false }) {
  return new Promise((resolve, reject) => {
    const finalHeaders = { Host: `127.0.0.1:${port}`, ...headers };
    let payload = null;
    if (body !== undefined) {
      payload = raw ? Buffer.from(body) : Buffer.from(JSON.stringify(body));
      if (!raw) finalHeaders['Content-Type'] ??= 'application/json';
      finalHeaders['Content-Length'] = payload.length;
    }
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: finalHeaders }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        if (String(res.headers['content-type'] ?? '').includes('json')) {
          try {
            json = JSON.parse(text);
          } catch {
            json = null;
          }
        }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on('error', reject);
    req.end(payload);
  });
}

export function encodeFrame(payload, { opcode = 1, mask = true } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload));
  const maskBit = mask ? 0x80 : 0;
  let header;
  if (data.length < 126) {
    header = Buffer.from([0x80 | opcode, maskBit | data.length]);
  } else if (data.length < 65536) {
    header = Buffer.from([0x80 | opcode, maskBit | 126, data.length >> 8, data.length & 255]);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = maskBit | 127;
    header.writeBigUInt64BE(BigInt(data.length), 2);
  }
  if (!mask) return Buffer.concat([header, data]);
  const key = randomBytes(4);
  const body = Buffer.from(data);
  for (let index = 0; index < body.length; index += 1) body[index] ^= key[index % 4];
  return Buffer.concat([header, key, body]);
}

export function parseFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const first = buffer[offset];
    const second = buffer[offset + 1];
    let length = second & 0x7f;
    let head = 2;
    if (length === 126) {
      if (buffer.length - offset < 4) break;
      length = buffer.readUInt16BE(offset + 2);
      head = 4;
    } else if (length === 127) {
      if (buffer.length - offset < 10) break;
      length = Number(buffer.readBigUInt64BE(offset + 2));
      head = 10;
    }
    const masked = (second & 0x80) !== 0;
    const total = head + (masked ? 4 : 0) + length;
    if (buffer.length - offset < total) break;
    const key = masked ? buffer.subarray(offset + head, offset + head + 4) : null;
    const payload = Buffer.from(buffer.subarray(offset + head + (masked ? 4 : 0), offset + total));
    if (key) for (let index = 0; index < payload.length; index += 1) payload[index] ^= key[index % 4];
    frames.push({ opcode: first & 0x0f, payload });
    offset += total;
  }
  return { frames, rest: buffer.subarray(offset) };
}

export const acceptKey = (key) => createHash('sha1').update(key + WS_GUID).digest('base64');

// Cliente WebSocket minimo (o global do Node nao deixa escolher o Origin).
export function connectWs({ port, path, origin, host = `127.0.0.1:${port}`, protocol = 'tty', headers = {}, allowHangup = false }) {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString('base64');
    const req = http.request({
      host: '127.0.0.1',
      port,
      path,
      headers: {
        Host: host,
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': key,
        'Sec-WebSocket-Protocol': protocol,
        ...(origin ? { Origin: origin } : {}),
        ...headers,
      },
    });
    req.on('response', (res) => {
      res.resume();
      res.on('end', () => resolve({ refused: true, status: res.statusCode }));
    });
    req.on('upgrade', (res, socket, head) => {
      const messages = [];
      let pending = Buffer.from(head);
      const waiters = new Set();
      const feed = (chunk) => {
        pending = Buffer.concat([pending, chunk]);
        const parsed = parseFrames(pending);
        pending = Buffer.from(parsed.rest);
        for (const frame of parsed.frames) messages.push(frame);
        for (const check of [...waiters]) check();
      };
      if (pending.length) feed(Buffer.alloc(0));
      socket.on('data', feed);
      socket.on('error', () => {});
      const client = {
        refused: false,
        status: res.statusCode,
        accept: res.headers['sec-websocket-accept'],
        expectedAccept: acceptKey(key),
        socket,
        messages,
        closed: false,
        send: (text) => socket.write(encodeFrame(text, { opcode: 1 })),
        sendBinary: (data) => socket.write(encodeFrame(data, { opcode: 2 })),
        output: () => Buffer.concat(messages.map((frame) => frame.payload)).toString('utf8'),
        waitFor(predicate, timeoutMs = 8000) {
          return new Promise((resolveWait, rejectWait) => {
            const check = () => {
              if (predicate(client)) {
                waiters.delete(check);
                clearTimeout(timer);
                resolveWait(client);
              }
            };
            const timer = setTimeout(() => {
              waiters.delete(check);
              rejectWait(new Error(`WebSocket: tempo esgotado. Recebido até agora:\n${client.output().slice(-600)}`));
            }, timeoutMs);
            waiters.add(check);
            check();
          });
        },
        close() {
          socket.destroy();
        },
      };
      socket.on('close', () => {
        client.closed = true;
        for (const check of [...waiters]) check();
      });
      resolve(client);
    });
    req.on('error', (error) => {
      // O ttyd (libwebsockets) recusa o upgrade fechando a conexao, sem resposta HTTP.
      if (allowHangup && error.code === 'ECONNRESET') resolve({ refused: true, status: 0 });
      else reject(error);
    });
    req.end();
  });
}

// ttyd de mentira: responde HTTP simples e aceita upgrade de WebSocket com eco.
export async function startFakeTtyd() {
  const requests = [];
  const upgrades = [];
  const server = http.createServer((req, res) => {
    requests.push({ method: req.method, url: req.url, headers: req.headers });
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'X-Fake-Ttyd': '1' });
    res.end('<title>ttyd falso</title>');
  });
  const sockets = new Set();
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  server.on('upgrade', (req, socket) => {
    upgrades.push({ url: req.url, headers: req.headers });
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${acceptKey(req.headers['sec-websocket-key'])}\r\nSec-WebSocket-Protocol: tty\r\n\r\n`,
    );
    socket.write(encodeFrame('0pronto', { opcode: 2, mask: false }));
    let pending = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      pending = Buffer.concat([pending, chunk]);
      const parsed = parseFrames(pending);
      pending = Buffer.from(parsed.rest);
      for (const frame of parsed.frames) socket.write(encodeFrame(Buffer.concat([Buffer.from('0eco:'), frame.payload]), { opcode: 2, mask: false }));
    });
    socket.on('error', () => {});
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    port: server.address().port,
    requests,
    upgrades,
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(resolve);
      }),
  };
}

export async function waitUntil(check, { timeoutMs = 8000, intervalMs = 30, message = 'condição não atendida' } = {}) {
  const limit = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > limit) throw new Error(`Tempo esgotado: ${message}`);
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
