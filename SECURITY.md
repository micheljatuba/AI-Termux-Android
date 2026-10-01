# Politica de seguranca (Security policy)

*English summary: report vulnerabilities privately through GitHub's "Report a
vulnerability" form on the Security tab, not through public issues. The sections
below describe what this project does, what it does not do, and its known
security limitations.*

## Como reportar uma vulnerabilidade

**Nao abra uma issue publica com detalhes de uma vulnerabilidade.**

1. Abra a aba **Security** do repositorio e escolha **Report a vulnerability**
   (relato privado do GitHub):
   <https://github.com/micheljatuba/AI-Termux-Android/security/advisories/new>
2. Se essa opcao nao estiver disponivel, abra uma issue pedindo um canal
   privado, **sem** detalhes tecnicos, e aguarde contato.

Inclua a versao do Android e do Termux, o comando executado, o impacto esperado
e como reproduzir. Nunca inclua credenciais reais; use valores ficticios.

O projeto e mantido de forma voluntaria: nao ha prazo garantido de resposta, mas
relatos de seguranca tem prioridade sobre qualquer outra mudanca.

## Versoes suportadas

Somente o branch `main` (e a ultima versao marcada, quando existir) recebe
correcoes de seguranca.

## O que o projeto faz

- Instala as CLIs oficiais dos agentes em um Linux dedicado (`termux-ai`), sem
  root real no Android.
- Nao pede, le, copia nem envia suas credenciais. Cada agente guarda o proprio
  login dentro do Linux dedicado.
- Nao desativa sandboxes, nao habilita aprovacao irrestrita e nao abre acesso
  SSH/ADB.
- Nao sobrescreve comandos, Linux ou configuracoes de outra origem.
- Fixa as versoes do Codex, Copilot, Claude Code e OpenCode.

## Handoff entre aparelhos (experimental)

`ia handoff` e `ia continuar` movem **trabalho em andamento** entre aparelhos
usando um branch dedicado do seu repositorio privado no GitHub.

Garantias implementadas e cobertas por testes automatizados:

- So envia depois que o GitHub confirma que o repositorio e privado. Remoto
  publico, nao verificavel ou com credenciais na URL e recusado.
- Seu branch, arquivos e indice nao sao alterados. Os commits sao montados sem
  hooks; o envio usa `git push` normal, entao um hook `pre-push` seu, se existir, roda.
- Escreve somente em `refs/heads/ia/handoff/*`, em um branch novo, sem
  force-push. Um handoff existente nunca e sobrescrito.
- Nao envia `.env*`, chaves, `.npmrc`, `.netrc`, bancos locais, pastas de
  credenciais dos agentes (`.claude`, `.codex`, `.copilot`, `.gemini`,
  `.local/share/opencode`, `.config/gh`, `.ssh`, `.aws`) nem `node_modules`.
- Varre tokens e chaves de formato conhecido nos arquivos alterados, nos commits
  locais ainda nao publicados e na nota. Ao encontrar, aborta sem imprimir o
  valor.
- Limita o envio a 2000 arquivos e 5 MiB por arquivo.
- Ao continuar, recusa handoffs de outra identidade git, nao sobrescreve
  alteracoes pendentes nem branches locais, e trata a nota como dado. Exige
  identidade git configurada (`user.name` e `user.email`).

Limites que voce precisa conhecer:

- **A varredura e uma rede de seguranca, nao uma garantia.** Segredos sem formato
  conhecido (por exemplo, uma senha em texto comum) passam. Mantenha o
  `.gitignore` em dia e use um repositorio de teste primeiro.
- **A checagem de autoria protege contra engano, nao contra um colaborador
  mal-intencionado:** o e-mail do autor de um commit pode ser forjado por quem tem
  acesso de escrita. Trate um handoff como qualquer codigo vindo do repositorio:
  revise `git diff` e `git status` antes de executar ou pedir ao agente que execute.
- Repositorio privado nao significa que so voce enxerga: colaboradores e
  integracoes com acesso ao repositorio enxergam os branches `ia/handoff/*`.
  Apague-os quando nao precisar mais: `git push origin --delete ia/handoff/<aparelho>/<data>`.
- A confirmacao de visibilidade usa o GitHub CLI e o remoto `github.com`. Outros
  remotos exigem `--allow-unverified-remote`, por sua conta e risco.
- Ainda nao foi validado em Android/PRoot.

## Limitacoes conhecidas da instalacao

Descritas aqui para que voce possa decidir com informacao completa:

- **PRoot nao e um sandbox de seguranca.** Os agentes acessam os arquivos
  disponiveis ao Termux. Mantenha backups.
- **Claude Code:** o instalador baixa `https://claude.ai/install.sh` por HTTPS e
  o executa, pedindo uma versao fixa. Nao ha verificacao de hash desse script:
  a confianca esta no TLS e no dominio do fornecedor.
- **Antigravity:** a URL do pacote e restrita ao dominio oficial e o SHA-512 do
  manifesto e conferido com o binario. Manifesto e pacote vem da mesma origem:
  isso protege contra corrupcao e desvio de dominio, **nao** contra o
  comprometimento da propria origem.
- **Pacotes npm** (Codex, Copilot, OpenCode) usam versao fixa e a verificacao de
  integridade do registro npm, sem lockfile proprio.
- **Imagem base:** `node:24-bookworm-slim` e referenciada por tag, nao por
  digest.
- Atualizacoes dos fornecedores (`claude update`, `agy update`, `opencode upgrade`)
  executam codigo deles, fora do controle deste projeto.

## Boas praticas para quem usa

- Revise `install.sh` e `scripts/` antes de executar; clone o repositorio completo.
- Digite chaves somente no prompt oficial do agente. Nao as coloque em arquivos
  do projeto.
- Nao publique backups do Linux dedicado: eles podem conter credenciais.
- Use `ia handoff --dry-run` para ver exatamente o que seria enviado.
