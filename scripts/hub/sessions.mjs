// Sessoes interativas dos agentes, mantidas em um servidor tmux dedicado.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { findExecutable, getAgent, sessionArgv } from './agents.mjs';
import { HubError, delay, stripControls } from './util.mjs';

export const SESSION_NAME = /^ia-[a-z0-9]+-[0-9]{1,3}$/;

const SEP = '\t';
const LIST_FORMAT = [
  '#{session_name}',
  '#{pane_dead}',
  '#{pane_dead_status}',
  '#{pane_dead_signal}',
  '#{window_activity}',
  '#{session_created}',
  '#{@ia_agent}',
  '#{@ia_dir}',
  '#{session_id}',
  '#{pid}',
].join(SEP);

// Teclas aceitas pelo painel (nome publico -> nome no tmux).
export const KEYS = Object.freeze({
  'C-c': 'C-c',
  Escape: 'Escape',
  Enter: 'Enter',
  Up: 'Up',
  Down: 'Down',
  Left: 'Left',
  Right: 'Right',
  Tab: 'Tab',
  'S-Tab': 'BTab',
  y: 'y',
  n: 'n',
  1: '1',
  2: '2',
  3: '3',
});

export async function readMemInfo(file = '/proc/meminfo') {
  try {
    const text = await readFile(file, 'utf8');
    const kb = (key) => Number(new RegExp(`^${key}:\\s+(\\d+)`, 'm').exec(text)?.[1] ?? 0);
    return { totalMb: Math.round(kb('MemTotal') / 1024), availableMb: Math.round(kb('MemAvailable') / 1024) };
  } catch {
    return { totalMb: 0, availableMb: 0 };
  }
}

// O tmux >= 3.4 recusa clientes de outra instancia do PRoot ("access not allowed") e ainda assim sai com codigo 0,
// com a mensagem so em stderr: sem este teste a lista viria vazia e criar sessoes pareceria dar certo.
const ACCESS_DENIED = /access not allowed/i;
export const TMUX_BLOCKED_MESSAGE = 'O tmux dos agentes está em outra instância do PRoot e recusou o acesso. No Termux, rode "ia web stop" e depois "ia web".';

function runTmux(bin, args, { input = null, timeoutMs = 8000, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { env, stdio: [input == null ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error.code === 'ENOENT' ? new HubError(503, 'tmux não encontrado; rode "ia atualizar" ou instale o tmux') : error);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (ACCESS_DENIED.test(stderr)) reject(new HubError(503, TMUX_BLOCKED_MESSAGE));
      else if (code === 0) resolve(stdout);
      else reject(new HubError(500, stderr.trim() || `tmux saiu com código ${code}`));
    });
    if (input != null) {
      child.stdin.on('error', () => {});
      child.stdin.end(input);
    }
  });
}

const NO_SERVER = /no server running|no sessions|error connecting|failed to connect/i;

export class Sessions {
  constructor({
    tmux = 'tmux',
    socket = 'termux-ai',
    config = null,
    maxSessions = 6,
    minFreeMb = 512,
    memInfo = readMemInfo,
    searchPath = process.env.PATH ?? '',
    previewTtlMs = 1500,
    reapIntervalMs = 500,
    env = process.env,
  } = {}) {
    this.tmux = tmux;
    this.socket = socket;
    this.config = config;
    this.maxSessions = maxSessions;
    this.minFreeMb = minFreeMb;
    this.memInfo = memInfo;
    this.searchPath = searchPath;
    this.previewTtlMs = previewTtlMs;
    this.reapIntervalMs = reapIntervalMs;
    this.env = env;
    this.queue = Promise.resolve();
    this.previews = new Map();
    this.buffers = 0;
    this.lastReap = 0;
  }

  #run(args, options = {}) {
    const base = ['-L', this.socket, '-u'];
    if (this.config) base.push('-f', this.config);
    return runTmux(this.tmux, [...base, ...args], { env: this.env, ...options });
  }

  #target(name) {
    if (!SESSION_NAME.test(String(name))) throw new HubError(400, 'Nome de sessão inválido');
    return `=${name}:`;
  }

  async list() {
    let output;
    try {
      output = await this.#run(['list-sessions', '-F', LIST_FORMAT]);
    } catch (error) {
      if (error instanceof HubError && NO_SERVER.test(error.message)) return [];
      throw error;
    }
    const sessions = [];
    let serverPid = 0;
    let unreaped = false;
    for (const line of output.split('\n')) {
      const [name, dead, deadStatus, deadSignal, activity, created, agent, dir, id, pid] = line.split(SEP);
      if (!name || !SESSION_NAME.test(name)) continue;
      const exitStatus = deadStatus === '' || deadStatus === undefined ? null : Number(deadStatus);
      serverPid = Number(pid) || serverPid;
      if (dead === '1' && exitStatus === null && !deadSignal) unreaped = true;
      sessions.push({
        name,
        agent: agent || name.split('-')[1],
        dir: dir ?? '',
        dead: dead === '1',
        exitStatus,
        activity: Number(activity) || 0,
        created: Number(created) || 0,
        order: Number(String(id ?? '').replace('$', '')) || 0,
      });
    }
    if (unreaped) this.#reapChildren(serverPid);
    return sessions.sort((a, b) => a.order - b.order || a.created - b.created || a.name.localeCompare(b.name));
  }

  // Sob carga o tmux as vezes perde o SIGCHLD de um painel: o processo do agente vira zumbi e o codigo de saida nunca
  // e informado. Um SIGCHLD extra faz o servidor recolher os filhos que ja terminaram (sem efeito se nao houver nenhum).
  #reapChildren(pid) {
    const now = Date.now();
    if (!Number.isInteger(pid) || pid <= 1 || now - this.lastReap < this.reapIntervalMs) return;
    this.lastReap = now;
    try {
      process.kill(pid, 'SIGCHLD');
    } catch {
      // o servidor ja encerrou
    }
  }

  async get(name) {
    this.#target(name);
    const found = (await this.list()).find((session) => session.name === name);
    if (!found) throw new HubError(404, 'Sessão não encontrada');
    return found;
  }

  async create({ agent, dir }) {
    const definition = getAgent(agent);
    if (!definition) throw new HubError(400, `Agente desconhecido: ${agent}`);
    if (definition.id !== 'shell' && !findExecutable(definition.bin, this.searchPath)) {
      throw new HubError(400, `${definition.label} não está instalado`);
    }
    const argv = sessionArgv(definition.id);
    const run = this.queue.then(async () => {
      const current = await this.list();
      if (current.length >= this.maxSessions) {
        throw new HubError(409, `Limite de ${this.maxSessions} sessões simultâneas; encerre alguma antes`);
      }
      const { availableMb, totalMb } = await this.memInfo();
      if (totalMb > 0 && availableMb < this.minFreeMb) {
        throw new HubError(503, `Pouca memória livre (${availableMb} MB); feche sessões ou apps antes de abrir outra`);
      }
      const used = new Set(current.map((session) => session.name));
      for (let number = 1; number < 100; number += 1) {
        const name = `ia-${definition.id}-${number}`;
        if (used.has(name)) continue;
        try {
          await this.#run(['new-session', '-d', '-s', name, '-c', dir, '-x', '160', '-y', '45', '--', ...argv]);
        } catch (error) {
          if (/duplicate session/i.test(error.message)) continue;
          throw error;
        }
        await this.#run(['set-option', '-t', `=${name}:`, '@ia_agent', definition.id]);
        await this.#run(['set-option', '-t', `=${name}:`, '@ia_dir', dir]);
        return this.get(name);
      }
      throw new HubError(409, 'Não há números livres para novas sessões');
    });
    this.queue = run.catch(() => {});
    return run;
  }

  async kill(name) {
    const target = this.#target(name);
    try {
      await this.#run(['kill-session', '-t', target]);
    } catch (error) {
      if (/can't find/i.test(error.message) || NO_SERVER.test(error.message)) throw new HubError(404, 'Sessão não encontrada');
      throw error;
    }
    this.previews.delete(name);
  }

  async killAll() {
    const sessions = await this.list();
    for (const session of sessions) await this.kill(session.name).catch(() => {});
    return sessions.length;
  }

  async restart(name) {
    const target = this.#target(name);
    await this.get(name);
    await this.#run(['respawn-pane', '-k', '-t', target]);
    this.previews.delete(name);
  }

  async send(name, text, { enter = true } = {}) {
    const target = this.#target(name);
    const body = stripControls(String(text ?? '').replace(/\r\n?/g, '\n'));
    if (Buffer.byteLength(body) > 64 * 1024) throw new HubError(413, 'Texto grande demais (máximo 64 KB)');
    if (!body && !enter) throw new HubError(400, 'Nada para enviar');
    await this.get(name);
    if (body) {
      // paste-buffer evita problemas de escape no argv do tmux (ex.: texto terminado em ";"); sem ESC,
      // o texto colado nao consegue encerrar o "bracketed paste" e virar teclas digitadas
      this.buffers += 1;
      const buffer = `ia-hub-${process.pid}-${this.buffers}`;
      await this.#run(['load-buffer', '-b', buffer, '-'], { input: body });
      await this.#run(['paste-buffer', '-p', '-d', '-b', buffer, '-t', target]);
    }
    if (enter) {
      await delay(body.includes('\n') || body.length > 200 ? 200 : 80);
      await this.#run(['send-keys', '-t', target, 'Enter']);
    }
  }

  async key(name, key) {
    const target = this.#target(name);
    const mapped = Object.hasOwn(KEYS, key) ? KEYS[key] : null;
    if (!mapped) throw new HubError(400, `Tecla não permitida: ${key}`);
    await this.get(name);
    await this.#run(['send-keys', '-t', target, mapped]);
  }

  async peek(name, lines = 14) {
    const target = this.#target(name);
    const cached = this.previews.get(name);
    if (cached && Date.now() - cached.at < this.previewTtlMs) return cached.lines.slice(-lines);
    let output;
    try {
      output = await this.#run(['capture-pane', '-p', '-J', '-t', target]);
    } catch (error) {
      if (/can't find/i.test(error.message) || NO_SERVER.test(error.message)) throw new HubError(404, 'Sessão não encontrada');
      throw error;
    }
    const all = output
      .split('\n')
      .map((line) => line.replace(/\s+$/, ''))
      .filter(Boolean);
    this.previews.set(name, { at: Date.now(), lines: all.slice(-40) });
    return all.slice(-lines);
  }

  async peekAll(lines = 14) {
    const sessions = await this.list();
    const result = {};
    await Promise.all(
      sessions.map(async (session) => {
        result[session.name] = await this.peek(session.name, lines).catch(() => []);
      }),
    );
    return result;
  }
}
