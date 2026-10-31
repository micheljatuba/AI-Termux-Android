// Catalogo de agentes do painel: comandos interativos (tmux) e adaptadores
// "headless" somente leitura usados pela orquestracao.
import { accessSync, constants, statSync } from 'node:fs';
import path from 'node:path';

export const READONLY_PREAMBLE =
  'MODO SOMENTE LEITURA: você só pode ler e analisar. NÃO crie, edite, apague nem renomeie arquivos, ' +
  'NÃO execute comandos que alterem o sistema e NÃO instale nada. Se a tarefa pedir mudanças, ' +
  'descreva-as (código, diff ou passos) na resposta, sem aplicá-las. Responda em português do Brasil.';

const stripThinking = (text) => {
  const end = text.lastIndexOf('</think>');
  return end === -1 ? text : text.slice(end + '</think>'.length);
};

const DEFINITIONS = [
  {
    id: 'copilot',
    label: 'GitHub Copilot',
    short: 'Copilot',
    bin: 'copilot',
    color: '#a371f7',
    session: ['copilot'],
    reads: true,
    guard: 'Bloqueia escrita e shell (--deny-tool).',
    login: 'ia copilot',
    headless: ({ prompt }) => ({
      args: ['-p', prompt, '-s', '--no-ask-user', '--no-auto-update', '--deny-tool=write', '--deny-tool=shell'],
    }),
    withModel: (args, model) => [...args, '--model', model],
  },
  {
    id: 'claude',
    label: 'Claude Code',
    short: 'Claude',
    bin: 'claude',
    color: '#d97757',
    session: ['claude'],
    reads: true,
    guard: 'Só ferramentas Read, Grep e Glob (modo dontAsk).',
    login: 'ia claude',
    headless: ({ prompt }) => ({
      args: [
        '-p',
        '--output-format',
        'text',
        '--no-session-persistence',
        '--permission-mode',
        'dontAsk',
        '--allowedTools=Read,Grep,Glob',
        '--tools=Read,Grep,Glob',
      ],
      stdin: prompt,
    }),
    // Flags conferidas no --help das versoes fixadas pelo instalador.
    withModel: (args, model) => [...args, '--model', model],
  },
  {
    id: 'codex',
    label: 'Codex',
    short: 'Codex',
    bin: 'codex',
    color: '#19c3a1',
    session: ['codex', '-s', 'workspace-write', '-a', 'on-request'],
    reads: true,
    guard: 'Sandbox read-only do Codex.',
    note: 'Experimental no Android/PRoot: sem sandbox funcional, o Codex pode não conseguir ler arquivos.',
    login: 'ia codex',
    headless: ({ prompt, dir }) => ({
      args: ['exec', '-s', 'read-only', '--skip-git-repo-check', '--ephemeral', '-C', dir, '-'],
      stdin: prompt,
    }),
    // "-" (prompt na entrada padrao) continua sendo o ultimo argumento.
    withModel: (args, model) => [...args.slice(0, -1), '-m', model, args.at(-1)],
  },
  {
    id: 'agy',
    label: 'Antigravity',
    short: 'Antigravity',
    bin: 'agy',
    color: '#58a6ff',
    session: ['agy'],
    reads: true,
    guard: 'Modo plan (somente planejamento).',
    login: 'ia agy',
    headless: ({ prompt }) => ({ args: ['-p', prompt, '--mode', 'plan', '--output-format', 'text'] }),
  },
  {
    id: 'opencode',
    label: 'OpenCode',
    short: 'OpenCode',
    bin: 'opencode',
    color: '#f778ba',
    session: ['opencode'],
    reads: true,
    guard: 'Agente plan (permissões de edição negadas).',
    login: 'ia opencode',
    headless: ({ prompt, dir }) => ({ args: ['run', prompt, '--agent', 'plan', '--dir', dir] }),
    // OpenCode usa provedor/modelo (ex.: anthropic/claude-sonnet-4).
    withModel: (args, model) => [...args, '-m', model],
    clean: stripThinking,
  },
  {
    id: 'hermes',
    label: 'Hermes Agent',
    short: 'Hermes',
    bin: 'hermes',
    color: '#e3b341',
    session: ['hermes'],
    reads: false,
    guard: 'Só ferramentas web e search; não lê nem altera arquivos.',
    login: 'ia hermes setup',
    headless: ({ prompt }) => ({ args: ['-z', prompt, '-t', 'web,search'] }),
  },
];

export const SHELL = Object.freeze({
  id: 'shell',
  label: 'Terminal',
  short: 'Terminal',
  bin: 'bash',
  color: '#8b949e',
  session: ['bash', '-l'],
  reads: false,
  guard: '',
  login: '',
  headless: null,
});

export const AGENTS = Object.freeze(DEFINITIONS.map((definition) => Object.freeze(definition)));
export const AGENT_IDS = Object.freeze(AGENTS.map((agent) => agent.id));

export function getAgent(id) {
  if (id === SHELL.id) return SHELL;
  return AGENTS.find((agent) => agent.id === id) ?? null;
}

export function findExecutable(name, searchPath = process.env.PATH ?? '') {
  for (const directory of searchPath.split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, name);
    try {
      accessSync(candidate, constants.X_OK);
      if (statSync(candidate).isFile()) return candidate;
    } catch {
      // continua procurando nas demais pastas do PATH
    }
  }
  return null;
}

// Visao publica (sem funcoes) dos agentes, com a instalacao detectada.
export function describeAgents(searchPath = process.env.PATH ?? '') {
  return [...AGENTS, SHELL].map((agent) => {
    const location = agent.id === SHELL.id ? agent.bin : findExecutable(agent.bin, searchPath);
    return {
      id: agent.id,
      label: agent.label,
      short: agent.short,
      color: agent.color,
      installed: Boolean(location),
      orchestrable: Boolean(agent.headless),
      reads: agent.reads,
      models: Boolean(agent.withModel),
      guard: agent.guard,
      note: agent.note ?? '',
      login: agent.login,
    };
  });
}

// Mesmo ambiente do launcher "ia": PATH com ~/.local/bin e marcador do guest.
const LOGIN_SCRIPT = 'export TERMUX_AI_GUEST=1; export PATH="$HOME/.local/bin:$PATH"; exec "$@"';

export function sessionArgv(id) {
  const agent = getAgent(id);
  if (!agent) return null;
  if (id === SHELL.id) return [...agent.session];
  return ['bash', '-lc', LOGIN_SCRIPT, 'ia-sessao', ...agent.session];
}

// Nome de modelo seguro para virar argumento: sem espaco e sem comecar com "-" (nao vira uma flag).
export const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,79}$/;

/** O agente aceita escolher o modelo na execucao automatica? */
export const supportsModel = (id) => Boolean(getAgent(id)?.withModel);

// Comando de uma execucao unica somente leitura (usado pela orquestracao).
export function headlessCommand(id, { prompt, dir, model = null }) {
  const agent = getAgent(id);
  if (!agent?.headless) return null;
  const spec = agent.headless({ prompt, dir });
  const useModel = model && agent.withModel && MODEL_NAME.test(model);
  return {
    command: agent.bin,
    args: useModel ? agent.withModel(spec.args, model) : spec.args,
    stdin: spec.stdin ?? null,
    clean: agent.clean ?? ((text) => text),
  };
}
