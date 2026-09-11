# Termux AI

Instalador de GitHub Copilot CLI, Claude Code e Codex para Termux no Android.
O comando `ia` abre um menu; `copilot`, `claude` e `codex` abrem cada agente.
O uso diario nao depende de PC, cabo USB, depuracao USB ou root.

**Nao e Windows, nao funciona no iOS e nao promete compatibilidade com qualquer
celular ou qualquer agente.** Os modelos em nuvem exigem internet e contas com
acesso aos respectivos servicos. Este projeto nao inclui assinaturas ou creditos.

## Compatibilidade

| Ambiente | Situacao |
| --- | --- |
| Android 11+, Termux ARM64 | Alvo principal; instalacao limpa ainda precisa de validacao em aparelho |
| Android 11+, Termux x86_64 | Aceito pela pre-verificacao; nao testado em aparelho |
| Google Play | Apenas o Termux oficial; precisa oferecer PRoot-Distro 5.3.0+ |
| F-Droid ou releases oficiais do Termux | Alvos previstos, sujeitos a versao dos pacotes |
| Android 32 bits, iPhone/iPad, apps homonimos da App Store | Nao suportados |

Reserve **6 GiB livres** e tenha pelo menos **4 GB de RAM**; 8 GB sao recomendados.
O instalador verifica Android, arquitetura do Termux, espaco e versao do PRoot.
Ter processador de 64 bits nao basta se o ambiente Termux instalado for de 32 bits.

O prototipo manual foi usado em um Galaxy Tab S9 com Termux da Google Play e
Ubuntu 26.04. O usuario confirmou que o Copilot funcionou bem. O **novo instalador
deste repositorio usa Debian com Node.js 24**, nao o Ubuntu daquele prototipo.
Seus testes automatizados simulam dependencias: nao comprovam compatibilidade
do novo ambiente com Android, logins ou chamadas reais a modelos.

## Instalar

Instale o [Termux oficial](https://github.com/termux/termux-app#installation).
Nao misture aplicativos, plugins ou repositorios de variantes diferentes.
Nao desinstale um Termux existente sem antes preservar os seus dados.

No Termux, execute:

```sh
pkg update && pkg install -y git
git clone https://github.com/micheljatuba/AI-Termux-Android.git
cd AI-Termux-Android
bash install.sh --check
bash install.sh
```

Revise os scripts antes de executa-los. Baixe o repositorio completo; executar
somente um arquivo por `curl | bash` nao e suportado. Prefira clonar dentro da
home privada do Termux, nao em Download ou no armazenamento compartilhado.

O instalador pede confirmacao, instala o PRoot oficial e cria um ambiente
dedicado `termux-ai`, a partir da imagem oficial `node:24-bookworm-slim`.
O Linux inclui Git, GitHub CLI (`gh`), ripgrep, nano e os tres agentes.
Os agentes rodam como o usuario Linux `node`, sem root real no Android.

As versoes iniciais sao Codex 0.154.0, Copilot 1.0.83 e Claude Code 2.1.269.
Node.js 24, pacotes Debian e atualizacoes automaticas dos fornecedores podem
mudar; nao se trata de uma imagem integralmente fixada por hash.

Opcoes adicionais:

```sh
bash install.sh --check
bash install.sh --no-menu
bash install.sh --yes
```

`--check` nao instala nem modifica arquivos. `--no-menu` desativa a abertura
automatica do menu, inclusive em uma instalacao gerenciada anterior. `--yes`
confirma somente a instalacao; nao autoriza acoes futuras dos agentes.

Uma nova execucao preserva o Linux dedicado e os dados, verifica os pacotes e
atualiza os atalhos gerenciados. Nao a execute enquanto os agentes estiverem
trabalhando. Se ja existir `ia`, `codex`, `copilot`, `claude` ou um Linux
`termux-ai` de outra origem, o instalador para sem substitui-los. Isso inclui
o prototipo configurado manualmente no S9: sua migracao nao e automatica.

## Usar

Abra uma nova sessao Bash do Termux para ver o menu. Na sessao atual, execute:

```sh
ia
```

Use `0` para voltar ao shell. Para trabalhar em um projeto, abra a pasta antes
do agente. Os atalhos preservam essa pasta e todos os argumentos:

```sh
mkdir -p ~/projetos
cd ~/projetos
copilot
```

`claude` e `codex` sao os outros atalhos. `ia terminal` abre o Linux para usar
`git`, `gh`, `node`, `npm` ou instalar outras ferramentas compativeis com a sua
arquitetura. O menu automatico atende ao Bash padrao; outros shells podem usar
`ia` manualmente. Sessoes SSH e shells nao interativos nao recebem o menu.

Para suprimir o menu em uma sessao: `TERMUX_AI_NO_MENU=1 bash -l`.

## Entrar Nas Contas

Execute um comando por vez e conclua o fluxo no navegador do proprio aparelho:

```sh
copilot login
claude auth login
codex login
```

Se o navegador nao abrir automaticamente, abra o link mostrado pelo agente.
O Codex tambem oferece `codex login --device-auth` quando a conta permite esse
fluxo. As credenciais ficam na home do usuario `node` dentro do Linux dedicado.
Nunca publique tokens, chaves, pastas de autenticacao ou backups do ambiente.

## Seguranca E Codex

**PRoot nao e um sandbox de seguranca.** Mesmo com o usuario `node`, os agentes
podem acessar arquivos que o Android disponibiliza ao Termux. Revise os pedidos
de permissao e mantenha backups dos projetos.

No prototipo do S9, Codex iniciou, mas a execucao de um comando no sandbox padrao
falhou. O teste alternativo de Landlock falhou com `Sandbox(LandlockRestrict)`.
Por isso, **Codex e experimental neste projeto**: instalar e exibir a versao
nao significa que a execucao protegida de comandos esteja funcionando.

Este instalador nao desativa sandboxes, nao habilita aprovacao irrestrita, nao
modifica protecoes do Android e nao configura servidores SSH ou ADB. Se um
agente exigir recursos de kernel indisponiveis no Android, a instalacao de
Linux por PRoot nao resolve essa limitacao.

## Atualizar E Preservar

Para atualizar deliberadamente os agentes, fora de uma tarefa em andamento:

```sh
ia terminal
npm install -g --prefix "$HOME/.local" @openai/codex @github/copilot
claude update
exit
```

Reexecutar o instalador pode retornar as versoes npm para as versoes iniciais
indicadas acima. Atualizacoes dos agentes podem alterar a compatibilidade.

Os arquivos gerenciados ficam em `~/.local/share/termux-ai` no Termux. O Bash
existente recebe somente uma linha de carregamento do menu; o original fica
em `~/.local/share/termux-ai/bashrc.before`, quando havia um arquivo anterior.

Para backup do Linux dedicado, escolha um nome de arquivo ainda inexistente:

```sh
proot-distro backup termux-ai --output ~/termux-ai-backup.tar.gz
```

Esse backup pode conter credenciais. Guarde-o em local privado. Projetos na
home do Termux, fora do Linux dedicado, precisam de backup separado.
Nao use `proot-distro reset` ou `remove` como tentativa de reparo sem backup:
esses comandos apagam os dados do ambiente.

Se houver interrupcao, o instalador nao apaga automaticamente um Linux parcial.
Se `install.lock` ficar para tras, confirme que nao ha outra instalacao ativa
antes de remover somente o diretorio de lock. Conflitos com comandos existentes
exigem migracao explicita; nao apague atalhos de outra instalacao automaticamente.

## Desenvolvimento

```sh
bash tests/run.sh
shellcheck --severity=warning install.sh bin/ia scripts/setup-linux.sh scripts/menu.bash tests/run.sh
```

A suite e offline e usa pastas temporarias. Verifica argumentos, recursao,
pre-verificacao sem efeitos, conflitos, preservacao de configuracoes e repeticao.
O workflow do GitHub executa esses testes e o ShellCheck; nao faz logins nem
instala agentes em um Android real.

Antes de anunciar suporte a um aparelho, teste uma instalacao limpa, abertura
do menu, login e uma tarefa controlada de leitura/edicao/execucao em cada agente.
Registre modelo do aparelho, Android, origem do Termux, versoes e limitacoes,
sem incluir identificadores pessoais ou credenciais.