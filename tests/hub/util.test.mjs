import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  HubError,
  Semaphore,
  clampInt,
  randomId,
  resolveWithin,
  stripAnsi,
  stripControls,
  truncateBytes,
  writeJsonAtomic,
} from '../../scripts/hub/util.mjs';

const CONTROL_CHARACTER = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/;

async function tempDir() {
  return mkdtemp(path.join(os.tmpdir(), 'hub-util-'));
}

test('stripAnsi remove cores e simula retorno de carro', () => {
  assert.equal(stripAnsi('\u001b[31mvermelho\u001b[0m normal'), 'vermelho normal');
  assert.equal(stripAnsi('10%\r50%\r100%\nfim'), '100%\nfim');
  assert.equal(stripAnsi('a\r\nb'), 'a\nb');
  assert.equal(stripAnsi('\u001b]0;titulo\u0007texto'), 'texto');
  assert.equal(stripAnsi('\u001b[?25l\u001b[2Kok'), 'ok');
});

test('stripAnsi não deixa sequências formadas por aninhamento nem controles soltos', () => {
  // ESC [ 2 0 ESC M 1 ~ : ao tirar "ESC M" sobra "ESC [ 2 0 1 ~", que é o fim do bracketed paste
  assert.equal(stripAnsi('\u001b[20\u001bM1~'), '');
  assert.equal(stripAnsi('a\u001b[20\u001b[20\u001bM1~1~b'), 'ab');

  const levels = 12;
  const deep = `x${'\u001b[20'.repeat(levels)}\u001bM${'1~'.repeat(levels)}y`;
  const cleaned = stripAnsi(deep);
  assert.ok(!CONTROL_CHARACTER.test(cleaned), 'nenhum ESC pode sobrar, mesmo acima do limite de passadas');
  assert.ok(cleaned.startsWith('x') && cleaned.endsWith('y'));

  assert.equal(stripAnsi('ok\u0000\u0007\u007f\u0085!\ttab\nlinha'), 'ok!\ttab\nlinha');
});

test('stripControls tira ESC e demais controles, mas preserva tab e quebra de linha', () => {
  assert.equal(stripControls('a\u001b[201~b\tc\nd\u0000\u0007\u007f\u0085e'), 'a[201~b\tc\nde');
  assert.equal(stripControls('texto comum com acentuação: ação'), 'texto comum com acentuação: ação');
  assert.equal(stripControls(42), '42');
});

test('truncateBytes respeita o limite sem cortar caracteres UTF-8', () => {
  assert.equal(truncateBytes('curto', 100), 'curto');
  const cut = truncateBytes('á'.repeat(100), 51);
  assert.ok(Buffer.byteLength(cut) <= 51, `ficou com ${Buffer.byteLength(cut)} bytes`);
  assert.ok(cut.endsWith('[... truncado ...]'));
  assert.ok(!cut.includes('\uFFFD'));
});

test('clampInt limita e usa o valor padrão', () => {
  assert.equal(clampInt('5', 1, 10, 3), 5);
  assert.equal(clampInt('99', 1, 10, 3), 10);
  assert.equal(clampInt('-4', 1, 10, 3), 1);
  assert.equal(clampInt('abc', 1, 10, 3), 3);
  assert.equal(clampInt(undefined, 1, 10, 3), 3);
});

test('randomId gera ids ordenáveis por data', () => {
  const a = randomId(new Date(2026, 0, 2, 3, 4, 5));
  const b = randomId(new Date(2026, 0, 2, 3, 4, 6));
  assert.match(a, /^20260102-030405-[0-9a-f]{6}$/);
  assert.ok(a < b);
});

test('writeJsonAtomic grava JSON completo e não deixa temporários', async () => {
  const dir = await tempDir();
  try {
    const file = path.join(dir, 'x.json');
    await writeJsonAtomic(file, { ok: true });
    await writeJsonAtomic(file, { ok: false, lista: [1, 2] });
    assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), { ok: false, lista: [1, 2] });
    assert.deepEqual(await readdir(dir), ['x.json']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

const WINDOWS_RENAME = process.platform === 'win32' ? 'rename concorrente sobre o mesmo destino falha com EPERM no Windows; o painel roda em Linux/Termux' : false;

test('writeJsonAtomic aguenta gravações simultâneas no mesmo arquivo', { skip: WINDOWS_RENAME }, async () => {
  const dir = await tempDir();
  try {
    const file = path.join(dir, 'x.json');
    const payloads = Array.from({ length: 30 }, (_, n) => ({ n, texto: 'ç'.repeat(2000) }));
    await Promise.all(payloads.map((payload) => writeJsonAtomic(file, payload)));
    const final = JSON.parse(await readFile(file, 'utf8'));
    assert.ok(payloads.some((payload) => payload.n === final.n), 'o arquivo final é uma das gravações, inteira');
    assert.equal(final.texto.length, 2000);
    assert.deepEqual(await readdir(dir), ['x.json'], 'nenhum temporário sobra');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('writeJsonAtomic limpa o temporário quando a gravação falha', async () => {
  const dir = await tempDir();
  try {
    await assert.rejects(writeJsonAtomic(path.join(dir, 'nao-existe', 'x.json'), { ok: true }));
    const cyclic = {};
    cyclic.self = cyclic;
    await assert.rejects(writeJsonAtomic(path.join(dir, 'x.json'), cyclic), TypeError);
    assert.deepEqual(await readdir(dir), []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('resolveWithin aceita subpastas e recusa fugas da raiz', async (t) => {
  const dir = await tempDir();
  try {
    const root = path.join(dir, 'raiz');
    await mkdir(path.join(root, 'a', 'b'), { recursive: true });
    await mkdir(path.join(dir, 'fora'));
    await writeFile(path.join(root, 'arquivo.txt'), 'x');

    assert.equal(await resolveWithin(root, '.'), await resolveWithin(root, root));
    assert.ok((await resolveWithin(root, 'a/b')).endsWith(path.join('a', 'b')));
    assert.ok((await resolveWithin(root, path.join(root, 'a'))).endsWith(`${path.sep}a`));

    await assert.rejects(resolveWithin(root, '..'), (error) => error instanceof HubError && error.status === 400);
    await assert.rejects(resolveWithin(root, path.join(dir, 'fora')), /fora da raiz/);
    await assert.rejects(resolveWithin(root, 'a/../../fora'), /fora da raiz/);
    await assert.rejects(resolveWithin(root, 'nao-existe'), /não encontrada/);
    await assert.rejects(resolveWithin(root, 'arquivo.txt'), /não é uma pasta/);

    try {
      await symlink(path.join(dir, 'fora'), path.join(root, 'atalho'), 'junction');
    } catch {
      t.diagnostic('sem permissão para criar links simbólicos; verificação de atalho ignorada');
      return;
    }
    await assert.rejects(resolveWithin(root, 'atalho'), /fora da raiz/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('Semaphore limita a concorrência e libera em caso de erro', async () => {
  const semaphore = new Semaphore(2);
  let running = 0;
  let peak = 0;
  const task = (fail) => async () => {
    running += 1;
    peak = Math.max(peak, running);
    await new Promise((resolve) => setTimeout(resolve, 15));
    running -= 1;
    if (fail) throw new Error('falha');
  };
  const results = await Promise.allSettled([1, 2, 3, 4, 5, 6].map((n) => semaphore.run(task(n === 3))));
  assert.equal(peak, 2);
  assert.equal(results.filter((item) => item.status === 'rejected').length, 1);
  assert.equal(semaphore.active, 0);
});

test('Semaphore.acquire com signal: quem desiste sai da fila sem ocupar vaga', async () => {
  const semaphore = new Semaphore(1);
  await semaphore.acquire();
  const quitter = new AbortController();
  const reason = new Error('cancelado de propósito');
  const gaveUp = semaphore.acquire(quitter.signal);
  const patient = semaphore.acquire();
  assert.equal(semaphore.waiters.length, 2);

  quitter.abort(reason);
  await assert.rejects(gaveUp, (error) => error === reason);
  assert.equal(semaphore.waiters.length, 1, 'só o paciente continua na fila');
  assert.equal(semaphore.active, 1);

  semaphore.release();
  await patient;
  assert.equal(semaphore.active, 1, 'a vaga passou direto ao próximo da fila');
  semaphore.release();
  assert.equal(semaphore.active, 0);
  quitter.abort(new Error('de novo'));
  assert.equal(semaphore.active, 0, 'abortar depois de entrar não mexe no semáforo');
});

test('Semaphore.acquire com signal já cancelado rejeita sem consumir vaga', async () => {
  const semaphore = new Semaphore(1);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(semaphore.acquire(controller.signal), (error) => error === controller.signal.reason);
  assert.equal(semaphore.active, 0);
  assert.equal(semaphore.waiters.length, 0);

  await semaphore.acquire(new AbortController().signal);
  assert.equal(semaphore.active, 1, 'com um signal ainda não cancelado, a vaga é concedida normalmente');
  semaphore.release();
  assert.equal(semaphore.active, 0);
});
