import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { describeAgents } from '../../scripts/hub/agents.mjs';
import { HELP, run } from '../../scripts/hub/cli.mjs';
import { Orchestrator } from '../../scripts/hub/orchestrator.mjs';

const ok = (output) => ({ ok: true, output, error: '', code: 0, timedOut: false, cancelled: false, durationMs: 1500 });
const bad = (error) => ({ ok: false, output: '', error, code: 1, timedOut: false, cancelled: false, durationMs: 10 });

const NO_COLOR_ENV = { TERMUX_AI_HUB_STATE: '' };

async function setup({ installed = ['claude', 'copilot', 'codex'], handlers = {} } = {}) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'hub-cli-'));
  const work = path.join(base, 'work');
  await mkdir(work);
  const calls = [];
  const runAgent = async (call) => {
    calls.push(call);
    return (handlers[call.agent] ?? (() => ok(`resposta de ${call.agent}`)))(call);
  };
  const describe = () => describeAgents('').map((agent) => ({ ...agent, installed: agent.id === 'shell' || installed.includes(agent.id) }));
  const make = () => new Orchestrator({ dir: path.join(base, 'runs'), runAgent, installedAgents: () => installed, persistDelayMs: 5 });
  const call = async (argv, extra = {}) => {
    let out = '';
    let err = '';
    const code = await run(argv, {
      out: { write: (text) => (out += text) },
      err: { write: (text) => (err += text) },
      readInput: async () => '',
      stdinIsTTY: true,
      env: NO_COLOR_ENV,
      cwd: work,
      orchestrator: make(),
      describe,
      signals: new EventEmitter(),
      ...extra,
    });
    return { code, out, err };
  };
  return { base, work, calls, call, cleanup: () => rm(base, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }) };
}

test('ajuda: sem argumentos, --ajuda, --help e ajuda mostram o uso e saem com 0', async () => {
  const env = await setup();
  try {
    for (const argv of [[], ['--ajuda'], ['--help'], ['-h'], ['ajuda'], ['help'], ['comparar', '-h'], ['comparar', '--help']]) {
      const result = await env.call(argv);
      assert.equal(result.code, 0, argv.join(' '));
      assert.equal(result.out.trim(), HELP.trim());
    }
    assert.match(HELP, /SOMENTE LEITURA/);
  } finally {
    await env.cleanup();
  }
});

test('opções e comandos inválidos saem com código 2 e uma dica', async () => {
  const env = await setup();
  try {
    const option = await env.call(['comparar', '--nada']);
    assert.equal(option.code, 2);
    assert.match(option.err, /Erro: /);
    assert.match(option.err, /ia orquestrar --ajuda/);

    const command = await env.call(['fazer']);
    assert.equal(command.code, 2);
    assert.match(command.err, /Comando desconhecido: fazer/);

    const missing = await env.call(['comparar', '-a']);
    assert.equal(missing.code, 2);
  } finally {
    await env.cleanup();
  }
});

test('agentes: lista o catálogo com o que cada um pode fazer', async () => {
  const env = await setup({ installed: ['claude', 'hermes'] });
  try {
    const result = await env.call(['agentes']);
    assert.equal(result.code, 0);
    const lines = result.out.split('\n');
    assert.match(lines[0], /somente leitura/);
    const claude = lines.find((line) => line.trim().startsWith('claude'));
    const hermes = lines.find((line) => line.trim().startsWith('hermes'));
    const copilot = lines.find((line) => line.trim().startsWith('copilot'));
    assert.match(claude, /instalado\s+lê arquivos/);
    assert.match(hermes, /instalado\s+sem acesso a arquivos/);
    assert.match(copilot, /não instalado/);
    assert.ok(!lines.some((line) => line.trim().startsWith('shell')));
  } finally {
    await env.cleanup();
  }
});

test('comparar: usa os agentes instalados, o juiz "auto" e imprime só o resultado final no stdout', async () => {
  const env = await setup({
    handlers: { claude: ({ prompt }) => ok(prompt.includes('Veredito') || prompt.includes('juiz') ? 'VEREDITO FINAL' : 'resposta A') },
  });
  try {
    const result = await env.call(['comparar', '-j', 'auto', 'Onde', 'fica', 'o', 'login?']);
    assert.equal(result.code, 0, result.err);
    assert.equal(result.out.trim(), 'VEREDITO FINAL');
    assert.match(result.err, /Execução \d{8}-\d{6}-[0-9a-f]{6} \(comparar, somente leitura\)/);
    assert.match(result.err, /✓ Claude Code — concluído/);
    assert.match(result.err, /✓ Juiz · Claude Code — concluído/);
    assert.match(result.err, /ia orquestrar ver \d{8}/);
    assert.deepEqual([...new Set(env.calls.map((call) => call.agent))].sort(), ['claude', 'codex', 'copilot']);
    assert.ok(env.calls.every((call) => call.dir === env.work));
    assert.ok(env.calls[0].prompt.includes('Onde fica o login?'));
    assert.ok(env.calls.every((call) => call.timeoutMs === 600000));
  } finally {
    await env.cleanup();
  }
});

test('comparar sem juiz imprime cada resposta e o Hermes só entra se for pedido', async () => {
  const env = await setup({ installed: ['claude', 'copilot', 'hermes'] });
  try {
    const plain = await env.call(['comparar', 'Tarefa simples']);
    assert.equal(plain.code, 0, plain.err);
    assert.match(plain.out, /## Claude Code\n\nresposta de claude/);
    assert.match(plain.out, /## GitHub Copilot\n\nresposta de copilot/);
    assert.ok(!env.calls.some((call) => call.agent === 'hermes'));

    const withHermes = await env.call(['comparar', '-a', 'claude,hermes', 'Tarefa simples']);
    assert.equal(withHermes.code, 0, withHermes.err);
    assert.ok(env.calls.some((call) => call.agent === 'hermes'));
  } finally {
    await env.cleanup();
  }
});

test('tarefa pela entrada padrão: "-" e entrada redirecionada', async () => {
  const env = await setup();
  try {
    const dash = await env.call(['comparar', '-a', 'claude,copilot', '-'], { readInput: async () => '  diff muito grande\n' });
    assert.equal(dash.code, 0, dash.err);
    assert.ok(env.calls[0].prompt.includes('diff muito grande'));

    const piped = await env.call(['comparar', '-a', 'claude,copilot'], { stdinIsTTY: false, readInput: async () => 'vinda do pipe' });
    assert.equal(piped.code, 0, piped.err);
    assert.ok(env.calls.at(-1).prompt.includes('vinda do pipe'));

    const empty = await env.call(['comparar', '-a', 'claude,copilot', '-'], { readInput: async () => '   \n' });
    assert.equal(empty.code, 2);
    assert.match(empty.err, /informe a tarefa/);

    const none = await env.call(['comparar', '-a', 'claude,copilot']);
    assert.equal(none.code, 2);
    assert.match(none.err, /informe a tarefa/);
  } finally {
    await env.cleanup();
  }
});

test('pasta de trabalho: resolvida a partir do cwd e validada', async () => {
  const env = await setup();
  try {
    await mkdir(path.join(env.work, 'sub'));
    const relative = await env.call(['comparar', '-a', 'claude,copilot', '-d', 'sub', 'x']);
    assert.equal(relative.code, 0, relative.err);
    assert.equal(env.calls[0].dir, path.join(env.work, 'sub'));

    const missing = await env.call(['comparar', '-a', 'claude,copilot', '-d', 'nao-existe', 'x']);
    assert.equal(missing.code, 2);
    assert.match(missing.err, /pasta não encontrada/);
  } finally {
    await env.cleanup();
  }
});

test('pipeline: etapas padrão em rodízio e etapas personalizadas', async () => {
  const env = await setup();
  try {
    const standard = await env.call(['pipeline', 'Criar cache']);
    assert.equal(standard.code, 0, standard.err);
    assert.deepEqual(env.calls.map((call) => call.agent), ['claude', 'copilot', 'codex']);
    assert.match(standard.err, /1\. Planejar · Claude Code/);
    assert.match(standard.err, /3\. Revisar · Codex/);
    assert.equal(standard.out.trim(), 'resposta de codex');

    env.calls.length = 0;
    const custom = await env.call(['pipeline', '-e', 'planejar:claude,revisar:copilot', 'Criar cache']);
    assert.equal(custom.code, 0, custom.err);
    assert.deepEqual(env.calls.map((call) => call.agent), ['claude', 'copilot']);
    assert.match(custom.err, /2\. Revisar · GitHub Copilot/);

    env.calls.length = 0;
    const loose = await env.call(['pipeline', '-e', 'claude,copilot,codex', 'Criar cache']);
    assert.equal(loose.code, 0, loose.err);
    assert.match(loose.err, /1\. Planejar · Claude Code/);
    assert.match(loose.err, /2\. Propor implementação · GitHub Copilot/);
    assert.match(loose.err, /3\. Revisar · Codex/);

    const invalid = await env.call(['pipeline', '-e', 'testar:claude,revisar:copilot', 'x']);
    assert.equal(invalid.code, 2);
    assert.match(invalid.err, /Etapa inválida "testar:claude"/);
  } finally {
    await env.cleanup();
  }
});

test('maestro: coordenador, número máximo de tarefas e integração', async () => {
  const plan = JSON.stringify({ tarefas: [{ agente: 'copilot', titulo: 'Riscos', prompt: 'Liste os riscos' }, { agente: 'claude', titulo: 'Mapa', prompt: 'Liste os arquivos' }] });
  const env = await setup({
    handlers: {
      codex: ({ prompt }) => (prompt.includes('maestro de uma equipe') ? ok(plan) : ok('RELATÓRIO INTEGRADO')),
    },
  });
  try {
    const result = await env.call(['maestro', '-a', 'claude,copilot,codex', '-c', 'codex', '-n', '2', 'Mapear', 'o', 'projeto']);
    assert.equal(result.code, 0, result.err);
    assert.equal(result.out.trim(), 'RELATÓRIO INTEGRADO');
    assert.match(result.err, /Plano · Codex/);
    assert.match(result.err, /Integração · Codex/);
    assert.deepEqual(env.calls.map((call) => call.agent).sort(), ['claude', 'codex', 'codex', 'copilot']);
  } finally {
    await env.cleanup();
  }
});

test('validações do orquestrador viram erros claros (código 2)', async () => {
  const env = await setup({ installed: ['claude'] });
  try {
    const few = await env.call(['comparar', 'x']);
    assert.equal(few.code, 2);
    assert.match(few.err, /pelo menos 2 agentes/);

    const missing = await env.call(['comparar', '-a', 'claude,agy', 'x']);
    assert.equal(missing.code, 2);
    assert.match(missing.err, /Antigravity não está instalado/);

    const unknown = await env.call(['comparar', '-a', 'claude,nada', 'x']);
    assert.equal(unknown.code, 2);
    assert.match(unknown.err, /desconhecido: nada/);

    const empty = await env.call(['comparar', '-a', ' , ', 'x']);
    assert.equal(empty.code, 2);
    assert.match(empty.err, /lista de agentes está vazia/);
  } finally {
    await env.cleanup();
  }

  const none = await setup({ installed: [] });
  try {
    const result = await none.call(['comparar', 'x']);
    assert.equal(result.code, 2);
    assert.match(result.err, /Nenhum agente instalado/);
  } finally {
    await none.cleanup();
  }
});

test('execução com erro sai com 1 e mostra as respostas parciais', async () => {
  const env = await setup({
    handlers: {
      claude: () => ok('resposta parcial do Claude'),
      copilot: () => ok('resposta parcial do Copilot'),
      codex: () => bad('sem rede'),
      agy: () => bad('cota esgotada'),
    },
  });
  try {
    const result = await env.call(['comparar', '-a', 'claude,copilot', '-j', 'codex', 'x']);
    assert.equal(result.code, 1);
    assert.match(result.err, /Erro: O juiz falhou: sem rede/);
    assert.match(result.err, /Respostas parciais recebidas/);
    assert.match(result.out, /## Claude Code\n\nresposta parcial do Claude/);
    assert.match(result.out, /## GitHub Copilot\n\nresposta parcial do Copilot/);

    const total = await env.call(['pipeline', '-e', 'planejar:codex,revisar:claude', 'x']);
    assert.equal(total.code, 1);
    assert.equal(total.out, '');
    assert.match(total.err, /Erro: Etapa "1\. Planejar · Codex" falhou: sem rede/);
  } finally {
    await env.cleanup();
  }

  const partial = await setup({ installed: ['claude', 'copilot', 'agy'], handlers: { claude: () => ok('só o Claude respondeu'), agy: () => bad('cota esgotada') } });
  try {
    const result = await partial.call(['comparar', '-a', 'claude,agy', 'x']);
    assert.equal(result.code, 0, 'basta um agente responder');
    assert.match(result.err, /✗ Antigravity — erro: cota esgotada/);
    assert.match(result.out, /só o Claude respondeu/);
  } finally {
    await partial.cleanup();
  }
});

test('--json imprime a execução completa e nada além disso no stdout', async () => {
  const env = await setup();
  try {
    const result = await env.call(['comparar', '--json', '-a', 'claude,copilot', 'x']);
    assert.equal(result.code, 0, result.err);
    const parsed = JSON.parse(result.out);
    assert.equal(parsed.mode, 'compare');
    assert.equal(parsed.status, 'done');
    assert.equal(parsed.steps.length, 2);
  } finally {
    await env.cleanup();
  }
});

test('Ctrl+C e o fechamento do terminal cancelam a execução e saem com 130', async () => {
  const handlers = {
    claude: ({ signal }) => new Promise((resolve) => signal.addEventListener('abort', () => resolve({ ...bad('Cancelado'), cancelled: true }), { once: true })),
    copilot: ({ signal }) => new Promise((resolve) => signal.addEventListener('abort', () => resolve({ ...bad('Cancelado'), cancelled: true }), { once: true })),
  };
  const env = await setup({ handlers });
  try {
    for (const name of ['SIGINT', 'SIGHUP']) {
      const signals = new EventEmitter();
      const pending = env.call(['comparar', '-a', 'claude,copilot', 'x'], { signals });
      for (let attempt = 0; attempt < 100 && signals.listenerCount(name) === 0; attempt += 1) await new Promise((resolve) => setTimeout(resolve, 10));
      assert.equal(signals.listenerCount(name), 1, name);
      signals.emit(name);
      const result = await pending;
      assert.equal(result.code, 130, name);
      assert.match(result.err, /Cancelando…/);
      assert.match(result.err, /cancelada/);
      for (const other of ['SIGINT', 'SIGTERM', 'SIGHUP']) assert.equal(signals.listenerCount(other), 0, `${name}: ${other}`);
    }
  } finally {
    await env.cleanup();
  }
});

test('historico e ver: encontra por ID completo, trecho e mostra cada etapa', async () => {
  const env = await setup();
  try {
    const empty = await env.call(['historico']);
    assert.equal(empty.code, 0);
    assert.match(empty.out, /Nenhuma execução ainda/);

    const first = await env.call(['comparar', '-a', 'claude,copilot', 'primeira tarefa']);
    const id = first.err.match(/Execução (\d{8}-\d{6}-[0-9a-f]{6})/)[1];
    await new Promise((resolve) => setTimeout(resolve, 5));

    const list = await env.call(['historico']);
    assert.equal(list.code, 0);
    assert.match(list.out, /ID\s+MODO\s+STATUS\s+QUANDO\s+TAREFA/);
    assert.match(list.out, new RegExp(`${id}\\s+comparar\\s+concluída\\s+\\d{2}/\\d{2} \\d{2}:\\d{2}\\s+primeira tarefa`));

    const byPartial = await env.call(['ver', id.slice(-6)]);
    assert.equal(byPartial.code, 0);
    assert.match(byPartial.out, /## Claude Code/);
    assert.match(byPartial.err, new RegExp(`${id} · comparar · concluída`));

    const everything = await env.call(['ver', id, '--tudo']);
    assert.match(everything.out, /=== Claude Code \(concluído, 2 s\) ===\nresposta de claude/);
    assert.match(everything.out, /=== GitHub Copilot \(concluído/);

    const asJson = await env.call(['ver', id, '--json']);
    assert.equal(JSON.parse(asJson.out).id, id);

    const absent = await env.call(['ver', '19990101-000000-abcdef']);
    assert.equal(absent.code, 2);
    assert.match(absent.err, /Execução não encontrada/);

    const noId = await env.call(['ver']);
    assert.equal(noId.code, 2);
    assert.match(noId.err, /Informe o ID/);
  } finally {
    await env.cleanup();
  }
});

test('ver: ID ambíguo lista as opções e execução com erro sai com 1', async () => {
  const env = await setup({ handlers: { claude: () => bad('falhou'), copilot: () => bad('falhou') } });
  try {
    const one = await env.call(['comparar', '-a', 'claude,copilot', 'a']);
    assert.equal(one.code, 1);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    const two = await env.call(['comparar', '-a', 'claude,copilot', 'b']);
    assert.equal(two.code, 1);
    const ids = [one, two].map((item) => item.err.match(/Execução (\d{8}-\d{6}-[0-9a-f]{6})/)[1]);

    const ambiguous = await env.call(['ver', ids[0].slice(0, 8)]);
    assert.equal(ambiguous.code, 2);
    assert.match(ambiguous.err, /ID ambíguo/);
    assert.ok(ambiguous.err.includes(ids[0]) && ambiguous.err.includes(ids[1]));

    const failed = await env.call(['ver', ids[0]]);
    assert.equal(failed.code, 1);
    assert.match(failed.out, /Nenhum agente respondeu/);
  } finally {
    await env.cleanup();
  }
});
