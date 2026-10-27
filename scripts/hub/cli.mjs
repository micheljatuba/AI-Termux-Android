// "ia orquestrar": comparar, pipeline e maestro direto no terminal (somente leitura).
import { stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { describeAgents, getAgent } from './agents.mjs';
import { Orchestrator } from './orchestrator.mjs';
import { HubError, clampInt } from './util.mjs';

const PREFERENCE = ['claude', 'copilot', 'codex', 'agy', 'opencode', 'hermes'];
const MODE_ALIASES = { comparar: 'compare', compare: 'compare', pipeline: 'pipeline', maestro: 'maestro' };
const MODE_NAMES = { compare: 'comparar', pipeline: 'pipeline', maestro: 'maestro' };
const ROLE_ALIASES = {
  planejar: 'plan',
  plan: 'plan',
  implementar: 'implement',
  implement: 'implement',
  revisar: 'review',
  review: 'review',
};
const ROLE_ORDER = ['plan', 'implement', 'review'];
const STATUS_ICON = { queued: '…', running: '▶', done: '✓', error: '✗', cancelled: '■', skipped: '–' };
const STATUS_TEXT = {
  queued: 'na fila',
  running: 'executando',
  done: 'concluído',
  error: 'erro',
  cancelled: 'cancelado',
  skipped: 'ignorado',
};
const RUN_STATUS_TEXT = { running: 'em execução', done: 'concluída', error: 'com erro', cancelled: 'cancelada', queued: 'na fila' };

export const HELP = `Uso: ia orquestrar <modo> [opções] [tarefa | -]

Executa vários agentes em modo SOMENTE LEITURA (nada é editado ou executado
no seu projeto) e imprime o resultado final. O progresso vai para o stderr.

Modos:
  comparar     Os agentes respondem à mesma tarefa; um juiz compara (opcional)
  pipeline     Planejar → implementar → revisar, cada etapa com um agente
  maestro      Um coordenador divide a tarefa, os agentes trabalham em paralelo
               e o coordenador integra os resultados

Outros comandos:
  agentes      Lista os agentes e o que cada um consegue fazer
  historico    Lista as últimas execuções
  ver ID       Mostra o resultado de uma execução (--tudo mostra cada etapa)

Opções:
  -a, --agentes LISTA       Agentes separados por vírgula (comparar e maestro)
  -j, --juiz AGENTE         Juiz do comparar ("auto" escolhe o melhor disponível)
  -e, --etapas LISTA        Etapas do pipeline, ex.: planejar:claude,implementar:copilot,revisar:codex
  -c, --coordenador AGENTE  Coordenador do maestro
  -n, --max-tarefas N       Máximo de subtarefas do maestro (1 a 6, padrão 4)
  -d, --pasta DIR           Pasta de trabalho (padrão: a pasta atual)
  -t, --tempo SEGUNDOS      Tempo limite por etapa (30 a 1800, padrão 600)
      --json                Imprime a execução completa em JSON
      --tudo                Com "ver": inclui a saída de cada etapa
  -h, --ajuda               Mostra esta ajuda

A tarefa pode vir como argumentos ou pela entrada padrão ("-").

Exemplos:
  ia orquestrar comparar -a claude,copilot -j auto "Onde fica a validação de login?"
  ia orquestrar pipeline -e planejar:claude,implementar:copilot,revisar:agy "Adicionar cache ao cliente HTTP"
  ia orquestrar maestro -a claude,copilot,opencode "Mapear o projeto e listar riscos"
  git diff | ia orquestrar comparar -a claude,copilot -j auto -`;

const OPTIONS = {
  agentes: { type: 'string', short: 'a' },
  juiz: { type: 'string', short: 'j' },
  etapas: { type: 'string', short: 'e' },
  coordenador: { type: 'string', short: 'c' },
  'max-tarefas': { type: 'string', short: 'n' },
  pasta: { type: 'string', short: 'd' },
  tempo: { type: 'string', short: 't' },
  json: { type: 'boolean' },
  tudo: { type: 'boolean' },
  ajuda: { type: 'boolean', short: 'h' },
  help: { type: 'boolean' },
};

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

const pad = (value, width) => String(value).padEnd(width);
const clock = (ms) => {
  const total = Math.max(0, Math.round(ms / 1000));
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
};
const seconds = (ms) => (ms >= 60000 ? `${Math.floor(ms / 60000)} min ${Math.round((ms % 60000) / 1000)} s` : `${Math.round(ms / 1000)} s`);
const stamp = (ms) => {
  const date = new Date(ms);
  const two = (n) => String(n).padStart(2, '0');
  return `${two(date.getDate())}/${two(date.getMonth() + 1)} ${two(date.getHours())}:${two(date.getMinutes())}`;
};

function splitList(text) {
  return String(text ?? '')
    .split(',')
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
}

function readableAgents(installed) {
  const ready = installed.filter((agent) => agent.installed && agent.orchestrable && agent.reads).map((agent) => agent.id);
  return PREFERENCE.filter((id) => ready.includes(id));
}

function parseSteps(text, fallback) {
  const items = splitList(text);
  if (items.length === 0) return null;
  return items.map((item, index) => {
    const [role, agent] = item.includes(':') ? item.split(':') : [ROLE_ORDER[Math.min(index, 2)], item];
    const mapped = ROLE_ALIASES[role];
    if (!mapped) throw new HubError(400, `Etapa inválida "${item}": use planejar, implementar ou revisar`);
    return { role: mapped, agent: agent || fallback[index % fallback.length] };
  });
}

function fallbackText(run) {
  return run.steps
    .filter((step) => step.status === 'done' && ['agent', 'worker', 'stage', 'coordinator'].includes(step.kind))
    .map((step) => `## ${step.title}\n\n${step.output}`)
    .join('\n\n');
}

function describeRun(run) {
  return `${run.id} · ${MODE_NAMES[run.mode] ?? run.mode} · ${RUN_STATUS_TEXT[run.status] ?? run.status}`;
}

async function findRun(orchestrator, query) {
  await orchestrator.refresh();
  const needle = String(query ?? '').trim();
  if (!needle) throw new HubError(400, 'Informe o ID da execução (veja "ia orquestrar historico")');
  const matches = orchestrator.list().filter((item) => item.id === needle || item.id.includes(needle));
  if (matches.length === 0) throw new HubError(404, `Execução não encontrada: ${needle}`);
  const exact = matches.find((item) => item.id === needle);
  if (!exact && matches.length > 1) throw new HubError(400, `ID ambíguo: ${matches.slice(0, 5).map((item) => item.id).join(', ')}`);
  return orchestrator.get((exact ?? matches[0]).id);
}

export async function run(
  argv,
  {
    out = process.stdout,
    err = process.stderr,
    readInput = readStdin,
    stdinIsTTY = Boolean(process.stdin.isTTY),
    env = process.env,
    cwd = process.cwd(),
    orchestrator = null,
    describe = describeAgents,
    signals = process,
  } = {},
) {
  const say = (text = '') => out.write(`${text}\n`);
  const warn = (text = '') => err.write(`${text}\n`);

  let parsed;
  try {
    parsed = parseArgs({ args: argv, options: OPTIONS, allowPositionals: true, strict: true });
  } catch (error) {
    warn(`Erro: ${error.message}`);
    warn('Veja "ia orquestrar --ajuda".');
    return 2;
  }
  const { values, positionals } = parsed;
  const [command, ...rest] = positionals;
  if (values.ajuda || values.help || !command || command === 'ajuda' || command === 'help') {
    say(HELP);
    return 0;
  }

  const state = env.TERMUX_AI_HUB_STATE || path.join(os.homedir(), '.local', 'share', 'termux-ai');
  const orch =
    orchestrator ??
    new Orchestrator({
      dir: path.join(state, 'runs'),
      maxParallel: clampInt(env.TERMUX_AI_HUB_MAX_PARALLEL, 1, 8, 4),
    });
  const installed = describe();

  try {
    await orch.init();

    if (command === 'agentes') {
      say('Agentes para orquestração (todos em modo somente leitura):');
      for (const agent of installed.filter((item) => item.orchestrable)) {
        const status = agent.installed ? 'instalado' : 'não instalado';
        const files = agent.reads ? 'lê arquivos' : 'sem acesso a arquivos';
        say(`  ${pad(agent.id, 9)} ${pad(agent.label, 15)} ${pad(status, 14)} ${pad(files, 22)} ${agent.guard}`);
      }
      return 0;
    }

    if (command === 'historico' || command === 'histórico') {
      await orch.refresh();
      const runs = orch.list().slice(0, 20);
      if (runs.length === 0) {
        say('Nenhuma execução ainda.');
        return 0;
      }
      say(`${pad('ID', 23)} ${pad('MODO', 9)} ${pad('STATUS', 12)} ${pad('QUANDO', 12)} TAREFA`);
      for (const item of runs) {
        const task = item.prompt.replace(/\s+/g, ' ').slice(0, 50);
        say(`${pad(item.id, 23)} ${pad(MODE_NAMES[item.mode] ?? item.mode, 9)} ${pad(RUN_STATUS_TEXT[item.status] ?? item.status, 12)} ${pad(stamp(item.createdAt), 12)} ${task}`);
      }
      return 0;
    }

    if (command === 'ver') {
      const found = await findRun(orch, rest[0]);
      if (values.json) {
        say(JSON.stringify(found, null, 2));
        return 0;
      }
      warn(describeRun(found));
      if (values.tudo) {
        for (const step of found.steps) {
          say(`=== ${step.title} (${STATUS_TEXT[step.status] ?? step.status}${step.durationMs ? `, ${seconds(step.durationMs)}` : ''}) ===`);
          say(step.output || step.error || '(sem saída)');
          say();
        }
      } else {
        say(found.result || fallbackText(found) || found.error || '(sem resultado)');
      }
      return found.status === 'done' ? 0 : 1;
    }

    const mode = MODE_ALIASES[command];
    if (!mode) {
      warn(`Comando desconhecido: ${command}`);
      warn('Use comparar, pipeline, maestro, agentes, historico ou ver. Veja "ia orquestrar --ajuda".');
      return 2;
    }

    let prompt = rest.join(' ').trim();
    if (rest.length === 1 && rest[0] === '-') prompt = (await readInput()).trim();
    else if (rest.length === 0 && !stdinIsTTY) prompt = (await readInput()).trim();
    if (!prompt) {
      warn('Erro: informe a tarefa (argumentos ou entrada padrão com "-").');
      return 2;
    }

    const dir = path.resolve(cwd, values.pasta ?? '.');
    if (!(await stat(dir).then((info) => info.isDirectory(), () => false))) {
      warn(`Erro: pasta não encontrada: ${dir}`);
      return 2;
    }

    const defaults = readableAgents(installed);
    if (defaults.length === 0 && !values.agentes && !values.etapas) {
      throw new HubError(400, 'Nenhum agente instalado para orquestrar (veja "ia orquestrar agentes")');
    }
    const spec = { mode, prompt, dir, timeoutSec: clampInt(values.tempo, 30, 1800, 600) };
    if (values.agentes && !splitList(values.agentes).length) throw new HubError(400, 'A lista de agentes está vazia');
    const chosen = values.agentes ? splitList(values.agentes) : defaults;
    if (mode === 'compare') {
      spec.agents = chosen;
      if (values.juiz) spec.judge = values.juiz.toLowerCase() === 'auto' ? defaults[0] : values.juiz.toLowerCase();
    } else if (mode === 'maestro') {
      spec.agents = chosen;
      if (values.coordenador) spec.coordinator = values.coordenador.toLowerCase();
      if (values['max-tarefas']) spec.maxTasks = clampInt(values['max-tarefas'], 1, 6, 4);
    } else {
      const pool = defaults.length ? defaults : chosen;
      spec.steps = parseSteps(values.etapas, pool) ?? ROLE_ORDER.map((role, index) => ({ role, agent: pool[index % Math.max(1, pool.length)] }));
    }
    for (const agent of [...(spec.agents ?? []), ...(spec.steps ?? []).map((step) => step.agent)]) {
      if (!getAgent(agent)) throw new HubError(400, `Agente desconhecido: ${agent}`);
    }

    const run = orch.start(spec);
    const started = Date.now();
    const seen = new Map();
    const report = (current) => {
      if (current.id !== run.id) return;
      for (const step of current.steps) {
        if (seen.get(step.id) === step.status || step.status === 'pending') continue;
        seen.set(step.id, step.status);
        const icon = STATUS_ICON[step.status] ?? '•';
        const detail =
          step.status === 'done'
            ? ` (${seconds(step.durationMs ?? 0)})`
            : step.status === 'error' && step.error
              ? `: ${step.error}`
              : '';
        warn(`[${clock(Date.now() - started)}] ${icon} ${step.title} — ${STATUS_TEXT[step.status] ?? step.status}${detail}`);
      }
    };
    warn(`Execução ${run.id} (${MODE_NAMES[mode]}, somente leitura) em ${dir}`);
    orch.on('update', report);
    report(run);
    const onInterrupt = () => {
      warn('Cancelando…');
      try {
        orch.cancel(run.id);
      } catch {
        // a execucao ja terminou
      }
    };
    signals.once?.('SIGINT', onInterrupt);
    signals.once?.('SIGTERM', onInterrupt);
    signals.once?.('SIGHUP', onInterrupt);
    await orch.wait(run.id);
    orch.off('update', report);
    signals.off?.('SIGINT', onInterrupt);
    signals.off?.('SIGTERM', onInterrupt);
    signals.off?.('SIGHUP', onInterrupt);
    report(run);

    if (values.json) {
      say(JSON.stringify(run, null, 2));
    } else if (run.status === 'done') {
      say(run.result || fallbackText(run));
    } else {
      warn(`Erro: ${run.error || 'a execução não terminou'}`);
      const partial = fallbackText(run);
      if (partial) {
        warn('Respostas parciais recebidas:');
        say(partial);
      }
    }
    warn(`Execução ${run.id}: ${RUN_STATUS_TEXT[run.status] ?? run.status} em ${seconds(Date.now() - started)}. Veja de novo com: ia orquestrar ver ${run.id}`);
    return run.status === 'done' ? 0 : run.status === 'cancelled' ? 130 : 1;
  } catch (error) {
    if (error instanceof HubError) {
      warn(`Erro: ${error.message}`);
      return 2;
    }
    throw error;
  } finally {
    await orch.shutdown?.();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      process.stderr.write(`ia orquestrar: ${error?.stack ?? error}\n`);
      process.exit(1);
    },
  );
}
