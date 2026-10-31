// Motor de orquestracao: executa agentes em modo somente leitura (comparar,
// pipeline e maestro) e guarda o historico em disco.
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { mkdir, readFile, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { READONLY_PREAMBLE, describeAgents, getAgent, headlessCommand } from './agents.mjs';
import { sanitizePolicy } from './models.mjs';
import { HubError, Semaphore, clampInt, randomId, stripAnsi, truncateBytes, writeJsonAtomic } from './util.mjs';

export const MODES = Object.freeze(['compare', 'pipeline', 'maestro']);
export const ROLES = Object.freeze(['plan', 'implement', 'review', 'custom']);

const LIMITS = Object.freeze({
  task: 32 * 1024,
  stepOutput: 256 * 1024,
  included: 20 * 1024,
  prompt: 96 * 1024,
  subtaskPrompt: 4000,
  subtaskTitle: 80,
  keepRuns: 50,
});

const RUN_ID = /^\d{8}-\d{6}-[0-9a-f]{6}$/;

const ROLE_TITLES = { plan: 'Planejar', implement: 'Propor implementação', review: 'Revisar', custom: 'Etapa' };
const ROLE_PROMPTS = {
  plan: 'Planeje a solução: analise o contexto, liste os arquivos relevantes e proponha um plano objetivo em passos numerados. Não escreva a implementação completa.',
  implement:
    'Com base no plano da etapa anterior, proponha a implementação: mostre o código ou o diff necessário como texto (sem aplicar nada) e explique as decisões importantes.',
  review:
    'Revise criticamente a proposta da etapa anterior: procure bugs, casos de borda, riscos de segurança e inconsistências com a tarefa. Liste os problemas por gravidade e entregue a versão final corrigida.',
};

const withPreamble = (text) => `${READONLY_PREAMBLE}\n\n${text}`;
const included = (text, limit = LIMITS.included) => truncateBytes(text, limit);

// Divide o espaco do prompt entre as respostas incluidas: um unico argumento do Linux nao passa de 128 KB.
const shareOf = (task, count) =>
  Math.max(2048, Math.min(LIMITS.included, Math.floor((LIMITS.prompt - Buffer.byteLength(task) - 4096) / Math.max(1, count))));

const labelOf = (id) => getAgent(id)?.label ?? id;

function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

// Grupos de processos dos agentes em execucao: se o processo principal sair de forma abrupta
// (erro nao tratado, process.exit com agentes ainda rodando), eles nao ficam soltos no aparelho.
const liveGroups = new Set();
let exitHookInstalled = false;

function trackGroup(pid) {
  if (!pid) return;
  liveGroups.add(pid);
  if (exitHookInstalled) return;
  exitHookInstalled = true;
  process.on('exit', () => {
    for (const group of liveGroups) {
      try {
        process.kill(-group, 'SIGKILL');
      } catch {
        // o grupo ja terminou
      }
    }
  });
}

// Resume por que um comando headless falhou (ultimas linhas uteis).
export function describeFailure(stdout, stderr, code) {
  const lines = (text) =>
    stripAnsi(text)
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean);
  const errLines = lines(stderr);
  const explicit = [...errLines].reverse().find((line) => /^(error|erro|fatal)\b/i.test(line));
  const picked = explicit ? [explicit] : (errLines.length ? errLines : lines(stdout)).slice(-3);
  const text = picked.join(' · ').slice(0, 500);
  return text ? `Saiu com código ${code}: ${text}` : `Saiu com código ${code} sem mensagem`;
}

// Executa um agente uma unica vez (headless, somente leitura).
export function runHeadless({ agent, prompt, dir, model = null, timeoutMs, signal, onOutput, env = process.env, spawnFn = spawn }) {
  const spec = headlessCommand(agent, { prompt, dir, model });
  const started = Date.now();
  const failure = (error, extra = {}) => ({
    ok: false,
    output: '',
    error,
    code: null,
    timedOut: false,
    cancelled: false,
    durationMs: Date.now() - started,
    ...extra,
  });
  if (!spec) return Promise.resolve(failure(`${labelOf(agent)} não suporta execução automática`));

  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let cancelled = false;
    let settled = false;
    let child;
    let killTimer;
    let timeout;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      clearTimeout(killTimer);
      liveGroups.delete(child?.pid);
      signal?.removeEventListener('abort', onAbort);
      resolve(result);
    };

    const kill = (name) => {
      if (!child?.pid) return;
      try {
        process.kill(-child.pid, name);
      } catch {
        try {
          child.kill(name);
        } catch {
          // o processo ja terminou
        }
      }
    };

    const stop = () => {
      kill('SIGTERM');
      killTimer = setTimeout(() => kill('SIGKILL'), 4000);
      killTimer.unref?.();
    };

    function onAbort() {
      cancelled = true;
      stop();
    }

    try {
      child = spawnFn(spec.command, spec.args, {
        cwd: dir,
        env: { ...env, NO_COLOR: '1', FORCE_COLOR: '0', TERM: 'dumb' },
        detached: true,
        stdio: [spec.stdin == null ? 'ignore' : 'pipe', 'pipe', 'pipe'],
      });
    } catch (error) {
      finish(failure(`Não foi possível iniciar ${spec.command}: ${error.message}`));
      return;
    }
    trackGroup(child.pid);

    if (signal?.aborted) {
      onAbort();
    } else {
      signal?.addEventListener('abort', onAbort, { once: true });
    }
    timeout = setTimeout(() => {
      timedOut = true;
      stop();
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (stdout.length < LIMITS.stepOutput * 2) stdout += chunk;
      onOutput?.(stdout);
    });
    child.stderr.on('data', (chunk) => {
      if (stderr.length < 64 * 1024) stderr += chunk;
    });
    if (spec.stdin != null) {
      child.stdin.on('error', () => {});
      child.stdin.end(spec.stdin);
    }

    child.on('error', (error) => {
      const message = error.code === 'ENOENT' ? `${spec.command} não encontrado no PATH` : error.message;
      finish(failure(message));
    });
    child.on('close', (code, exitSignal) => {
      const output = truncateBytes(spec.clean(stripAnsi(stdout)).trim(), LIMITS.stepOutput);
      const durationMs = Date.now() - started;
      if (cancelled) return finish({ ok: false, output, error: 'Cancelado', code, timedOut, cancelled, durationMs });
      if (timedOut) {
        const error = `Tempo esgotado (${Math.round(timeoutMs / 1000)} s)`;
        return finish({ ok: false, output, error, code, timedOut, cancelled, durationMs });
      }
      if (code !== 0) {
        const error = exitSignal ? `Encerrado pelo sinal ${exitSignal}` : describeFailure(stdout, stderr, code);
        return finish({ ok: false, output, error, code, timedOut, cancelled, durationMs });
      }
      if (!output) {
        return finish({ ok: false, output, error: 'O agente terminou sem resposta', code, timedOut, cancelled, durationMs });
      }
      return finish({ ok: true, output, error: '', code, timedOut, cancelled, durationMs });
    });
  });
}

function extractJson(text) {
  const candidates = [];
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(text);
  if (fenced) candidates.push(fenced[1]);
  const first = text.indexOf('{');
  const last = text.lastIndexOf('}');
  if (first !== -1 && last > first) candidates.push(text.slice(first, last + 1));
  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      // tenta o proximo candidato
    }
  }
  return null;
}

// Valida o plano devolvido pelo coordenador do modo maestro.
export function parseMaestroPlan(text, allowed, maxTasks, models = {}) {
  const data = extractJson(text);
  const list = data?.tarefas ?? data?.tasks;
  if (!Array.isArray(list) || list.length === 0) return null;
  const tasks = [];
  for (const [index, item] of list.slice(0, maxTasks).entries()) {
    const prompt = typeof item?.prompt === 'string' ? item.prompt.trim() : '';
    if (!prompt) return null;
    const requested = String(item.agente ?? item.agent ?? '').toLowerCase();
    const agent = allowed.includes(requested) ? requested : allowed[index % allowed.length];
    const title = String(item.titulo ?? item.title ?? `Subtarefa ${index + 1}`).trim().slice(0, LIMITS.subtaskTitle);
    // So um modelo da lista permitida para o agente escolhido; fora dela vale o padrao da conta.
    const requestedModel = String(item.modelo ?? item.model ?? '').trim();
    const model = (models[agent] ?? []).includes(requestedModel) ? requestedModel : null;
    tasks.push({ agent, ...(model ? { model } : {}), title: title || `Subtarefa ${index + 1}`, prompt: prompt.slice(0, LIMITS.subtaskPrompt) });
  }
  return tasks;
}

function judgePrompt(task, answers) {
  const share = shareOf(task, answers.length);
  const blocks = answers.map((answer, index) => `### Resposta ${index + 1} — ${answer.label}\n${included(answer.output, share)}`);
  return withPreamble(
    [
      'Você é o juiz de uma comparação entre agentes de IA que receberam a mesma tarefa.',
      '',
      '## Tarefa original',
      task,
      '',
      '## Respostas recebidas',
      blocks.join('\n\n'),
      '',
      '## O que entregar',
      '1. Uma comparação curta, com pontos fortes e fracos de cada resposta.',
      '2. Qual resposta é a melhor e por quê.',
      '3. A resposta final, combinando o melhor de cada uma.',
    ].join('\n'),
  );
}

function stepPrompt(task, step, previous, results) {
  // uma unica passada: o texto inserido (tarefa, resultados) nunca e reinterpretado como marcador
  const fill = (template) =>
    template.replace(/\{\{(tarefa|anterior|passo(\d))\}\}/g, (_, key, number) => {
      if (key === 'tarefa') return task;
      if (key === 'anterior') return previous ? included(previous.output) : '';
      return included(results[Number(number) - 1]?.output ?? '');
    });
  const lines = ['## Tarefa', task];
  if (previous) lines.push('', `## Resultado da etapa anterior (${previous.title})`, included(previous.output));
  const instruction = step.role === 'custom' ? truncateBytes(fill(step.prompt || ''), LIMITS.included * 2) : ROLE_PROMPTS[step.role];
  lines.push('', `## Sua etapa: ${step.title}`, instruction);
  return withPreamble(lines.join('\n'));
}

function coordinatorPrompt(task, workers, maxTasks, models = {}) {
  const team = workers
    .map((id) => `- ${id}: ${labelOf(id)}${models[id]?.length ? ` (modelos permitidos: ${models[id].join(', ')})` : ''}`)
    .join('\n');
  const withModels = workers.some((id) => models[id]?.length);
  return withPreamble(
    [
      'Você é o maestro de uma equipe de agentes de IA (todos somente leitura).',
      `Divida a tarefa abaixo em no máximo ${maxTasks} subtarefas independentes, que possam ser executadas em paralelo.`,
      '',
      '## Agentes disponíveis',
      team,
      '',
      '## Regras',
      '- Use apenas os agentes listados e escolha o mais adequado para cada subtarefa.',
      ...(withModels
        ? ['- Quando o agente tiver modelos permitidos, escolha em "modelo" o mais adequado à subtarefa (o mais capaz só quando a subtarefa for difícil); sem lista, omita "modelo".']
        : []),
      '- Cada prompt deve ser completo e autocontido (o agente não vê as outras subtarefas).',
      '- Responda SOMENTE com JSON válido, sem texto fora do JSON, neste formato:',
      withModels
        ? '{"tarefas":[{"agente":"<id>","modelo":"<modelo permitido ou omitido>","titulo":"<título curto>","prompt":"<instrução completa>"}]}'
        : '{"tarefas":[{"agente":"<id>","titulo":"<título curto>","prompt":"<instrução completa>"}]}',
      '',
      '## Tarefa',
      task,
    ].join('\n'),
  );
}

function integrationPrompt(task, tasks) {
  const share = shareOf(task, tasks.length);
  const blocks = tasks.map((entry) =>
    entry.status === 'done'
      ? `### ${entry.title} — ${labelOf(entry.agent)}\n${included(entry.output, share)}`
      : `### ${entry.title} — ${labelOf(entry.agent)}\n(falhou: ${entry.error || 'sem resposta'})`,
  );
  return withPreamble(
    [
      'Você é o maestro. Integre os resultados dos agentes em uma única resposta final coerente para a tarefa original.',
      '',
      '## Tarefa original',
      task,
      '',
      '## Resultados dos agentes',
      blocks.join('\n\n'),
      '',
      '## O que entregar',
      'Uma resposta final integrada. Aponte divergências entre os agentes e lacunas que ainda restam.',
    ].join('\n'),
  );
}

// Valida e normaliza o pedido de uma execucao.
export function normalizeSpec(spec, installed) {
  const fail = (message) => {
    throw new HubError(400, message);
  };
  if (!spec || typeof spec !== 'object') fail('Pedido inválido');
  const mode = String(spec.mode ?? '');
  if (!MODES.includes(mode)) fail('Modo inválido: use comparar, pipeline ou maestro');
  const prompt = typeof spec.prompt === 'string' ? spec.prompt.trim() : '';
  if (!prompt) fail('Escreva a tarefa para os agentes');
  if (Buffer.byteLength(prompt) > LIMITS.task) fail('A tarefa é grande demais (máximo 32 KB)');

  const ready = new Set(installed);
  const pick = (id, label) => {
    const value = String(id ?? '').toLowerCase();
    if (!getAgent(value)?.bin || value === 'shell') fail(`${label}: agente desconhecido (${value || 'vazio'})`);
    if (!ready.has(value)) fail(`${label}: ${labelOf(value)} não está instalado`);
    return value;
  };
  const list = (value, label) => {
    const raw = Array.isArray(value) ? value : [];
    return [...new Set(raw.map((id) => pick(id, label)))];
  };

  const options = {
    mode,
    timeoutSec: clampInt(spec.timeoutSec, 30, 1800, 600),
    agents: [],
    judge: null,
    steps: [],
    coordinator: null,
    maxTasks: 4,
  };

  if (mode === 'compare') {
    options.agents = list(spec.agents, 'Agentes');
    if (options.agents.length < 2) fail('Escolha pelo menos 2 agentes para comparar');
    if (options.agents.length > 6) fail('Escolha no máximo 6 agentes');
    if (spec.judge) options.judge = pick(spec.judge, 'Juiz');
  } else if (mode === 'pipeline') {
    const raw = Array.isArray(spec.steps) ? spec.steps : [];
    if (raw.length < 2 || raw.length > 6) fail('O pipeline precisa de 2 a 6 etapas');
    const defaults = ['plan', 'implement', 'review'];
    options.steps = raw.map((item, index) => {
      const role = ROLES.includes(item?.role) ? item.role : defaults[Math.min(index, defaults.length - 1)];
      const custom = typeof item?.prompt === 'string' ? item.prompt.trim().slice(0, LIMITS.subtaskPrompt) : '';
      if (role === 'custom' && !custom) fail(`Etapa ${index + 1}: escreva a instrução da etapa personalizada`);
      return { agent: pick(item?.agent, `Etapa ${index + 1}`), role, prompt: custom };
    });
  } else {
    options.agents = list(spec.agents, 'Agentes');
    if (options.agents.length < 1) fail('Escolha pelo menos 1 agente para executar as subtarefas');
    options.coordinator = pick(spec.coordinator || options.agents[0], 'Coordenador');
    options.maxTasks = clampInt(spec.maxTasks, 1, 6, 4);
    const policy = sanitizePolicy(spec.models);
    options.models = Object.fromEntries(Object.entries(policy).filter(([agent]) => options.agents.includes(agent)));
  }
  return { prompt, options };
}

export class Orchestrator extends EventEmitter {
  constructor({
    dir,
    runAgent = runHeadless,
    installedAgents = () => describeAgents().filter((agent) => agent.installed && agent.orchestrable).map((agent) => agent.id),
    maxParallel = 4,
    persistDelayMs = 700,
  }) {
    super();
    this.dir = dir;
    this.runAgent = runAgent;
    this.installedAgents = installedAgents;
    this.semaphore = new Semaphore(maxParallel);
    this.persistDelayMs = persistDelayMs;
    this.active = new Map();
    this.controllers = new Map();
    this.completions = new Map();
    this.timers = new Map();
    this.index = new Map();
  }

  async #runNames() {
    const entries = await readdir(this.dir, { withFileTypes: true });
    return entries.filter((entry) => entry.isDirectory() && RUN_ID.test(entry.name)).map((entry) => entry.name);
  }

  // Apaga as execucoes mais antigas alem de keepRuns, sem tocar nas que ainda rodam (aqui ou em outro processo).
  async #prune() {
    let names;
    try {
      names = (await this.#runNames()).sort();
    } catch {
      return;
    }
    for (const name of names.slice(0, Math.max(0, names.length - LIMITS.keepRuns))) {
      if (this.active.has(name)) continue;
      const status = this.index.get(name)?.status ?? (await this.#read(name))?.status;
      if (status === 'running' || status === 'queued') continue;
      await rm(path.join(this.dir, name), { recursive: true, force: true }).catch(() => {});
      this.index.delete(name);
    }
  }

  async init() {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    await this.#prune();
    const names = (await this.#runNames()).sort();
    for (const name of names.slice(-LIMITS.keepRuns)) {
      const run = await this.#read(name);
      if (!run) continue;
      await this.#reconcile(run);
      this.index.set(run.id, this.#summary(run));
    }
  }

  // Descobre execucoes criadas por outros processos (ex.: "ia orquestrar") e atualiza as que ainda rodam.
  async refresh() {
    let names;
    try {
      names = await this.#runNames();
    } catch {
      return;
    }
    const present = new Set(names);
    for (const id of [...this.index.keys()]) {
      if (!present.has(id) && !this.active.has(id)) this.index.delete(id);
    }
    for (const name of names) {
      if (this.active.has(name)) continue;
      const known = this.index.get(name);
      if (known && known.status !== 'running' && known.status !== 'queued') continue;
      const run = await this.#read(name);
      if (!run) continue;
      await this.#reconcile(run);
      this.index.set(name, this.#summary(run));
    }
  }

  async #reconcile(run) {
    if (run.status !== 'queued' && run.status !== 'running') return;
    if (this.active.has(run.id)) return;
    if (run.pid && run.pid !== process.pid && processAlive(run.pid)) return;
    run.status = 'error';
    run.error = 'Interrompido: o processo que executava esta tarefa foi encerrado';
    run.finishedAt = Date.now();
    run.rev += 1;
    for (const step of run.steps) {
      if (['pending', 'queued', 'running'].includes(step.status)) step.status = 'cancelled';
    }
    await this.#persist(run).catch(() => {});
  }

  list() {
    return [...this.index.values()].sort((a, b) => (a.id < b.id ? 1 : -1));
  }

  async get(id) {
    if (!RUN_ID.test(id)) throw new HubError(404, 'Execução não encontrada');
    const run = this.active.get(id) ?? (await this.#read(id));
    if (!run) throw new HubError(404, 'Execução não encontrada');
    return run;
  }

  start(spec) {
    const { prompt, options } = normalizeSpec(spec, this.installedAgents());
    if (!spec.dir || typeof spec.dir !== 'string') throw new HubError(400, 'Pasta de trabalho ausente');
    const run = {
      id: randomId(),
      rev: 0,
      pid: process.pid,
      mode: options.mode,
      prompt,
      dir: spec.dir,
      options,
      status: 'running',
      createdAt: Date.now(),
      startedAt: Date.now(),
      finishedAt: null,
      steps: [],
      result: '',
      error: '',
    };
    const controller = new AbortController();
    this.active.set(run.id, run);
    this.controllers.set(run.id, controller);
    this.index.set(run.id, this.#summary(run));
    this.#changed(run);
    const completion = this.#execute(run, controller.signal).finally(() => {
      this.controllers.delete(run.id);
      this.completions.delete(run.id);
    });
    this.completions.set(run.id, completion);
    return run;
  }

  wait(id) {
    return this.completions.get(id) ?? Promise.resolve();
  }

  cancel(id) {
    const controller = this.controllers.get(id);
    if (!controller) throw new HubError(409, 'A execução já terminou');
    controller.abort();
  }

  async remove(id) {
    if (!RUN_ID.test(id)) throw new HubError(404, 'Execução não encontrada');
    if (this.active.has(id)) throw new HubError(409, 'Cancele a execução antes de apagar');
    await rm(path.join(this.dir, id), { recursive: true, force: true });
    this.index.delete(id);
  }

  async shutdown() {
    for (const controller of this.controllers.values()) controller.abort();
    await Promise.allSettled([...this.completions.values()]);
  }

  #summary(run) {
    return {
      id: run.id,
      mode: run.mode,
      prompt: run.prompt.slice(0, 160),
      status: run.status,
      createdAt: run.createdAt,
      finishedAt: run.finishedAt,
      agents: [...new Set(run.steps.map((step) => step.agent).filter(Boolean))],
    };
  }

  async #read(id) {
    try {
      return JSON.parse(await readFile(path.join(this.dir, id, 'run.json'), 'utf8'));
    } catch {
      return null;
    }
  }

  async #persist(run) {
    const folder = path.join(this.dir, run.id);
    await mkdir(folder, { recursive: true, mode: 0o700 });
    await writeJsonAtomic(path.join(folder, 'run.json'), run);
  }

  #changed(run, { immediate = false } = {}) {
    run.rev += 1;
    this.index.set(run.id, this.#summary(run));
    this.emit('update', run);
    if (immediate) {
      clearTimeout(this.timers.get(run.id));
      this.timers.delete(run.id);
      return this.#persist(run).catch(() => {});
    }
    if (!this.timers.has(run.id)) {
      const timer = setTimeout(() => {
        this.timers.delete(run.id);
        this.#persist(run).catch(() => {});
      }, this.persistDelayMs);
      timer.unref?.();
      this.timers.set(run.id, timer);
    }
    return Promise.resolve();
  }

  #addStep(run, kind, agent, title, extra = {}) {
    const step = {
      id: `s${run.steps.length + 1}`,
      kind,
      agent,
      title,
      status: 'pending',
      output: '',
      error: '',
      startedAt: null,
      finishedAt: null,
      durationMs: null,
      ...extra,
    };
    run.steps.push(step);
    return step;
  }

  async #runStep(run, signal, step, prompt) {
    if (signal.aborted) {
      step.status = 'cancelled';
      this.#changed(run);
      return step;
    }
    step.status = 'queued';
    this.#changed(run);
    try {
      await this.semaphore.acquire(signal);
    } catch {
      // cancelada na fila: sai sem ocupar uma vaga
      step.status = 'cancelled';
      step.finishedAt = Date.now();
      this.#changed(run);
      return step;
    }
    try {
      if (signal.aborted) {
        step.status = 'cancelled';
        return step;
      }
      step.status = 'running';
      step.startedAt = Date.now();
      this.#changed(run);
      let lastLive = 0;
      const result = await this.runAgent({
        agent: step.agent,
        model: step.model ?? null,
        prompt,
        dir: run.dir,
        timeoutMs: run.options.timeoutSec * 1000,
        signal,
        onOutput: (text) => {
          const stamp = Date.now();
          if (stamp - lastLive < 300) return;
          lastLive = stamp;
          step.output = truncateBytes(stripAnsi(text), LIMITS.stepOutput);
          this.#changed(run);
        },
      });
      step.output = result.output ?? '';
      step.error = result.error ?? '';
      step.durationMs = result.durationMs ?? Date.now() - step.startedAt;
      step.status = result.ok ? 'done' : result.cancelled ? 'cancelled' : 'error';
    } catch (error) {
      step.status = 'error';
      step.error = error.message;
    } finally {
      step.finishedAt = Date.now();
      this.semaphore.release();
      this.#changed(run);
    }
    return step;
  }

  async #execute(run, signal) {
    try {
      if (run.mode === 'compare') await this.#compare(run, signal);
      else if (run.mode === 'pipeline') await this.#pipeline(run, signal);
      else await this.#maestro(run, signal);
    } catch (error) {
      run.error = error.message;
    }
    for (const step of run.steps) {
      if (['pending', 'queued', 'running'].includes(step.status)) step.status = signal.aborted ? 'cancelled' : 'skipped';
    }
    run.status = signal.aborted ? 'cancelled' : run.error ? 'error' : 'done';
    if (run.status === 'cancelled' && !run.error) run.error = 'Execução cancelada';
    run.finishedAt = Date.now();
    await this.#changed(run, { immediate: true });
    this.active.delete(run.id);
    await this.#prune();
    this.emit('finish', run);
  }

  async #compare(run, signal) {
    const { agents, judge } = run.options;
    const steps = agents.map((agent) => this.#addStep(run, 'agent', agent, labelOf(agent)));
    const judgeStep = judge ? this.#addStep(run, 'judge', judge, `Juiz · ${labelOf(judge)}`) : null;
    this.#changed(run);
    await Promise.all(steps.map((step) => this.#runStep(run, signal, step, withPreamble(run.prompt))));
    const answers = steps.filter((step) => step.status === 'done').map((step) => ({ label: step.title, output: step.output }));
    if (signal.aborted) return;
    if (answers.length === 0) {
      run.error = 'Nenhum agente respondeu';
      return;
    }
    if (!judgeStep) return;
    if (answers.length < 2) {
      judgeStep.status = 'skipped';
      judgeStep.error = 'Só um agente respondeu; não há o que comparar';
      run.result = answers[0].output;
      return;
    }
    await this.#runStep(run, signal, judgeStep, judgePrompt(run.prompt, answers));
    if (judgeStep.status === 'done') run.result = judgeStep.output;
    else if (!signal.aborted) run.error = `O juiz falhou: ${judgeStep.error}`;
  }

  async #pipeline(run, signal) {
    const done = [];
    const steps = run.options.steps.map((item, index) => ({
      item,
      step: this.#addStep(run, 'stage', item.agent, `${index + 1}. ${ROLE_TITLES[item.role]} · ${labelOf(item.agent)}`),
    }));
    this.#changed(run);
    for (const { item, step } of steps) {
      const previous = done.at(-1) ?? null;
      const descriptor = { role: item.role, prompt: item.prompt, title: ROLE_TITLES[item.role] };
      await this.#runStep(run, signal, step, stepPrompt(run.prompt, descriptor, previous, done));
      if (step.status !== 'done') {
        if (!signal.aborted) run.error = `Etapa "${step.title}" falhou: ${step.error}`;
        return;
      }
      done.push(step);
    }
    run.result = done.at(-1).output;
  }

  async #maestro(run, signal) {
    const { agents, coordinator, maxTasks } = run.options;
    const models = run.options.models ?? {};
    const plan = this.#addStep(run, 'coordinator', coordinator, `Plano · ${labelOf(coordinator)}`);
    const integrate = this.#addStep(run, 'integrate', coordinator, `Integração · ${labelOf(coordinator)}`);
    this.#changed(run);

    let tasks = null;
    let prompt = coordinatorPrompt(run.prompt, agents, maxTasks, models);
    for (let attempt = 0; attempt < 2 && !tasks && !signal.aborted; attempt += 1) {
      await this.#runStep(run, signal, plan, prompt);
      if (plan.status !== 'done') {
        if (!signal.aborted) run.error = `O coordenador falhou: ${plan.error}`;
        return;
      }
      tasks = parseMaestroPlan(plan.output, agents, maxTasks, models);
      if (!tasks) {
        prompt = withPreamble(
          `Sua resposta anterior não era um JSON válido no formato pedido. Responda SOMENTE com o JSON {"tarefas":[{"agente","titulo","prompt"}]} para a tarefa:\n\n${run.prompt}\n\nAgentes permitidos: ${agents.join(', ')}.`,
        );
      }
    }
    if (signal.aborted) return;
    if (!tasks) {
      run.error = 'O coordenador não devolveu um plano válido';
      return;
    }

    const workers = tasks.map((task) => ({
      task,
      step: this.#addStep(run, 'worker', task.agent, `${task.title} · ${labelOf(task.agent)}${task.model ? ` (${task.model})` : ''}`, {
        subtask: task.title,
        model: task.model ?? null,
      }),
    }));
    // as subtarefas entram antes da integracao na linha do tempo
    run.steps.splice(run.steps.indexOf(integrate), 1);
    run.steps.push(integrate);
    run.steps.forEach((step, index) => {
      step.id = `s${index + 1}`;
    });
    this.#changed(run);

    await Promise.all(workers.map(({ task, step }) => this.#runStep(run, signal, step, withPreamble(task.prompt))));
    if (signal.aborted) return;
    const results = workers.map(({ task, step }) => ({ ...task, status: step.status, output: step.output, error: step.error }));
    if (!results.some((entry) => entry.status === 'done')) {
      run.error = 'Nenhuma subtarefa foi concluída';
      return;
    }
    await this.#runStep(run, signal, integrate, integrationPrompt(run.prompt, results));
    if (integrate.status === 'done') run.result = integrate.output;
    else if (!signal.aborted) run.error = `A integração falhou: ${integrate.error}`;
  }
}
