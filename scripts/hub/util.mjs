// Utilitarios compartilhados do painel (sem dependencias externas).
import { randomBytes } from 'node:crypto';
import { realpath, rename, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';

export class HubError extends Error {
  constructor(status, message) {
    super(message);
    this.name = 'HubError';
    this.status = status;
  }
}

const ANSI = /\u001b\[[0-?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)|\u001b[@-Z\\-_]/g;
// Controles C0 (exceto tab e quebra de linha), DEL e controles C1.
const CONTROLS = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g;

export function stripControls(text) {
  return String(text).replace(CONTROLS, '');
}

// Remove sequencias ANSI e simula o efeito de "\r" (barras de progresso).
export function stripAnsi(text) {
  let value = String(text);
  // uma sequencia aninhada (ESC [ 2 0 ESC M 1 ~) so se forma depois da primeira passada
  for (let pass = 0; pass < 8; pass += 1) {
    const next = value.replace(ANSI, '');
    if (next === value) break;
    value = next;
  }
  return stripControls(
    value
      .replace(/\r\n/g, '\n')
      .split('\n')
      .map((line) => (line.includes('\r') ? line.slice(line.lastIndexOf('\r') + 1) : line))
      .join('\n'),
  );
}

export function truncateBytes(text, maxBytes, marker = '\n[... truncado ...]') {
  const value = String(text);
  if (Buffer.byteLength(value) <= maxBytes) return value;
  const room = Math.max(0, maxBytes - Buffer.byteLength(marker));
  let cut = Buffer.from(value).subarray(0, room).toString('utf8');
  if (cut.endsWith('\uFFFD')) cut = cut.slice(0, -1);
  return cut + marker;
}

export function clampInt(value, min, max, fallback) {
  const number = Number.parseInt(value, 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

export function randomId(now = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `${stamp}-${randomBytes(3).toString('hex')}`;
}

export async function writeJsonAtomic(file, data) {
  const temp = `${file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  try {
    await writeFile(temp, JSON.stringify(data), { mode: 0o600 });
    await rename(temp, file);
  } catch (error) {
    await unlink(temp).catch(() => {});
    throw error;
  }
}

// Resolve "candidate" (relativo a root ou absoluto) e garante que fica dentro de root.
export async function resolveWithin(root, candidate) {
  const base = await realpath(root);
  let target;
  try {
    target = await realpath(path.resolve(base, candidate || '.'));
  } catch {
    throw new HubError(400, 'Pasta não encontrada');
  }
  const rel = path.relative(base, target);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) {
    throw new HubError(400, 'Pasta fora da raiz permitida');
  }
  const info = await stat(target);
  if (!info.isDirectory()) throw new HubError(400, 'O caminho não é uma pasta');
  return target;
}

export class Semaphore {
  constructor(limit) {
    this.limit = Math.max(1, limit);
    this.active = 0;
    this.waiters = [];
  }

  // Com "signal", quem espera na fila desiste ao cancelar, sem ocupar uma vaga.
  acquire(signal) {
    if (signal?.aborted) return Promise.reject(signal.reason ?? new Error('cancelado'));
    if (this.active < this.limit) {
      this.active += 1;
      return Promise.resolve();
    }
    return new Promise((resolve, reject) => {
      const waiter = () => {
        signal?.removeEventListener('abort', onAbort);
        resolve();
      };
      const onAbort = () => {
        const position = this.waiters.indexOf(waiter);
        if (position !== -1) this.waiters.splice(position, 1);
        reject(signal.reason ?? new Error('cancelado'));
      };
      this.waiters.push(waiter);
      signal?.addEventListener('abort', onAbort, { once: true });
    });
  }

  release() {
    const next = this.waiters.shift();
    if (next) next();
    else this.active -= 1;
  }

  async run(task) {
    await this.acquire();
    try {
      return await task();
    } finally {
      this.release();
    }
  }
}

export function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
