import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { KEYS, SESSION_NAME, Sessions, readMemInfo } from '../../scripts/hub/sessions.mjs';
import { HubError } from '../../scripts/hub/util.mjs';
import { createStubHome, hasCommand, waitUntil } from './helpers.mjs';

const CONFIG = fileURLToPath(new URL('../../scripts/hub/tmux.conf', import.meta.url));
const skip = hasCommand('tmux') ? false : 'tmux não está instalado';
let counter = 0;

async function setup(options = {}) {
  const stub = await createStubHome();
  const socket = `hubtest-${process.pid}-${Date.now().toString(36)}-${counter++}`;
  const make = (extra = {}) =>
    new Sessions({
      socket,
      config: CONFIG,
      maxSessions: 4,
      minFreeMb: 0,
      searchPath: stub.searchPath,
      env: stub.env,
      previewTtlMs: 0,
      ...options,
      ...extra,
    });
  const sessions = make();
  const screen = async (name, lines = 40) => (await sessions.peek(name, lines)).join('\n');
  return {
    stub,
    socket,
    sessions,
    make,
    screen,
    async cleanup() {
      spawnSync('tmux', ['-L', socket, 'kill-server'], { stdio: 'ignore' });
      await stub.cleanup();
    },
  };
}

const rejects = (promise, status, pattern) =>
  assert.rejects(promise, (error) => {
    assert.ok(error instanceof HubError, `esperava HubError, veio ${error}`);
    assert.equal(error.status, status, error.message);
    if (pattern) assert.match(error.message, pattern);
    return true;
  });

test('SESSION_NAME e KEYS: contrato com o servidor', () => {
  for (const ok of ['ia-claude-1', 'ia-agy-12', 'ia-shell-999', 'ia-opencode-3']) assert.ok(SESSION_NAME.test(ok), ok);
  for (const bad of ['ia-claude-1000', 'ia-claude', 'ia--1', 'ia-Claude-1', 'ia-claude-1\n', 'x-claude-1', 'ia-claude-1;', 'ia-cl aude-1']) assert.ok(!SESSION_NAME.test(bad), bad);
  assert.deepEqual(Object.keys(KEYS).sort(), ['1', '2', '3', 'C-c', 'Down', 'Enter', 'Escape', 'Left', 'Right', 'S-Tab', 'Tab', 'Up', 'n', 'y']);
});

test('readMemInfo lê /proc/meminfo e tolera arquivo ausente', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'hub-mem-'));
  try {
    const file = path.join(dir, 'meminfo');
    await writeFile(file, 'MemTotal:        8123456 kB\nMemFree:          100000 kB\nMemAvailable:    3145728 kB\n');
    assert.deepEqual(await readMemInfo(file), { totalMb: 7933, availableMb: 3072 });
    assert.deepEqual(await readMemInfo(path.join(dir, 'nao-existe')), { totalMb: 0, availableMb: 0 });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('sem servidor tmux a lista é vazia; sem o binário o erro é claro', { skip }, async () => {
  const env = await setup();
  try {
    assert.deepEqual(await env.sessions.list(), []);
    assert.equal(await env.sessions.killAll(), 0);
    await rejects(env.sessions.get('ia-claude-1'), 404);
    const broken = env.make({ tmux: '/nao/existe/tmux' });
    await rejects(broken.list(), 503, /tmux não encontrado/);
  } finally {
    await env.cleanup();
  }
});

test('criar: nome, metadados, pasta de trabalho e menor número livre', { skip }, async () => {
  const env = await setup();
  try {
    const first = await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    assert.deepEqual(
      { name: first.name, agent: first.agent, dir: first.dir, dead: first.dead, exitStatus: first.exitStatus },
      { name: 'ia-claude-1', agent: 'claude', dir: env.stub.work, dead: false, exitStatus: null },
    );
    const second = await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    const shell = await env.sessions.create({ agent: 'shell', dir: env.stub.work });
    assert.deepEqual([second.name, shell.name], ['ia-claude-2', 'ia-shell-1']);
    assert.deepEqual((await env.sessions.list()).map((session) => session.name), ['ia-claude-1', 'ia-claude-2', 'ia-shell-1']);

    await waitUntil(async () => (await env.screen('ia-claude-1')).includes(`PRONTO-claude dir=${env.stub.work}`), { message: 'o agente deveria abrir na pasta escolhida' });

    await env.sessions.kill('ia-claude-1');
    const reused = await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    assert.equal(reused.name, 'ia-claude-1', 'reaproveita o menor número livre');
    assert.deepEqual((await env.sessions.list()).map((session) => session.name), ['ia-claude-2', 'ia-shell-1', 'ia-claude-1'], 'a ordem segue a criação');
  } finally {
    await env.cleanup();
  }
});

test('criar em paralelo gera nomes distintos', { skip }, async () => {
  const env = await setup();
  try {
    const created = await Promise.all([1, 2, 3].map(() => env.sessions.create({ agent: 'codex', dir: env.stub.work })));
    assert.deepEqual(created.map((session) => session.name).sort(), ['ia-codex-1', 'ia-codex-2', 'ia-codex-3']);
  } finally {
    await env.cleanup();
  }
});

test('criar: agente desconhecido, ausente, limite de sessões e pouca memória', { skip }, async () => {
  const env = await setup({ maxSessions: 2 });
  try {
    await rejects(env.sessions.create({ agent: 'nada', dir: env.stub.work }), 400, /Agente desconhecido/);
    const missing = env.make({ searchPath: env.stub.bin });
    await rejects(missing.create({ agent: 'agy', dir: env.stub.work }), 400, /Antigravity não está instalado/);

    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await env.sessions.create({ agent: 'codex', dir: env.stub.work });
    await rejects(env.sessions.create({ agent: 'claude', dir: env.stub.work }), 409, /Limite de 2 sessões/);
    assert.equal((await env.sessions.list()).length, 2);

    const lowMemory = env.make({ maxSessions: 6, minFreeMb: 512, memInfo: async () => ({ totalMb: 4000, availableMb: 120 }) });
    await rejects(lowMemory.create({ agent: 'claude', dir: env.stub.work }), 503, /Pouca memória livre \(120 MB\)/);

    const unknownMemory = env.make({ maxSessions: 6, minFreeMb: 512, memInfo: async () => ({ totalMb: 0, availableMb: 0 }) });
    assert.equal((await unknownMemory.create({ agent: 'claude', dir: env.stub.work })).name, 'ia-claude-2');
  } finally {
    await env.cleanup();
  }
});

test('enviar texto: chega intacto (; aspas, crases, UTF-8, várias linhas) mesmo com LANG vazio', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));

    const samples = [
      'primeira linha; com ponto e vírgula;',
      'echo "aspas" $HOME `crase` \\ \'simples\' #hash && ls',
      'ação — ✓ 日本語 🎉',
      '-n --help -- ;',
    ];
    for (const text of samples) await env.sessions.send('ia-claude-1', text);
    await env.sessions.send('ia-claude-1', 'linha A\nlinha B\r\nlinha C');
    await waitUntil(async () => (await env.stub.readLog('claude')).includes('linha C'), { message: 'o texto deveria chegar ao agente' });

    const lines = (await env.stub.readLog('claude')).split('\n').filter(Boolean);
    assert.deepEqual(lines, [...samples, 'linha A', 'linha B', 'linha C']);
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('eco: ação — ✓ 日本語 🎉'), { message: 'o UTF-8 deve sobreviver ao tmux' });
  } finally {
    await env.cleanup();
  }
});

test('enviar remove ESC e outros controles: o texto não escapa da colagem nem vira teclas', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));
    // ESC [ 2 0 1 ~ encerra o "bracketed paste"; escondido dentro de outra sequência também seria remontado
    await env.sessions.send('ia-claude-1', 'antes\u001b[201~echo INJETADO\u001b[20\u001bM1~ depois\u0000\u0007\u007f');
    await waitUntil(async () => (await env.stub.readLog('claude')).includes('depois'), { message: 'o texto deveria chegar ao agente' });
    const log = await env.stub.readLog('claude');
    assert.equal(log, 'antes[201~echo INJETADO[20M1~ depois\n');
    assert.ok(!/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/.test(log), 'nenhum caractere de controle chegou ao agente');
  } finally {
    await env.cleanup();
  }
});

test('sem servidor tmux, ações sobre uma sessão inexistente respondem 404 (não erro interno)', { skip }, async () => {
  const env = await setup();
  try {
    assert.deepEqual(await env.sessions.list(), []);
    await rejects(env.sessions.kill('ia-claude-1'), 404, /Sessão não encontrada/);
    await rejects(env.sessions.peek('ia-claude-1'), 404, /Sessão não encontrada/);
    await rejects(env.sessions.restart('ia-claude-1'), 404);
    await rejects(env.sessions.send('ia-claude-1', 'oi'), 404);
    await rejects(env.sessions.key('ia-claude-1', 'Enter'), 404);
    assert.deepEqual(await env.sessions.peekAll(), {});
  } finally {
    await env.cleanup();
  }
});

test('enviar sem Enter só cola; a tecla Enter confirma', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));
    await env.sessions.send('ia-claude-1', 'rascunho', { enter: false });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('rascunho'), { message: 'o rascunho aparece no terminal' });
    assert.equal(await env.stub.readLog('claude'), '', 'nada foi enviado ao agente ainda');
    await env.sessions.key('ia-claude-1', 'Enter');
    await waitUntil(async () => (await env.stub.readLog('claude')).trim() === 'rascunho');
    await env.sessions.send('ia-claude-1', '', { enter: true });
    await waitUntil(async () => (await env.stub.readLog('claude')) === 'rascunho\n\n');
  } finally {
    await env.cleanup();
  }
});

test('enviar e teclas validam entrada e destino', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await rejects(env.sessions.send('ia-claude-1', '', { enter: false }), 400, /Nada para enviar/);
    await rejects(env.sessions.send('ia-claude-1', 'x'.repeat(65 * 1024)), 413);
    await rejects(env.sessions.send('ia-nada-1', 'oi'), 404, /Sessão não encontrada/);
    await rejects(env.sessions.send('claude; rm -rf /', 'oi'), 400, /Nome de sessão inválido/);
    await rejects(env.sessions.send('../ia-claude-1', 'oi'), 400);
    await rejects(env.sessions.key('ia-claude-1', 'C-d'), 400, /Tecla não permitida/);
    await rejects(env.sessions.key('ia-claude-1', 'send-keys'), 400);
    for (const inherited of ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf']) {
      await rejects(env.sessions.key('ia-claude-1', inherited), 400, /Tecla não permitida/);
    }
    await rejects(env.sessions.key('ia-nada-1', 'Enter'), 404);
    await rejects(env.sessions.kill('ia-nada-1'), 404);
    await rejects(env.sessions.kill('x'), 400);
    await rejects(env.sessions.restart('ia-nada-1'), 404);
    await rejects(env.sessions.peek('x'), 400);
    await rejects(env.sessions.peek('ia-nada-1'), 404);
    assert.equal(await env.stub.readLog('claude'), '');
  } finally {
    await env.cleanup();
  }
});

test('Ctrl+C interrompe o agente e a sessão fica "encerrada" até reiniciar', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));
    await env.sessions.key('ia-claude-1', 'C-c');
    const dead = await waitUntil(async () => {
      const found = await env.sessions.get('ia-claude-1');
      return found.dead ? found : null;
    }, { message: 'a sessão deveria ficar encerrada' });
    assert.equal(dead.dead, true);
    await env.sessions.restart('ia-claude-1');
    const alive = await waitUntil(async () => {
      const found = await env.sessions.get('ia-claude-1');
      return found.dead ? null : found;
    });
    assert.equal(alive.exitStatus, null);
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));
  } finally {
    await env.cleanup();
  }
});

test('quando o agente sai, o código de saída é informado e reiniciar recomeça', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('PRONTO-claude'));
    await env.sessions.send('ia-claude-1', '/sair');
    // Sob carga o tmux pode perder o SIGCHLD do painel; o hub reenvia o sinal ao servidor até o código de saída aparecer.
    const ended = await waitUntil(async () => {
      const found = await env.sessions.get('ia-claude-1');
      return found.dead && found.exitStatus !== null ? found : null;
    }, { message: 'o agente deveria encerrar com um código de saída' });
    assert.equal(ended.exitStatus, 3);

    await env.sessions.restart('ia-claude-1');
    const again = await waitUntil(async () => {
      const found = await env.sessions.get('ia-claude-1');
      return found.dead ? null : found;
    });
    assert.equal(again.agent, 'claude');
    assert.equal(again.dir, env.stub.work);
    await env.sessions.send('ia-claude-1', 'depois do reinício');
    await waitUntil(async () => (await env.stub.readLog('claude')).includes('depois do reinício'));
  } finally {
    await env.cleanup();
  }
});

// tmux de mentira: ignora os argumentos e imprime uma listagem fixa no formato de LIST_FORMAT.
async function withFakeTmux(rows, fn) {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'hub-fake-tmux-'));
  try {
    const listing = path.join(dir, 'listing.tsv');
    await writeFile(listing, `${rows.map((row) => row.join('\t')).join('\n')}\n`);
    const bin = path.join(dir, 'tmux');
    await writeFile(bin, `#!/bin/sh\ncat '${listing}'\n`, { mode: 0o755 });
    return await fn(bin);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

const fakeRow = (name, { dead = 0, status = '', signal = '', pid = 4242 } = {}) => [name, dead, status, signal, 100, 100, 'claude', '/tmp', '$0', pid];

async function killsDuring(fn) {
  const original = process.kill;
  const calls = [];
  process.kill = (pid, signal) => {
    calls.push([pid, signal]);
    return true;
  };
  try {
    await fn();
  } finally {
    process.kill = original;
  }
  return calls;
}

const skipFake = process.platform === 'win32' ? 'precisa de /bin/sh' : false;

test('painel encerrado sem código nem sinal: o servidor tmux recebe SIGCHLD para recolher o zumbi', { skip: skipFake }, async () => {
  await withFakeTmux([fakeRow('ia-claude-1', { dead: 1 })], async (tmux) => {
    const sessions = new Sessions({ tmux, reapIntervalMs: 60_000 });
    const calls = await killsDuring(async () => {
      const [found] = await sessions.list();
      assert.equal(found.dead, true);
      assert.equal(found.exitStatus, null);
      await sessions.list();
    });
    assert.deepEqual(calls, [[4242, 'SIGCHLD']], 'um único SIGCHLD dentro do intervalo');
  });
});

test('SIGCHLD só é enviado quando falta o código de saída e não há sinal', { skip: skipFake }, async () => {
  const rows = [fakeRow('ia-claude-1'), fakeRow('ia-claude-2', { dead: 1, status: 3 }), fakeRow('ia-claude-3', { dead: 1, signal: 'SIGKILL' })];
  await withFakeTmux(rows, async (tmux) => {
    const calls = await killsDuring(async () => {
      const found = await new Sessions({ tmux, reapIntervalMs: 0 }).list();
      assert.deepEqual(found.map((session) => [session.dead, session.exitStatus]), [[false, null], [true, 3], [true, null]]);
    });
    assert.deepEqual(calls, []);
  });
});

test('PID de servidor inválido nunca vira alvo de kill', { skip: skipFake }, async () => {
  for (const pid of ['', '0', '1', '-5', 'abc', '1.5']) {
    await withFakeTmux([fakeRow('ia-claude-1', { dead: 1, pid })], async (tmux) => {
      const calls = await killsDuring(async () => {
        await new Sessions({ tmux, reapIntervalMs: 0 }).list();
      });
      assert.deepEqual(calls, [], `pid "${pid}"`);
    });
  }
});

test('prévia: últimas linhas sem espaços finais, cache curto e peekAll', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await env.sessions.create({ agent: 'codex', dir: env.stub.work });
    await env.sessions.send('ia-claude-1', 'um');
    await env.sessions.send('ia-claude-1', 'dois');
    await env.sessions.send('ia-claude-1', 'três');
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('eco: três'));

    const last = await env.sessions.peek('ia-claude-1', 2);
    assert.equal(last.length, 2);
    assert.equal(last.at(-1), 'eco: três');
    assert.ok(last.every((line) => line === line.trimEnd() && line.length > 0));

    const all = await env.sessions.peekAll(3);
    assert.deepEqual(Object.keys(all).sort(), ['ia-claude-1', 'ia-codex-1']);
    assert.ok(all['ia-claude-1'].length <= 3);
    assert.match(all['ia-codex-1'].join('\n'), /PRONTO-codex/);

    const cached = env.make({ previewTtlMs: 60000 });
    const before = await cached.peek('ia-claude-1', 40);
    await env.sessions.send('ia-claude-1', 'quatro');
    await waitUntil(async () => (await env.screen('ia-claude-1')).includes('eco: quatro'));
    assert.deepEqual(await cached.peek('ia-claude-1', 40), before, 'a prévia em cache não muda dentro do TTL');
    assert.ok((await env.make().peek('ia-claude-1', 40)).includes('eco: quatro'));
  } finally {
    await env.cleanup();
  }
});

test('encerrar e encerrar tudo', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'claude', dir: env.stub.work });
    await env.sessions.create({ agent: 'codex', dir: env.stub.work });
    await env.sessions.create({ agent: 'shell', dir: env.stub.work });
    await env.sessions.kill('ia-codex-1');
    assert.deepEqual((await env.sessions.list()).map((session) => session.name), ['ia-claude-1', 'ia-shell-1']);
    assert.equal(await env.sessions.killAll(), 2);
    assert.deepEqual(await env.sessions.list(), []);
  } finally {
    await env.cleanup();
  }
});

test('a configuração do painel é aplicada ao servidor tmux dedicado', { skip }, async () => {
  const env = await setup();
  try {
    await env.sessions.create({ agent: 'shell', dir: env.stub.work });
    const show = (option) =>
      spawnSync('tmux', ['-L', env.socket, 'show-options', '-gv', option], { encoding: 'utf8', env: env.stub.env }).stdout.trim();
    assert.equal(show('remain-on-exit'), 'on');
    assert.equal(show('status'), 'off');
    assert.equal(show('mouse'), 'on');
    assert.equal(show('history-limit'), '20000');
    assert.equal(show('set-clipboard'), 'off');
  } finally {
    await env.cleanup();
  }
});
