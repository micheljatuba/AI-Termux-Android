// "ia orquestrar": comparar, pipeline e maestro direto no terminal (somente leitura).
import { stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline/promises';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { describeAgents, getAgent, supportsModel } from './agents.mjs';
import { checkJev, describeGate, forgetJevKey, gateTask, loadJevConfig, saveJevConfig, saveJevKey } from './jev.mjs';
import { loadModelPolicy, saveModelPolicy, withAgentModels } from './models.mjs';
import { Orchestrator } from './orchestrator.mjs';
import { HubError, clampInt } from './util.mjs';

const PREFERENCE = ['claude', 'copilot', 'codex', 'agy', 'opencode', 'hermes'];
const MODE_ALIASES = { comparar: 'compare', compare: 'compare', pipeline: 'pipeline', maestro: 'maestro', auto: 'auto' };
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
  auto         O Jev decide (risco, clareza e modo); o Hermes, se instalado,
               coordena e escolhe o agente e o modelo de cada subtarefa.
               Mostra o plano e pede confirmação (--sim sem terminal)

Outros comandos:
  agentes      Lista os agentes e o que cada um consegue fazer
  historico    Lista as últimas execuções
  ver ID       Mostra o resultado de uma execução (--tudo mostra cada etapa)
  decidir      Pergunta ao TypeSafe Jev o risco, a clareza e o melhor agente/modo
  modelos      Modelos permitidos por agente: "modelos claude opus,sonnet";
               "modelos claude limpar" volta ao padrão da conta
  typesafe     status | configurar | testar | ativar | desativar | esquecer

Frente de decisão (TypeSafe Jev, opcional): com "ia typesafe configurar", toda
orquestração passa antes pelo Jev. Bloqueio para a tarefa; confirmação, tarefa
pouco clara ou Jev indisponível param e perguntam. Só o texto da tarefa e os
NOMES dos arquivos da pasta vão ao TypeSafe (nunca o conteúdo); segredos na
tarefa impedem o envio.

Opções:
  -a, --agentes LISTA       Agentes separados por vírgula (comparar e maestro)
  -j, --juiz AGENTE         Juiz do comparar ("auto" escolhe o melhor disponível)
  -e, --etapas LISTA        Etapas do pipeline, ex.: planejar:claude,implementar:copilot,revisar:codex
  -c, --coordenador AGENTE  Coordenador do maestro
  -n, --max-tarefas N       Máximo de subtarefas do maestro (1 a 6, padrão 4)
  -d, --pasta DIR           Pasta de trabalho (padrão: a pasta atual)
  -t, --tempo SEGUNDOS      Tempo limite por etapa (30 a 1800, padrão 600)
      --confirmar           Segue quando o Jev pede confirmação ou mais detalhes
      --sem-jev             Segue quando o Jev está indisponível (nunca ignora um bloqueio)
      --sim                 Com "auto": executa o plano sem perguntar
      --json                Imprime a execução completa em JSON
      --tudo                Com "ver": inclui a saída de cada etapa
  -h, --ajuda               Mostra esta ajuda

A tarefa pode vir como argumentos ou pela entrada padrão ("-").

Exemplos:
  ia orquestrar comparar -a claude,copilot -j auto "Onde fica a validação de login?"
  ia orquestrar pipeline -e planejar:claude,implementar:copilot,revisar:agy "Adicionar cache ao cliente HTTP"
  ia orquestrar maestro -a claude,copilot,opencode "Mapear o projeto e listar riscos"
  ia orquestrar auto "Revisar a segurança do login e propor correções"
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
  confirmar: { type: 'boolean' },
  'sem-jev': { type: 'boolean' },
  sim: { type: 'boolean' },
  ajuda: { type: 'boolean', short: 'h' },
  help: { type: 'boolean' },
};

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

async function askYesNo(question) {
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  try {
    return /^(s|sim|y|yes)$/i.test((await rl.question(`${question} [s/N] `)).trim());
  } finally {
    rl.close();
  }
}

// Le a chave sem eco no terminal; pela entrada padrao quando nao ha terminal.
async function readSecretInput({ stdinIsTTY }) {
  if (!stdinIsTTY || typeof process.stdin.setRawMode !== 'function') return (await readStdin()).trim();
  process.stderr.write('Cole a chave de API do TypeSafe (ela nao aparece na tela) e tecle Enter: ');
  const stdin = process.stdin;
  return new Promise((resolve, reject) => {
    let value = '';
    const cleanup = () => {
      stdin.off('data', onData);
      stdin.setRawMode(false);
      stdin.pause();
      process.stderr.write('\n');
    };
    const onData = (chunk) => {
      for (const char of chunk) {
        if (char === '\r' || char === '\n') {
          cleanup();
          resolve(value.trim());
          return;
        }
        if (char === '\u0003') {
          cleanup();
          reject(new HubError(400, 'Cancelado'));
          return;
        }
        value = char === '\u007f' || char === '\b' ? value.slice(0, -1) : value + char;
      }
    };
    stdin.setRawMode(true);
    stdin.setEncoding('utf8');
    stdin.on('data', onData);
    stdin.resume();
  });
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

// Plano do modo auto: o Jev escolhe o modo; o Hermes (se instalado) coordena e escolhe agente e modelo
// de cada subtarefa. Os agentes que executam sao os que leem arquivos (o Hermes so planeja e integra).
export function autoPlan({ route, installed, readers, policy }) {
  if (readers.length === 0) throw new HubError(400, 'Nenhum agente que lê arquivos está instalado (veja "ia orquestrar agentes")');
  const hermes = installed.some((agent) => agent.id === 'hermes' && agent.installed && agent.orchestrable);
  const lead = readers.includes(route.agent) ? route.agent : readers[0];
  const order = [lead, ...readers.filter((id) => id !== lead)];
  const coordinator = hermes ? 'hermes' : lead;
  const label = (id) => getAgent(id)?.label ?? id;
  const allowed = Object.fromEntries(Object.entries(policy).filter(([agent]) => order.includes(agent)));
  const modelsText = Object.keys(allowed).length
    ? ` · modelos: ${Object.entries(allowed).map(([agent, names]) => `${agent} (${names.join(', ')})`).join(', ')}`
    : ' · modelos: padrão de cada conta';
  let spec;
  let text;
  if (route.mode === 'compare' && order.length >= 2) {
    spec = { mode: 'compare', agents: order.slice(0, 3), judge: coordinator };
    text = `comparar · ${spec.agents.map(label).join(', ')} · juiz ${label(coordinator)}`;
  } else if (route.mode === 'pipeline') {
    spec = { mode: 'pipeline', steps: ROLE_ORDER.map((role, index) => ({ role, agent: order[index % order.length] })) };
    text = `pipeline · ${spec.steps.map((step) => `${step.role === 'plan' ? 'planejar' : step.role === 'implement' ? 'implementar' : 'revisar'}: ${label(step.agent)}`).join(' → ')}`;
  } else {
    const maxTasks = route.mode === 'direct' ? 1 : 4;
    spec = { mode: 'maestro', agents: order, coordinator, maxTasks, models: allowed };
    text = `maestro · coordenador ${label(coordinator)} · agentes ${order.map(label).join(', ')} · até ${maxTasks} subtarefa${maxTasks > 1 ? 's' : ''}${modelsText}`;
  }
  return { spec, summary: `Plano do Jev: ${text} (somente leitura)` };
}

async function modelsCommand(rest, { state, say }) {
  const policy = await loadModelPolicy(state);
  if (rest.length === 0) {
    say('Modelos permitidos por agente na orquestração (o coordenador escolhe dentro da lista):');
    for (const agent of describeAgents('').filter((item) => supportsModel(item.id))) {
      say(`  ${pad(agent.id, 9)} ${policy[agent.id]?.join(', ') ?? '(padrão da conta)'}`);
    }
    say('Defina com: ia orquestrar modelos claude opus,sonnet  ·  limpe com: ia orquestrar modelos claude limpar');
    return 0;
  }
  const [agent, list = '', ...extra] = rest;
  if (extra.length > 0 || !list) throw new HubError(400, 'Uso: ia orquestrar modelos <agente> <modelo1,modelo2> | limpar');
  const id = String(agent).toLowerCase();
  const names = list.toLowerCase() === 'limpar' ? [] : list.split(',');
  const next = withAgentModels(policy, id, names);
  await saveModelPolicy(state, next);
  say(next[id] ? `${id}: ${next[id].join(', ')}` : `${id}: padrão da conta`);
  return 0;
}

// Frente de decisao: true quando a tarefa pode seguir para os agentes.
async function passGate({ result, values, canAsk, ask, warn }) {
  if (result.status === 'disabled') return true;
  warn(describeGate(result));
  if (result.status === 'secret') return false;
  if (result.status === 'unavailable') {
    if (values['sem-jev']) {
      warn('Seguindo sem a decisão do Jev, a pedido (--sem-jev).');
      return true;
    }
    if (canAsk) return ask('Seguir sem a decisão do Jev?');
    warn('Parado. Para seguir sem o Jev, repita com --sem-jev.');
    return false;
  }
  const { verdict } = result.decision;
  if (verdict === 'allow') return true;
  if (verdict === 'block') {
    warn('Nada foi executado. Reformule a tarefa: o bloqueio do Jev não tem atalho para ignorar.');
    return false;
  }
  if (values.confirmar) return true;
  if (canAsk) return ask('Seguir mesmo assim?');
  warn('Parado. Para seguir, repita com --confirmar.');
  return false;
}

async function typesafeCommand(action = 'status', { state, env, say, warn, readSecret, stdinIsTTY, fetchImpl }) {
  if (action === 'status') {
    const config = await loadJevConfig({ state, env });
    say(`TypeSafe Jev: ${config.enabled ? 'ativo (toda orquestração passa antes pelo Jev)' : 'desativado'}`);
    say(`Chave: ${{ arquivo: 'salva em arquivo privado', ambiente: 'da variável TYPESAFE_API_KEY', invalida: 'inválida', ausente: 'não configurada' }[config.keySource]}`);
    say(`Modelo: ${config.model}`);
    if (!config.key) say('Crie uma chave em https://console.typesafe.ai e execute: ia typesafe configurar');
    return 0;
  }
  if (action === 'configurar') {
    await saveJevKey(state, await readSecret({ stdinIsTTY }));
    await saveJevConfig(state, { enabled: true });
    say('Chave salva em arquivo privado e frente de decisão ativada.');
    say('Confira a conexão com: ia typesafe testar');
    return 0;
  }
  if (action === 'ativar') {
    if (!(await loadJevConfig({ state, env })).key) throw new HubError(400, 'Configure a chave antes: ia typesafe configurar');
    await saveJevConfig(state, { enabled: true });
    say('Frente de decisão ativada.');
    return 0;
  }
  if (action === 'desativar') {
    await saveJevConfig(state, { enabled: false });
    say('Frente de decisão desativada: as orquestrações seguem sem o Jev.');
    return 0;
  }
  if (action === 'esquecer') {
    await forgetJevKey(state);
    await saveJevConfig(state, { enabled: false });
    say('Chave apagada e frente de decisão desativada.');
    return 0;
  }
  if (action === 'testar') {
    try {
      const { models } = await checkJev(await loadJevConfig({ state, env }), { fetchImpl });
      say(`Conexão com o TypeSafe ok${models.length ? `; modelos: ${models.join(', ')}` : ''}.`);
      return 0;
    } catch (error) {
      warn(`Erro: ${error.message}`);
      return 4;
    }
  }
  warn('Uso: ia typesafe status | configurar | testar | ativar | desativar | esquecer');
  return 2;
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
    gate = gateTask,
    ask = askYesNo,
    readSecret = readSecretInput,
    fetchImpl = fetch,
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
  if (command === 'modelos') {
    try {
      return await modelsCommand(rest, { state, say });
    } catch (error) {
      warn(`Erro: ${error.message}`);
      return 2;
    }
  }
  if (command === 'typesafe') {
    try {
      return await typesafeCommand(rest[0], { state, env, say, warn, readSecret, stdinIsTTY, fetchImpl });
    } catch (error) {
      warn(`Erro: ${error.message}`);
      return 2;
    }
  }
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

    const mode = command === 'decidir' ? 'decide' : MODE_ALIASES[command];
    if (!mode) {
      warn(`Comando desconhecido: ${command}`);
      warn('Use comparar, pipeline, maestro, agentes, historico ou ver. Veja "ia orquestrar --ajuda".');
      return 2;
    }

    let prompt = rest.join(' ').trim();
    let fromStdin = false;
    if (rest.length === 1 && rest[0] === '-') {
      prompt = (await readInput()).trim();
      fromStdin = true;
    } else if (rest.length === 0 && !stdinIsTTY) {
      prompt = (await readInput()).trim();
      fromStdin = true;
    }
    if (!prompt) {
      warn('Erro: informe a tarefa (argumentos ou entrada padrão com "-").');
      return 2;
    }

    const dir = path.resolve(cwd, values.pasta ?? '.');
    if (!(await stat(dir).then((info) => info.isDirectory(), () => false))) {
      warn(`Erro: pasta não encontrada: ${dir}`);
      return 2;
    }

    const installedIds = installed.filter((agent) => agent.installed && agent.orchestrable).map((agent) => agent.id);
    if (mode === 'decide') {
      const result = await gate({ task: prompt, dir, agents: installedIds, state, env, fetchImpl, force: true });
      say(describeGate(result));
      if (result.status === 'decided') {
        const { route, verdict } = result.decision;
        if (verdict !== 'block') {
          say(
            route.mode === 'direct'
              ? `Para seguir: ia ${route.agent ?? 'claude'}`
              : `Para seguir: ia orquestrar ${MODE_NAMES[route.mode]}${route.agent ? ` -a ${route.agent}` : ''} "<tarefa>"`,
          );
          say('Ou deixe o Jev decidir e o coordenador conduzir: ia orquestrar auto "<tarefa>"');
        }
        return { allow: 0, confirm: 1, unclear: 1, block: 3 }[verdict];
      }
      return result.status === 'secret' ? 3 : 4;
    }

    const canAsk = stdinIsTTY && !fromStdin;
    const verdict = await gate({ task: prompt, dir, agents: installedIds, state, env, fetchImpl });
    if (mode === 'auto' && verdict.status === 'disabled') {
      warn('O modo auto precisa do Jev como decisor. Ative com: ia typesafe configurar');
      return 2;
    }
    if (!(await passGate({ result: verdict, values, canAsk, ask, warn }))) return 3;

    const defaults = readableAgents(installed);
    if (defaults.length === 0 && !values.agentes && !values.etapas) {
      throw new HubError(400, 'Nenhum agente instalado para orquestrar (veja "ia orquestrar agentes")');
    }
    let spec = { mode, prompt, dir, timeoutSec: clampInt(values.tempo, 30, 1800, 600) };
    if (mode === 'auto') {
      const route = verdict.status === 'decided' ? verdict.decision.route : { mode: 'maestro', agent: null };
      const plan = autoPlan({ route, installed, readers: defaults, policy: await loadModelPolicy(state) });
      spec = { ...plan.spec, prompt, dir, timeoutSec: spec.timeoutSec };
      warn(plan.summary);
      if (!values.sim) {
        if (!canAsk) {
          warn('Parado. Para executar este plano sem terminal, repita com --sim.');
          return 3;
        }
        if (!(await ask('Executar este plano?'))) return 3;
      }
    }
    if (values.agentes && !splitList(values.agentes).length) throw new HubError(400, 'A lista de agentes está vazia');
    const chosen = values.agentes ? splitList(values.agentes) : defaults;
    if (mode === 'auto') {
      // o plano do Jev e do coordenador ja definiu agentes, modo e modelos
    } else if (mode === 'compare') {
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
    warn(`Execução ${run.id} (${MODE_NAMES[spec.mode]}, somente leitura) em ${dir}`);
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
