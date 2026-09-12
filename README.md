<div align="center">

# AI Termux Android

**Cinco agentes de IA. Um terminal no Android.**

GitHub Copilot &middot; Claude Code &middot; Codex &middot; Antigravity &middot; OpenCode

[![Shell Checks](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml/badge.svg)](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml)
![Android 11 ou superior](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)
![Arquiteturas de 64 bits](https://img.shields.io/badge/64_bits-ARM64_%7C_x86__64-0969DA)

[Instalacao](#instalacao) &middot; [Primeiro uso](#primeiro-uso) &middot; [Como funciona](#como-funciona) &middot; [Atualizar](#atualizar) &middot; [Compatibilidade](#compatibilidade)

</div>

Instale as CLIs oficiais, escolha um agente pelo menu `ia` e trabalhe nos seus
projetos. Sem root, PC, cabo USB ou depuracao USB no uso diario.
Os modelos em nuvem precisam de **internet e uma conta no provedor escolhido**.

## Instalacao

### 1. Prepare o Termux

Instale o **Termux oficial** pela [Google Play](https://play.google.com/store/apps/details?id=com.termux),
[F-Droid](https://f-droid.org/en/packages/com.termux/) ou
[GitHub do Termux](https://github.com/termux/termux-app/releases).

| Requisito | Minimo previsto |
| --- | --- |
| Sistema | Android 11 ou superior |
| Arquitetura do Termux | ARM64 (`aarch64`) ou `x86_64` |
| Espaco livre | 6 GiB para instalar e atualizar |
| Memoria | 4 GB de RAM; 8 GB recomendados |
| Pacotes | A variante do Termux deve oferecer PRoot-Distro 5.3.0+ |

> [!IMPORTANT]
> Nao misture aplicativos, plugins ou repositorios de variantes diferentes do
> Termux. Preserve seus dados antes de trocar uma instalacao existente.
> iOS e aplicativos homonimos da App Store nao sao suportados.

### 2. Instale os agentes

No **Termux**, execute o bloco abaixo. O instalador verifica o ambiente e pede
confirmacao antes de instalar pacotes.

```sh
pkg update && pkg install -y git
git clone https://github.com/micheljatuba/AI-Termux-Android.git ~/AI-Termux-Android
cd ~/AI-Termux-Android
bash install.sh --check
bash install.sh
```

Mantenha o projeto na home privada do Termux, fora de Download ou do armazenamento
compartilhado. Revise os scripts antes de executar; baixe o repositorio completo.

> [!NOTE]
> Ja tem um menu `ia` ou Ubuntu configurado manualmente? Veja
> [Instalacoes existentes](#instalacoes-existentes). O instalador nao substitui
> comandos ou ambientes de outra origem.

### 3. Abra o menu

```sh
ia
```

O menu tambem aparece em novas sessoes **Bash** do Termux. Escolha o numero do
agente e pressione Enter. Use `0` para voltar ao shell.

<details>
<summary>Opcoes de instalacao</summary>

| Opcao | O que faz |
| --- | --- |
| `bash install.sh --check` | Verifica o ambiente sem instalar nem modificar arquivos |
| `bash install.sh --no-menu` | Instala os comandos sem abrir o menu automaticamente |
| `bash install.sh --yes` | Confirma a instalacao sem pergunta interativa |

`--yes` nao autoriza acoes futuras dos agentes. Para desativar um menu automatico
ja gerenciado por este projeto, execute novamente com `--no-menu`.
Outros shells podem usar `ia` manualmente; conexoes SSH e shells nao interativos
nao recebem o menu.

</details>

## Primeiro uso

Conecte a conta de cada agente, seguindo o fluxo oficial no navegador ou no
terminal. As contas de outros agentes **nao sao copiadas automaticamente**.

| Agente | Abrir | Conectar a conta |
| --- | --- | --- |
| GitHub Copilot CLI | `copilot` | `copilot login` |
| Claude Code | `claude` | `claude auth login` |
| Codex | `codex` | `codex login` |
| Google Antigravity CLI | `antigravity` ou `agy` | Siga o fluxo ao abrir |
| OpenCode | `opencode` | `opencode auth login` ou `/connect` na interface |

Se o navegador nao abrir, use o link exibido pelo agente. Planos, limites e
cobranca dependem de cada provedor; este projeto nao fornece assinaturas ou
creditos. No OpenCode, `opencode models` lista os modelos disponiveis.

**Abra o agente dentro da pasta em que deseja trabalhar:**

```sh
mkdir -p ~/projetos/meu-projeto
cd ~/projetos/meu-projeto
copilot
```

Os atalhos preservam a pasta atual e os argumentos. Use `ia terminal` para abrir
o Linux e executar `git`, `gh`, `node` e `npm` no mesmo projeto.

### Na tela

![Menu real do Termux no Android com os cinco agentes e o terminal Ubuntu](docs/images/termux-menu-android.png)

<sub>Captura real de uma instalacao Ubuntu existente no Android, recortada para
mostrar apenas o menu. Essa instalacao preserva sua ordem original; em uma
instalacao nova, Copilot, Claude e Codex ocupam as opcoes 1, 2 e 3.</sub>

## Como funciona

```mermaid
flowchart LR
    android["Android + Termux"] --> menu["Menu ia e atalhos"]
    menu --> linux["Linux via PRoot"]
    linux --> cli["CLI escolhida"]
    cli --> provider["Provedor de IA"]
```

1. **Verifica o ambiente:** Android, arquitetura, espaco livre e conflitos com comandos existentes.
2. **Prepara o Linux:** instala o PRoot oficial e cria o ambiente `termux-ai`, usando Debian com Node.js 24.
3. **Instala as CLIs oficiais:** verifica os executaveis, sem pedir logins nem chamar modelos.
4. **Cria os atalhos:** adiciona `ia` e os comandos dos agentes, com menu automatico opcional.

O ambiente inclui **Git, GitHub CLI, ripgrep, nano e Node.js**. Os agentes rodam
como o usuario Linux `node`, sem root real no Android. A imagem base e
`node:24-bookworm-slim`; nao e necessario instalar ou executar Docker.

Isso nao transforma Android em Windows. PRoot fornece um ambiente Linux sobre
o kernel do Android, com limitacoes de compatibilidade e isolamento.

## Atualizar

Saia dos agentes antes de atualizar uma instalacao **gerenciada por este projeto**:

```sh
cd ~/AI-Termux-Android
git pull --ff-only
bash install.sh
```

O Linux dedicado e seus dados sao reaproveitados. Use `--no-menu` novamente se
nao deseja o menu automatico. Comandos personalizados nao sao sobrescritos.

<details>
<summary>Atualizar apenas as CLIs e consultar versoes</summary>

```sh
ia terminal
npm install -g --prefix "$HOME/.local" @openai/codex @github/copilot
claude update
agy update
opencode upgrade
exit
```

Para conferir as versoes pelo Termux:

```sh
copilot --version
claude --version
codex --version
antigravity --version
opencode --version
```

O instalador parte de Codex 0.154.0, Copilot 1.0.83, Claude Code 2.1.269 e
OpenCode 1.18.30. Antigravity segue seu manifesto oficial. Reexecutar o instalador
pode retornar os pacotes npm para as versoes iniciais; atualizacoes dos fornecedores
podem mudar a compatibilidade.

No OpenCode, o instalador executa explicitamente apenas o pos-instalador oficial,
sem liberar scripts globalmente no npm. O download do Antigravity verifica o
dominio do pacote e o SHA-512 antes de instalar o binario. O configurador de
aliases e perfis do Antigravity nao e executado.

</details>

## Instalacoes existentes

**Ja usa Ubuntu e um menu manual no Android? Nao execute o instalador completo
por cima dessa configuracao.** O complemento abaixo acrescenta apenas o OpenCode
a um menu compativel, sem migrar contas nem reinstalar os outros agentes.

Clone este repositorio, caso ainda nao o tenha, usando o comando da
[instalacao](#instalacao). Depois, no Termux e **fora do Ubuntu**:

```sh
cd ~/AI-Termux-Android
git pull --ff-only
bash scripts/add-opencode-ubuntu.sh
ia
```

O complemento reconhece o menu Ubuntu com Antigravity na opcao 5 e acrescenta
OpenCode na opcao 6. Preserva as opcoes anteriores e salva uma copia do menu
em `~/.cache/termux-ai-opencode.*`. Se o formato for desconhecido ou existir
um comando `opencode` de outra origem, ele para sem substituir o menu.
Nao e uma migracao generica de qualquer instalacao Ubuntu.

## Compatibilidade

**O alvo e Android 11+ de 64 bits.** Isso nao garante o funcionamento de todas
as CLIs em qualquer configuracao. A tabela separa os testes locais do uso real:

| Componente | Situacao observada em Android com Ubuntu |
| --- | --- |
| Copilot CLI | Uso confirmado pelo usuario |
| Antigravity CLI | Versao e ajuda verificadas; uso confirmado pelo usuario |
| Claude Code | Diagnostico de instalacao e tela inicial verificados; uso com modelos pendente |
| OpenCode | Instalacao, versao e ajuda verificadas; interface, login e tarefas com modelos pendentes |
| Codex | Inicia, mas o sandbox de comandos falhou com `Sandbox(LandlockRestrict)` |

As verificacoes em aparelho usaram **Android com Ubuntu 26.04**. A instalacao
limpa do ambiente **Debian** criado pelo instalador ainda precisa de validacao
completa. Os testes automatizados e o CI usam dependencias simuladas: nao fazem
login, nao chamam modelos e nao substituem testes no Android.

<details>
<summary>Limites conhecidos e solucao de problemas</summary>

- **Codex:** continua experimental. Exibir `--version` nao confirma que a execucao protegida de comandos funciona.
- **OpenCode:** continua experimental ate validar interface, autenticacao e tarefas com modelos.
- **Antigravity:** o login Linux pode depender de Secret Service/D-Bus; persistencia de credenciais nao e garantida em todas as configuracoes PRoot.
- **Arquitetura:** um processador de 64 bits com Termux de 32 bits nao atende aos requisitos.
- **Repositorios:** se a sua variante nao oferece PRoot-Distro 5.3.0+, nao misture repositorios para forcar a instalacao.
- **Conflitos:** comandos dos agentes de outra origem exigem migracao explicita.
- **Interrupcao:** confirme que nao existe outra instalacao ativa antes de remover um `install.lock` remanescente. Um Linux parcial nao e apagado automaticamente.

Referencias: [Termux](https://github.com/termux/termux-app#installation),
[PRoot-Distro](https://github.com/termux/proot-distro),
[Antigravity](https://antigravity.google/docs/cli/install) e
[OpenCode](https://opencode.ai/docs/cli/).

</details>

## Seguranca e backups

> [!WARNING]
> **PRoot nao e um sandbox de seguranca.** Os agentes podem acessar arquivos
> disponiveis ao Termux. Revise as permissoes e mantenha backups dos projetos.

O instalador nao desativa sandboxes, nao habilita aprovacao irrestrita, nao
configura compartilhamento automatico de sessoes e nao abre acesso SSH/ADB.
As permissoes dos agentes permanecem nos padroes de cada fornecedor.

Digite chaves somente no prompt oficial do agente. Nao publique credenciais,
logs privados ou backups. No OpenCode, as credenciais ficam em
`~/.local/share/opencode/auth.json`, dentro do Linux em que ele roda.

<details>
<summary>Onde ficam os dados e como fazer backup</summary>

O estado do instalador fica em `~/.local/share/termux-ai` no Termux. Quando havia
um arquivo Bash anterior, sua copia e preservada em
`~/.local/share/termux-ai/bashrc.before`. O menu usa apenas uma linha adicional
de carregamento nesse arquivo.

Para copiar o Linux dedicado, escolha um nome de arquivo ainda inexistente:

```sh
proot-distro backup termux-ai --output ~/termux-ai-backup.tar.gz
```

Esse backup pode conter credenciais. Guarde-o em local privado. Projetos na
home do Termux, fora do Linux dedicado, precisam de backup separado.
Nao use `proot-distro reset` ou `remove` como reparo sem backup: eles apagam
os dados do ambiente.

</details>

## Desenvolvimento

Os testes exigem Bash, Node.js 22+ e utilitarios GNU, incluindo `tar` e `sha512sum`.

```sh
bash tests/run.sh
shellcheck --severity=warning install.sh bin/ia scripts/setup-linux.sh scripts/add-opencode-ubuntu.sh scripts/menu.bash tests/run.sh
```

A suite verifica argumentos, conflitos, preservacao de configuracoes,
repeticao da instalacao, validacao de downloads e atualizacao do menu Ubuntu.
Antes de anunciar suporte a uma nova configuracao Android, teste instalacao,
login e uma tarefa controlada em cada agente, sem publicar dados pessoais.