// Modelos permitidos por agente na orquestracao: o coordenador (ex.: Hermes) so escolhe dentro desta lista.
// Um agente sem lista usa o modelo padrao da conta. Guardado em <estado>/modelos.json (arquivo 600).
import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { MODEL_NAME, supportsModel } from './agents.mjs';
import { HubError } from './util.mjs';

export const MAX_MODELS = 8;

const policyFile = (state) => path.join(state, 'modelos.json');

/** Mantem so agentes que aceitam modelo e nomes validos, sem repeticao. */
export function sanitizePolicy(raw) {
  const policy = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return policy;
  for (const [agent, list] of Object.entries(raw)) {
    if (!supportsModel(agent) || !Array.isArray(list)) continue;
    const names = [...new Set(list.map((item) => String(item ?? '').trim()).filter((item) => MODEL_NAME.test(item)))].slice(0, MAX_MODELS);
    if (names.length > 0) policy[agent] = names;
  }
  return policy;
}

export async function loadModelPolicy(state) {
  try {
    return sanitizePolicy(JSON.parse(await readFile(policyFile(state), 'utf8')));
  } catch {
    return {};
  }
}

export async function saveModelPolicy(state, policy) {
  await mkdir(state, { recursive: true });
  const file = policyFile(state);
  await writeFile(`${file}.next`, `${JSON.stringify(sanitizePolicy(policy), null, 2)}\n`, { mode: 0o600 });
  await chmod(`${file}.next`, 0o600);
  await rename(`${file}.next`, file);
}

/** Nova politica com a lista de um agente trocada (lista vazia remove o agente). */
export function withAgentModels(policy, agent, names) {
  if (!supportsModel(agent)) throw new HubError(400, `${agent} não aceita escolher o modelo; use claude, codex, copilot ou opencode`);
  const cleaned = [...new Set(names.map((item) => String(item ?? '').trim()).filter(Boolean))];
  const invalid = cleaned.filter((item) => !MODEL_NAME.test(item));
  if (invalid.length > 0) throw new HubError(400, `Nome de modelo inválido: ${invalid[0].slice(0, 40)}`);
  if (cleaned.length > MAX_MODELS) throw new HubError(400, `No máximo ${MAX_MODELS} modelos por agente`);
  const next = { ...policy };
  if (cleaned.length === 0) delete next[agent];
  else next[agent] = cleaned;
  return next;
}
