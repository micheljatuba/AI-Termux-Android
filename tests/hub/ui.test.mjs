import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const page = (await readFile(new URL('../../scripts/hub/index.html', import.meta.url), 'utf8')).replaceAll('\r\n', '\n');
const scripts = [...page.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
const markup = page.replace(/<script\b[\s\S]*?<\/script>/g, '').replace(/<style\b[\s\S]*?<\/style>/g, '');
const code = scripts[0]?.[2] ?? '';

test('a página tem um único script e um único estilo, ambos com nonce', () => {
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0][1].trim(), 'nonce="__NONCE__"');
  assert.equal([...page.matchAll(/<style\b([^>]*)>/g)].map((match) => match[1].trim()).join('|'), 'nonce="__NONCE__"');
  assert.equal(page.split('__NONCE__').length - 1, 2, '__NONCE__ só pode aparecer nas duas tags');
});

test('o script da página compila', () => {
  assert.ok(code.length > 10_000);
  assert.doesNotThrow(() => new vm.Script(code, { filename: 'scripts/hub/index.html' }));
});

test('a página cabe na CSP: sem estilo ou evento inline e sem HTML dinâmico', () => {
  assert.doesNotMatch(markup, /\sstyle\s*=/i);
  assert.doesNotMatch(markup, /\son[a-z]+\s*=/i);
  assert.doesNotMatch(page, /javascript:/i);
  assert.doesNotMatch(code, /setAttribute\(\s*['"`]style['"`]/);
  assert.doesNotMatch(code, /\.(?:innerHTML|outerHTML)\b|insertAdjacentHTML|document\.write|\beval\(|new Function|srcdoc/);
  assert.doesNotMatch(code, /\.cssText\b|setAttribute\(\s*['"`]on/);
});

test('a página não depende de nada externo nem de caminhos absolutos', () => {
  const external = [...page.matchAll(/https?:\/\/[^\s'"`)<>]+/g)].map((match) => match[0]).filter((url) => url !== 'http://www.w3.org/2000/svg');
  assert.deepEqual(external, []);
  assert.doesNotMatch(code, /['"`]\/(?:api|t)\//, 'as chamadas precisam ser relativas ao token da URL');
  assert.doesNotMatch(markup, /(?:src|href|action)="\//);
});

test('todas as chamadas à API são relativas e ao menos as principais existem', () => {
  const calls = [...code.matchAll(/\bapi\(\s*'(GET|POST|DELETE)'\s*,\s*([`'])([^`']*)/g)].map((match) => `${match[1]} ${match[3]}`);
  assert.ok(calls.length >= 12, `esperava ao menos 12 chamadas, achei ${calls.length}`);
  for (const call of calls) assert.match(call, /^(?:GET|POST|DELETE) api\//, call);
  for (const wanted of ['GET api/state', 'GET api/previews', 'POST api/sessions', 'POST api/broadcast', 'POST api/runs', 'GET api/runs']) {
    assert.ok(calls.some((call) => call.startsWith(wanted)), `faltou ${wanted}`);
  }
});

test('os terminais usam o ttyd pelo caminho relativo t/ e uma sessão por iframe', () => {
  assert.match(code, /src:\s*`t\/\?arg=\$\{encodeURIComponent\(name\)\}`/);
});

test('todo $("#id") do script existe no HTML ou é criado pelo próprio script', () => {
  const declared = new Set([...markup.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
  for (const match of code.matchAll(/\bid:\s*'([^']+)'/g)) declared.add(match[1]);
  const used = new Set([...code.matchAll(/\$\('#([A-Za-z][\w-]*)'\)/g)].map((match) => match[1]));
  assert.ok(used.size >= 15);
  assert.deepEqual([...used].filter((id) => !declared.has(id)), []);
});

test('o aviso do tmux sem acesso aparece no banner da página', () => {
  assert.match(code, /function renderBanner\(\)[\s\S]*?S\.state\?\.tmuxError[\s\S]*?\n\}/);
});

test('o documento declara idioma, codificação e viewport para o tablet', () => {
  assert.match(page, /<html lang="pt-BR">/);
  assert.match(page, /<meta charset="utf-8">/i);
  assert.match(page, /<meta name="viewport" content="[^"]*width=device-width/);
  assert.match(page, /<title>[^<]*Painel<\/title>/);
});
