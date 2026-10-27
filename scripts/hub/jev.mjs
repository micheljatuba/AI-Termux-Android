// Frente de decisao com TypeSafe Jev (System One): antes de uma tarefa seguir para os agentes,
// o Jev classifica o risco, a clareza e sugere o agente e o modo. Opcional e desligado por padrao.
//
// O que sai do aparelho: o texto da tarefa, os NOMES de ate 300 arquivos da pasta (nunca o
// conteudo) e os agentes disponiveis. Antes do envio, segredos conhecidos na tarefa ou nos nomes
// impedem a requisicao. Sem resposta valida do Jev, a decisao e "indisponivel" e nada segue sem
// confirmacao explicita (falha fechada).
import { createHash } from 'node:crypto';
import { appendFile, chmod, mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const DEFAULT_BASE_URL = 'https://api.typesafe.ai';
export const DEFAULT_MODEL = 'jev-latest';
const KEY_PATTERN = /^[\x21-\x7e]{16,512}$/;
const LIMITS = Object.freeze({ task: 8 * 1024, files: 300, depth: 3, log: 1024 * 1024 });

const AGENT_NOTES = Object.freeze({
  claude: 'Claude Code: deep reasoning, refactoring and careful code review.',
  codex: 'Codex (OpenAI): implementing and explaining code.',
  copilot: 'GitHub Copilot: code plus GitHub work such as pull requests and issues.',
  opencode: 'OpenCode: open agent that can use several model providers.',
  agy: 'Antigravity (Google): general coding tasks.',
  hermes: 'Hermes Agent: generalist agent with tools and long-term memory.',
});

const SECRET_RULES = Object.freeze([
  ['chave privada', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['token GitHub', /gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}/],
  ['chave Anthropic/OpenAI', /(^|[^A-Za-z0-9])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}/],
  ['chave AWS', /(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}/],
  ['chave Google', /AIza[0-9A-Za-z_-]{35}/],
  ['token Slack', /xox[abprs]-[A-Za-z0-9-]{10,}/],
  ['token npm/GitLab', /npm_[A-Za-z0-9]{36}|glpat-[A-Za-z0-9_-]{20,}/],
  ['JWT', /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/],
  ['credencial em URL', /[a-z][a-z0-9+.-]*:\/\/[^/\s:@]+:[^/\s@]+@/],
  ['atribuicao de segredo', /(api[_-]?key|secret|token|passw(or)?d|senha)[A-Za-z0-9_]*\s*[:=]\s*["'][A-Za-z0-9/+_=.-]{20,}["']/i],
]);

const SENSITIVE_DIRS = new Set(['.ssh', '.aws', '.gnupg', '.claude', '.codex', '.copilot', '.gemini', '.ia', 'node_modules']);
const SENSITIVE_NAME =
  /^(\.env(\..*)?|.*\.(pem|key|p12|pfx|jks|keystore|kdbx|sqlite3?|db)|id_(rsa|dsa|ecdsa|ed25519).*|\.netrc|_netrc|\.git-credentials|\.npmrc|\.pypirc|\.pgpass|\.htpasswd|credentials(\.json)?|auth\.json|secrets\.(json|ya?ml)|service-account.*\.json)$/i;

export class JevUnavailable extends Error {}

/** Nomes das regras de segredo encontradas no texto; nunca o valor. */
export function findSecrets(text) {
  return SECRET_RULES.filter(([, rule]) => rule.test(text)).map(([name]) => name);
}

export const isSensitiveName = (name) => SENSITIVE_NAME.test(name);

export function jevPaths(state) {
  const dir = path.join(state, 'typesafe');
  return { dir, config: path.join(dir, 'config.json'), key: path.join(dir, 'key'), log: path.join(dir, 'decisoes.jsonl') };
}

function resolveBaseURL(raw) {
  const value = (raw || DEFAULT_BASE_URL).replace(/\/+$/, '');
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new JevUnavailable('TYPESAFE_BASE_URL invalida');
  }
  const loopback = url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !loopback) throw new JevUnavailable('TYPESAFE_BASE_URL precisa usar https');
  if (url.username || url.password || url.search || url.hash) throw new JevUnavailable('TYPESAFE_BASE_URL invalida');
  return value;
}

/** Le a configuracao; a chave vem do ambiente (TYPESAFE_API_KEY) ou do arquivo privado. */
export async function loadJevConfig({ state, env = process.env }) {
  const files = jevPaths(state);
  let saved = {};
  try {
    saved = JSON.parse(await readFile(files.config, 'utf8'));
  } catch {
    saved = {};
  }
  let key = (env.TYPESAFE_API_KEY || '').trim();
  let keySource = key ? 'ambiente' : 'ausente';
  if (!key) {
    try {
      key = (await readFile(files.key, 'utf8')).trim();
      keySource = key ? 'arquivo' : 'ausente';
    } catch {
      key = '';
    }
  }
  const model = typeof saved.model === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(saved.model) ? saved.model : DEFAULT_MODEL;
  return {
    enabled: saved.enabled === true,
    key: KEY_PATTERN.test(key) ? key : '',
    keySource: key && !KEY_PATTERN.test(key) ? 'invalida' : keySource,
    model,
    baseURL: env.TYPESAFE_BASE_URL || DEFAULT_BASE_URL,
    timeoutMs: Math.min(30000, Math.max(2000, Number.parseInt(env.TYPESAFE_TIMEOUT_MS, 10) || 10000)),
    files,
  };
}

async function ensurePrivateDir(dir) {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700);
}

export async function saveJevConfig(state, changes) {
  const files = jevPaths(state);
  await ensurePrivateDir(files.dir);
  let current = {};
  try {
    current = JSON.parse(await readFile(files.config, 'utf8'));
  } catch {
    current = {};
  }
  const next = { ...current, ...changes };
  await writeFile(`${files.config}.next`, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  await rename(`${files.config}.next`, files.config);
  return next;
}

export async function saveJevKey(state, key) {
  const value = String(key ?? '').trim();
  if (!KEY_PATTERN.test(value)) throw new Error('Chave invalida: cole a chave de API criada em console.typesafe.ai');
  const files = jevPaths(state);
  await ensurePrivateDir(files.dir);
  await writeFile(`${files.key}.next`, `${value}\n`, { mode: 0o600 });
  await chmod(`${files.key}.next`, 0o600);
  await rename(`${files.key}.next`, files.key);
}

export async function forgetJevKey(state) {
  await rm(jevPaths(state).key, { force: true });
}

/** Nomes de arquivos (relativos) da pasta, sem pastas ocultas, node_modules e nomes de credenciais. */
export async function listProjectFiles(root, { limit = LIMITS.files, depth = LIMITS.depth } = {}) {
  const names = [];
  let truncated = false;
  async function walk(dir, level) {
    if (names.length >= limit) return;
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (names.length >= limit) {
        truncated = true;
        return;
      }
      if (entry.name.startsWith('.') || SENSITIVE_DIRS.has(entry.name) || isSensitiveName(entry.name)) continue;
      const relative = path.relative(root, path.join(dir, entry.name));
      if (entry.isDirectory()) {
        if (level < depth) await walk(path.join(dir, entry.name), level + 1);
      } else if (entry.isFile()) {
        names.push(relative.split(path.sep).join('/'));
      }
    }
  }
  await walk(root, 1);
  return { names, truncated };
}

export function buildRequest({ task, files, truncated, agents, model }) {
  const routable = agents.filter((id) => AGENT_NOTES[id]);
  const questions = {
    safety: {
      type: 'choice',
      instructions:
        'Classify the risk of letting autonomous AI coding agents work on this task on the user\'s own phone, with access to the files listed in the state.',
      criteria: {
        safe: 'Reading, explaining, planning, reviewing or proposing code changes; nothing destructive or irreversible.',
        confirm:
          'Could delete or overwrite data, touch files outside the project, deploy, publish, push, spend money, change accounts or credentials, or install software.',
        block:
          'Aims at stealing or exposing credentials or private data, malware, attacking or abusing systems, evading security controls, or harming people.',
      },
    },
    clear: {
      type: 'noul',
      instructions:
        'Is this task clear and specific enough for a coding agent to start working without asking clarifying questions first?',
    },
    mode: {
      type: 'choice',
      instructions: 'Which way of using the agents fits this task best?',
      criteria: {
        direct: 'One agent working alone is enough: a question or a small, well-defined change.',
        compare: 'Independent answers from several agents should be compared: uncertain or high-stakes answer.',
        pipeline: 'Sequential stages help: plan, then implement, then review.',
        maestro: 'Large task that splits into parallel subtasks whose results are integrated.',
      },
    },
  };
  if (routable.length > 0) {
    questions.agent = {
      type: 'choice',
      instructions: 'Which available agent should lead this task?',
      criteria: Object.fromEntries(routable.map((id) => [id, AGENT_NOTES[id]])),
    };
  }
  return {
    model,
    state: {
      task: task.slice(0, LIMITS.task),
      project_files: files,
      project_files_truncated: Boolean(truncated),
      available_agents: routable,
    },
    questions,
  };
}

const unit = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;

function readChoice(answer, labels) {
  if (!answer || answer.type !== 'choice' || !labels.includes(answer.choice) || !unit(answer.confidence)) return null;
  const probabilities = {};
  for (const label of labels) {
    const value = answer.probabilities?.[label];
    probabilities[label] = unit(value) ? value : 0;
  }
  return { choice: answer.choice, confidence: answer.confidence, probabilities };
}

/** Converte as respostas do Jev numa decisao local e conservadora. */
export function decide(response, request) {
  const answers = response?.answers;
  const safety = readChoice(answers?.safety, Object.keys(request.questions.safety.criteria));
  const mode = readChoice(answers?.mode, Object.keys(request.questions.mode.criteria));
  const agent = request.questions.agent ? readChoice(answers?.agent, Object.keys(request.questions.agent.criteria)) : null;
  const clear = answers?.clear?.type === 'noul' && unit(answers.clear.noul) ? answers.clear.noul : null;
  if (!safety || !mode || clear === null || (request.questions.agent && !agent)) {
    throw new JevUnavailable('Resposta do Jev em formato inesperado');
  }
  const reasons = [];
  let verdict = 'allow';
  if (safety.choice === 'block' || safety.probabilities.block >= 0.5) {
    verdict = 'block';
    reasons.push(`risco alto (bloquear: ${pct(safety.probabilities.block)})`);
  } else if (safety.choice === 'confirm' || safety.probabilities.block >= 0.15 || safety.confidence < 0.6) {
    verdict = 'confirm';
    reasons.push(
      safety.choice === 'confirm'
        ? `pode alterar ou apagar dados, publicar ou mexer em contas (${pct(safety.probabilities.confirm)})`
        : `classificacao de risco incerta (confianca ${pct(safety.confidence)})`,
    );
  }
  if (verdict === 'allow' && clear < 0.5) {
    verdict = 'unclear';
    reasons.push(`tarefa pouco clara (clareza ${pct(clear)}); detalhe o objetivo, os arquivos e o resultado esperado`);
  } else if (clear < 0.5) {
    reasons.push(`tarefa pouco clara (clareza ${pct(clear)})`);
  }
  return {
    verdict,
    reasons,
    safety,
    clear,
    route: { mode: mode.choice, modeConfidence: mode.confidence, agent: agent?.choice ?? null, agentConfidence: agent?.confidence ?? null },
    model: typeof response.model === 'string' ? response.model.slice(0, 64) : request.model,
  };
}

const pct = (value) => `${Math.round(value * 100)}%`;

export async function askJev(config, body, { fetchImpl = fetch } = {}) {
  if (!config.key) throw new JevUnavailable('Chave do TypeSafe ausente; configure com: ia typesafe configurar');
  const base = resolveBaseURL(config.baseURL);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.timeoutMs);
  let res;
  try {
    res = await fetchImpl(`${base}/v1/systemone`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${config.key}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
      redirect: 'error',
    });
  } catch (error) {
    throw new JevUnavailable(error?.name === 'AbortError' ? `Sem resposta do Jev em ${config.timeoutMs / 1000} s` : 'Sem conexao com o TypeSafe');
  } finally {
    clearTimeout(timer);
  }
  if (res.status === 401 || res.status === 403) throw new JevUnavailable('Chave do TypeSafe recusada; configure outra com: ia typesafe configurar');
  if (res.status === 429) throw new JevUnavailable('Limite de uso do TypeSafe atingido');
  if (!res.ok) throw new JevUnavailable(`TypeSafe respondeu com erro ${res.status}`);
  try {
    return await res.json();
  } catch {
    throw new JevUnavailable('Resposta do Jev ilegivel');
  }
}

/** Confere chave e conexao sem enviar dados do projeto (GET /v1/models). */
export async function checkJev(config, { fetchImpl = fetch } = {}) {
  if (!config.key) throw new JevUnavailable('Chave do TypeSafe ausente; configure com: ia typesafe configurar');
  const base = resolveBaseURL(config.baseURL);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.timeoutMs);
  let res;
  try {
    res = await fetchImpl(`${base}/v1/models`, {
      headers: { Authorization: `Bearer ${config.key}`, Accept: 'application/json' },
      signal: controller.signal,
      redirect: 'error',
    });
  } catch {
    throw new JevUnavailable('Sem conexao com o TypeSafe');
  } finally {
    clearTimeout(timer);
  }
  if (res.status === 401 || res.status === 403) throw new JevUnavailable('Chave do TypeSafe recusada');
  if (!res.ok) throw new JevUnavailable(`TypeSafe respondeu com erro ${res.status}`);
  const data = await res.json().catch(() => null);
  const models = Array.isArray(data?.models) ? data.models.map((item) => String(item?.id ?? item?.name ?? item)).slice(0, 20) : [];
  return { models };
}

async function logDecision(files, entry) {
  try {
    await ensurePrivateDir(files.dir);
    const info = await stat(files.log).catch(() => null);
    if (info && info.size > LIMITS.log) await rename(files.log, `${files.log}.1`);
    await appendFile(files.log, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  } catch {
    // o registro e auxiliar: falhar ao gravar nao muda a decisao
  }
}

/**
 * Decide se uma tarefa segue para os agentes.
 * status: disabled | secret | unavailable | decided (com decision.verdict allow/confirm/unclear/block)
 */
export async function gateTask({ task, dir, agents, state, env = process.env, fetchImpl = fetch, now = () => new Date(), force = false }) {
  const config = await loadJevConfig({ state, env });
  if (!config.enabled && !force) return { status: 'disabled' };
  const text = String(task ?? '');
  const { names, truncated } = await listProjectFiles(dir);
  const secrets = findSecrets(`${text}\n${names.join('\n')}`);
  if (secrets.length > 0) return { status: 'secret', secrets };
  const body = buildRequest({ task: text, files: names, truncated, agents, model: config.model });
  const taskHash = createHash('sha256').update(text).digest('hex').slice(0, 16);
  try {
    const decision = decide(await askJev(config, body, { fetchImpl }), body);
    await logDecision(config.files, { at: now().toISOString(), task: taskHash, model: decision.model, verdict: decision.verdict, route: decision.route });
    return { status: 'decided', decision, sent: { files: names.length, truncated } };
  } catch (error) {
    if (!(error instanceof JevUnavailable)) throw error;
    await logDecision(config.files, { at: now().toISOString(), task: taskHash, verdict: 'unavailable', reason: error.message });
    return { status: 'unavailable', reason: error.message };
  }
}

/** Texto curto, em portugues, para o terminal ou o painel. */
export function describeGate(result) {
  switch (result.status) {
    case 'secret':
      return `A tarefa (ou um nome de arquivo) parece conter um segredo (${result.secrets.join(', ')}). Nada foi enviado ao TypeSafe; remova-o e tente de novo.`;
    case 'unavailable':
      return `Jev indisponivel: ${result.reason}.`;
    case 'decided': {
      const { decision } = result;
      const route = `sugestao: modo ${decision.route.mode}${decision.route.agent ? `, agente ${decision.route.agent}` : ''}`;
      const head = {
        allow: 'Jev: pode seguir.',
        confirm: 'Jev: confirme antes de seguir.',
        unclear: 'Jev: a tarefa precisa de mais detalhes.',
        block: 'Jev: tarefa bloqueada.',
      }[decision.verdict];
      return [head, ...decision.reasons.map((reason) => `- ${reason}`), `- ${route}`].join('\n');
    }
    default:
      return 'Jev desativado.';
  }
}

export const defaultState = (env = process.env) => env.TERMUX_AI_HUB_STATE || path.join(os.homedir(), '.local', 'share', 'termux-ai');
