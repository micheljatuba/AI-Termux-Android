<div align="center">

# AI Termux Android

### Seu Android virou uma estacao de programacao com IA.

**Cinco agentes de IA de verdade, um menu, nenhum PC.**
GitHub Copilot &middot; Claude Code &middot; Codex &middot; Antigravity &middot; OpenCode &middot; Hermes (opcional)

[![Shell Checks](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml/badge.svg)](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml)
![Android 11 ou superior](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)
![Sem root](https://img.shields.io/badge/root-nao_precisa-198754)
![Arquiteturas de 64 bits](https://img.shields.io/badge/64_bits-ARM64_%7C_x86__64-0969DA)
[![Licenca MIT](https://img.shields.io/badge/licenca-MIT-blue)](LICENSE)
[![Seguranca](https://img.shields.io/badge/seguranca-politica_publica-8250df)](SECURITY.md)

<img src="docs/images/menu-android.png" width="720" alt="Menu do AI Termux Android com os agentes, o terminal Linux, o EmbeddingGemma, versoes e atualizacoes, diagnostico, o Hermes Agent opcional e o painel web">

<sub>Digite <code>ia</code>. Escolha o numero. Comece a programar.</sub>

**[Instalar em 3 comandos](#instalacao)** &middot; [Ver funcionando](#veja-funcionando) &middot; [Recursos](#o-que-ele-faz) &middot; [Seguranca](#seguranca-em-primeiro-lugar) &middot; [English](README.en.md)

</div>

---

## Por que isso existe

A ideia aparece no onibus, na fila, longe do computador. Ate agora, programar
com IA exigia um notebook ou um app preso a um unico provedor.

**AI Termux Android coloca os agentes de linha de comando oficiais dentro do seu
celular ou tablet**, num Linux de verdade, com Git, GitHub CLI e Node.js. Voce
abre a pasta do projeto, escolhe o agente e trabalha, e no proximo aparelho
continua de onde parou.

> **Sem root. Sem PC. Sem cabo USB.** So o Termux, a sua conta no provedor de IA
> e alguns minutos de instalacao.

## Veja funcionando

Capturas reais das CLIs oficiais no Android, antes do login:

<table>
  <tr>
    <td width="50%"><img src="docs/images/claude-entry.png" alt="Claude Code aberto no Android com a escolha do metodo de login"><br><sub><b>Claude Code</b></sub></td>
    <td width="50%"><img src="docs/images/copilot-entry.png" alt="GitHub Copilot CLI aberto no Android antes do login"><br><sub><b>GitHub Copilot CLI</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/codex-entry.png" alt="Codex aberto no Android com as opcoes de conexao"><br><sub><b>Codex</b></sub></td>
    <td width="50%"><img src="docs/images/antigravity-entry.png" alt="Antigravity CLI aberto no Android com as opcoes de login Google"><br><sub><b>Google Antigravity CLI</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/opencode-entry.png" alt="OpenCode aberto no Android com a selecao de provedor"><br><sub><b>OpenCode</b></sub></td>
    <td width="50%"><img src="docs/images/agents-versions.png" alt="Versoes de Copilot, Claude, Codex, Antigravity e OpenCode no Android"><br><sub><b>Os cinco instalados, lado a lado</b></sub></td>
  </tr>
</table>

## O que ele faz

| | Recurso | Na pratica |
| :---: | --- | --- |
| 🤖 | **Cinco agentes, um menu** | `ia` abre o menu; `claude`, `copilot`, `codex`, `agy` e `opencode` abrem direto, sempre na pasta atual. |
| 🖥️ | **[Painel no navegador](#acesso-pelo-navegador)** | Varios agentes ao vivo lado a lado, com terminal interativo em cada cartao. Envie a mesma pergunta para todos de uma vez. |
| 🎼 | **[Orquestracao](#orquestracao-de-agentes)** | Compare respostas, encadeie *planejar &rarr; implementar &rarr; revisar* ou deixe um "maestro" dividir a tarefa entre os agentes. Somente leitura: nada e alterado sem voce. |
| 🧑‍✈️ | **[Modo auto](#modo-auto-o-jev-decide-o-hermes-conduz)** | O Jev decide, o Hermes coordena e escolhe o agente e o modelo de cada parte: Claude numa, Codex noutra. Voce confirma o plano. *(experimental)* |
| 📲 | **[Continue em outro aparelho](#continuar-em-outro-aparelho)** | `ia handoff` no celular, `ia continuar` no tablet. Seu trabalho viaja por um branch privado, com qualquer agente. *(experimental)* |
| 🧭 | **[Frente de decisao](#frente-de-decisao-com-typesafe-jev-opcional)** | Com o TypeSafe Jev, cada tarefa e avaliada antes: risco, clareza e qual agente usar. *(opcional, experimental)* |
| 🧠 | **[Hermes Agent](#hermes-agent-opcional) e [EmbeddingGemma 2](#embeddinggemma-2-opcional)** | Um agente generalista com memoria e busca semantica local nos seus arquivos, se voce quiser. *(opcionais)* |
| ✈️ | **[LFM3 local](#lfm3-local-opcional)** | Um modelo da Liquid AI rodando no proprio aparelho: conversa sem internet e API local compativel com OpenAI, com token. *(opcional, experimental)* |
| 🔄 | **[Atualizacoes](#atualizar) e [diagnostico](#diagnostico)** | `ia versoes`, `ia atualizar` e `ia diagnostico` mostram o que esta desatualizado e o que precisa de atencao. |

## Seguranca em primeiro lugar

Agentes de IA tem acesso aos seus arquivos. Por isso o projeto trata seguranca
como recurso, nao como rodape:

- 🔒 **Servicos locais com token.** Painel, terminal web e EmbeddingGemma escutam so em `127.0.0.1` e exigem um token privado, porque outros apps do Android tambem alcancam `127.0.0.1`.
- 🛡️ **Nada e desligado escondido.** Sandboxes e aprovacoes dos agentes ficam no padrao de cada fornecedor; o Codex abre no modo *Pedir aprovacao*.
- 🔑 **Segredos nao vazam.** O handoff so envia para repositorio privado e para ao encontrar tokens ou chaves; a frente de decisao nunca envia o conteudo dos seus arquivos.
- 🚦 **Falha fechada.** Se uma verificacao nao pode ser feita, nada segue sem a sua confirmacao.
- 🧪 **Testado de verdade.** Centenas de verificacoes automaticas a cada mudanca, incluindo testes que tentam quebrar as protecoes de proposito.

Detalhes, limites conhecidos e como relatar uma falha: [SECURITY.md](SECURITY.md).

## Comece agora

No [Termux oficial](#1-prepare-o-termux):

```sh
pkg update && pkg install -y git
git clone https://github.com/micheljatuba/AI-Termux-Android.git ~/AI-Termux-Android
cd ~/AI-Termux-Android && bash install.sh
```

Depois digite `ia`. O passo a passo completo esta em [Instalacao](#instalacao).

**Testado no Android:** instalacao, menu, atalhos e acesso aos cinco agentes
com login e API. Veja os [requisitos e limites](#compatibilidade). Os modelos em
nuvem precisam de **internet e uma conta no provedor escolhido**; assinaturas,
creditos e limites de uso nao estao incluidos neste projeto.

## O que voce pode criar

| Sua proxima ideia | Como usar o ambiente |
| --- | --- |
| Um script que resolve uma tarefa repetitiva | Descreva a tarefa ao agente, revise o codigo e teste no terminal |
| Um projeto que voce quer entender | Abra a pasta e peca uma explicacao da estrutura e dos pontos principais |
| Uma correcao que nao pode esperar | Investigue o erro, revise a sugestao e execute os testes do projeto |
| Uma segunda opiniao sobre seu codigo | Rode `ia orquestrar comparar` e veja as propostas de varios agentes lado a lado |
| Um projeto pronto para compartilhar | Use Git e GitHub CLI para revisar alteracoes e publicar seu trabalho |

O agente muda. **A pasta do projeto continua a mesma.** Cada CLI mantem sua
propria conta e conversa; voce escolhe a ferramenta para cada etapa.

<div align="center">

**Curtiu? Deixe uma ⭐ para encontrar o projeto depois e ajudar mais gente a descobrir.**

</div>

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

Os downloads diretos do instalador Claude e do manifesto/pacote Antigravity
limitam a conexao a 15 segundos e cada tentativa a 5 minutos. Falhas transitorias
podem receber ate duas novas tentativas; o curl deixa de iniciar novas tentativas
apos 10 minutos. Esses limites nao abrangem os comandos `pkg`, `npm`, `apt-get`
nem downloads internos dos instaladores dos fornecedores. Se a instalacao falhar,
aguarde a execucao terminar e rode `bash install.sh` novamente; nao apague o Linux.

> [!NOTE]
> Ja tem um menu `ia` ou Ubuntu configurado manualmente? Veja
> [Instalacoes existentes](#instalacoes-existentes). O instalador nao substitui
> comandos ou ambientes de outra origem.

### 3. Abra o menu

```sh
ia
```

O menu tambem aparece em novas sessoes **Bash** do Termux. Escolha o numero do
agente e pressione Enter. A opcao `7` abre o EmbeddingGemma 2 local (opcional),
`8` atualiza os agentes, `9` faz o [diagnostico](#diagnostico), `10` abre o
[Hermes Agent](#hermes-agent-opcional) (opcional) e `11` abre o
[painel web](#acesso-pelo-navegador) com varios agentes. Para consultar
versoes, execute `ia versoes`. Use `0` para voltar ao shell.

<details>
<summary>Opcoes de instalacao</summary>

| Opcao | O que faz |
| --- | --- |
| `bash install.sh --check` | Verifica o ambiente sem instalar nem modificar arquivos |
| `bash install.sh --no-menu` | Instala os comandos sem abrir o menu automaticamente |
| `bash install.sh --yes` | Confirma a instalacao sem pergunta interativa |
| `bash install.sh --adopt-ubuntu` | Integra um Ubuntu e um menu `ia` manuais; veja [Instalacoes existentes](#instalacoes-existentes) |

`--yes` nao autoriza acoes futuras dos agentes. Para desativar um menu automatico
ja gerenciado por este projeto, execute novamente com `--no-menu`.
Outros shells podem usar `ia` manualmente; conexoes SSH e shells nao interativos
nao recebem o menu.

</details>

## Acesso pelo navegador

No Termux, execute:

```sh
ia web
```

Isso inicia o **painel de agentes** e abre o link no navegador do aparelho. O
link tem o formato `http://127.0.0.1:7690/<token>/`. Se o navegador nao abrir
sozinho, copie o link exibido ou use `ia web abrir`. Quando o EmbeddingGemma
opcional estiver instalado, sua interface sobe junto em
`http://127.0.0.1:8085/<token>/`, com o mesmo token.

| Comando | O que faz |
| --- | --- |
| `ia web` | Inicia o painel (e o EmbeddingGemma, se instalado) |
| `ia web abrir` | Inicia o painel e abre o link no navegador |
| `ia web status` | Mostra o que esta ativo; `ia web status painel` (ou `terminal`, `embedding`) inclui o link |
| `ia web stop` | Encerra os servicos e as sessoes dos agentes, e libera o wake-lock |
| `ia web start terminal` | Inicia so o terminal Linux com menu em `http://127.0.0.1:7680/<token>/menu/` |

`start`, `stop` e `status` aceitam um alvo: `painel`, `terminal`, `embedding` ou
`todos`; por exemplo, `ia web stop painel`. O terminal com menu so sobe quando
pedido, porque da acesso a um shell completo.

O comando volta assim que o painel esta no ar, e os servicos seguem em segundo
plano ate `ia web stop`. Se o inicio passar de 180 s, o `ia web` para de esperar
e avisa; ajuste o limite com `TERMUX_AI_WEB_START_TIMEOUT` (em segundos) e confira
o resultado com `ia web status`.

### O que o painel oferece

- **Varios agentes ao vivo.** Abra Copilot, Claude Code, Codex, Antigravity,
  OpenCode, Hermes ou um terminal Linux. Cada um roda em uma sessao `tmux` propria
  e aparece como um cartao com terminal interativo. Fechar a aba ou trocar de
  aplicativo nao encerra o agente.
- **Grade ou foco.** Veja os cartoes lado a lado ou amplie um deles, em **Ao vivo**
  (terminais interativos) ou em **Previa** (so as ultimas linhas, mais leve).
- **Um prompt para varios agentes.** Marque os agentes, escreva uma vez e envie a
  todos com Ctrl+Enter. **Colar sem Enter** deixa o texto no terminal para voce
  revisar antes. Ha modelos de prompt prontos.
- **Pasta de trabalho.** O seletor navega apenas dentro da pasta de onde `ia web`
  foi iniciado.
- **Orquestrar e Historico.** Abas para [orquestrar](#orquestracao-de-agentes)
  varios agentes e rever as execucoes anteriores.

Cada agente abre com as permissoes e a conta normais da sua CLI; o Codex abre no
modo [Pedir aprovacao](#codex-no-android). Sao ate 6 sessoes ao mesmo tempo, e o
painel recusa novas quando a memoria livre fica abaixo de 512 MB.

> [!IMPORTANT]
> O painel, o terminal com menu e o EmbeddingGemma escutam **somente em
> 127.0.0.1** e todo acesso exige o token do link. O token importa porque, no
> Android, **outros apps instalados no aparelho tambem alcancam 127.0.0.1**.
> Quem tiver o link controla os agentes e os terminais: nao o
> compartilhe nem o publique em capturas de tela. Para trocar o token, encerre o
> painel e apague o arquivo; o proximo `ia web` gera outro.

```sh
ia web stop
ia terminal -c 'rm -f ~/.local/share/termux-ai/web/token'
ia web
```

<details>
<summary>Sessoes, dois aparelhos e Android 12+</summary>

- **As sessoes vivem enquanto o painel estiver ativo.** Fechar a aba, trocar de
  aplicativo ou bloquear a tela nao as encerra, e ao voltar elas reaparecem.
  `ia web stop` encerra o painel **e todas as sessoes**, com os agentes dentro
  delas: no PRoot, cada `ia web` roda em uma instancia propria e so alcanca o
  tmux da propria instancia, entao um tmux deixado para tras ficaria
  inacessivel (`access not allowed`). O botao **✕** de um cartao encerra so
  aquele agente.
- **Dois aparelhos ou janelas na mesma sessao.** Com telas de tamanhos
  diferentes, o tmux mostra pontos (`·`) na area que sobra. Use uma tela por vez.
- **Android 12 ou superior.** O sistema pode encerrar processos em segundo plano
  do Termux (`signal 9`). O `ia web` aciona o wake-lock, mas se os agentes caem
  quando o Termux fica em segundo plano, veja como
  [desativar a restricao de processos fantasma](https://github.com/agnostic-apollo/Android-Docs/blob/master/en/docs/apps/processes/phantom-cached-and-empty-processes.md).

</details>

O painel, o terminal com menu e o EmbeddingGemma escutam **somente em
127.0.0.1** e nao aceitam conexoes de outros aparelhos no Wi-Fi; nao altere o
endereco de escuta para `0.0.0.0`. Os tres exigem o mesmo token; um servico de
versao anterior que ainda rode sem token e reiniciado no proximo `ia web start`.
O instalador inclui `ttyd`, `tmux` e Node.js
no Linux, e `ia web` aciona `termux-wake-lock` automaticamente quando disponivel,
evitando que o Android suspenda os servicos ao alternar para o navegador
(`ia web stop` libera o wake-lock).

### EmbeddingGemma 2 (opcional)

Para habilitar o EmbeddingGemma, execute no Termux:

```sh
ia embeddinggemma install
```

Esse comando instala Python e as dependencias opcionais (`sentence-transformers`,
`fastapi` e `uvicorn`) no Linux. Reserve alguns GiB; a primeira inferencia baixa
o modelo (cerca de 1,5 GiB) e pode levar mais tempo. Busca de arquivos fica
restrita a pasta atual de onde `ia web` foi iniciado. Programas que usam o
endpoint compativel com OpenAI (`http://127.0.0.1:8085/v1/embeddings`) devem
enviar `Authorization: Bearer <token>`; o token fica em
`~/.local/share/termux-ai/web/token`, dentro do Linux.

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
| Hermes Agent (opcional) | `hermes` ou `ia hermes` | `ia hermes setup`; veja [Hermes Agent](#hermes-agent-opcional) |

Se o navegador nao abrir, use o link exibido pelo agente. Planos, limites e
cobranca dependem de cada provedor; este projeto nao fornece assinaturas ou
creditos. No OpenCode, `opencode models` lista os modelos disponiveis.

**OpenCode sem chave de API:** em `opencode auth login`, escolha **GitHub
Copilot** para entrar com a assinatura do Copilot por codigo de dispositivo,
ou **OpenAI** e depois **ChatGPT Plus/Pro** para usar a assinatura do ChatGPT.
Depois de conectar as contas, confira tudo com `ia diagnostico`.

**Abra o agente dentro da pasta em que deseja trabalhar:**

```sh
mkdir -p ~/projetos/meu-projeto
cd ~/projetos/meu-projeto
copilot
```

Os atalhos preservam a pasta atual e os argumentos. Use `ia terminal` para abrir
o Linux e executar `git`, `gh`, `node` e `npm` no mesmo projeto.

### Na tela

Veja a interface antes de conectar sua conta. As capturas abaixo mostram as
CLIs reais em perfis de demonstracao vazios, sem credenciais ou conversas.

<details open>
<summary>GitHub Copilot CLI</summary>

**Opcao 1 no menu** ou `copilot`. A entrada mostra a area de conversa e o
comando `/login` para conectar sua conta.

![GitHub Copilot CLI aberto antes do login](docs/images/copilot-entry.png)

</details>

<details>
<summary>Claude Code</summary>

**Opcao 2 no menu** ou `claude`. Escolha o metodo de conexao oferecido pela
CLI, incluindo conta Claude ou Anthropic Console para uso de API.

![Claude Code com a escolha do metodo de login](docs/images/claude-entry.png)

</details>

<details>
<summary>Codex</summary>

**Opcao 3 no menu** ou `codex`. A tela de boas-vindas oferece conexao com
ChatGPT, codigo de dispositivo ou sua propria chave de API. No Android, o
Codex abre no modo **Pedir aprovacao**; veja [Codex no Android](#codex-no-android).

![Codex com as opcoes de conexao antes do login](docs/images/codex-entry.png)

</details>

<details>
<summary>Google Antigravity CLI</summary>

**Opcao 5 no menu** ou `antigravity`. A tela de entrada oferece Google OAuth
ou conexao por um projeto Google Cloud, conforme o fluxo do fornecedor.

![Antigravity CLI com as opcoes de login Google](docs/images/antigravity-entry.png)

</details>

<details>
<summary>OpenCode</summary>

**Opcao 6 no menu** ou `opencode`. Para conectar uma conta, `opencode auth login`
abre a selecao de provedores mostrada abaixo. Escolha o seu e siga o fluxo
de autenticacao antes de inserir qualquer credencial.

![OpenCode com a selecao de provedor antes de inserir credenciais](docs/images/opencode-entry.png)

</details>

<details>
<summary>Versoes dos cinco agentes</summary>

**Cinco executaveis, uma instalacao.** Abaixo, a saida real dos comandos
`--version` executados pelos atalhos do Termux:

![Versoes de Copilot, Claude, Codex, Antigravity e OpenCode no Android](docs/images/agents-versions.png)

<sub>Captura real do terminal. As interfaces e versoes podem mudar com as
atualizacoes dos fornecedores.</sub>

</details>

### Codex no Android

**O sandbox do Codex nao funciona no Android.** O Android nao oferece Landlock,
e o bubblewrap usado pelo Codex nao consegue montar o isolamento no PRoot. No
modo padrao do Codex, os comandos do agente falham sem pedir aprovacao.

Por isso, `codex`, `ia codex` e a opcao 3 do menu abrem o Codex no modo
**Pedir aprovacao** (`-s workspace-write -a on-request`), com um aviso curto.
Cada comando ou edicao pede sua confirmacao: aprovar executa a acao fora do
sandbox; recusar a bloqueia.

| Ao abrir o Codex | O que acontece |
| --- | --- |
| `codex`, `codex resume` ou `codex fork` | Abre no modo Pedir aprovacao |
| Com uma opcao de permissao, como `-s`, `-a`, `-p` ou `--full-auto` | Usa o modo informado, sem alteracao |
| `codex exec` ou `codex review` | Mostra um aviso: sem o sandbox, os comandos do agente falham |
| `codex login`, `codex --help` e os demais subcomandos | Executa sem alteracao |

Revise cada pedido antes de aprovar e mantenha os projetos no Git ou com
backup. O [diagnostico](#diagnostico) testa o sandbox do Codex e avisa se uma
versao futura passar a inicia-lo sem bloquear gravacoes; nesse caso, comandos
poderiam rodar sem aprovacao.

O Codex tambem inicia um servidor local em segundo plano. Ao fechar o Codex
aberto pelo menu ou por `ia codex`, o PRoot-Distro encerra os processos do
Linux, inclusive esse servidor. Por isso, a mensagem "Any running work
continues", exibida ao sair, nao vale aqui: espere a tarefa terminar antes de
sair e use `ia codex resume` para retomar a conversa.

Esse servidor e um pacote separado, que o npm e o `ia atualizar` nao trocam.
Depois de atualizar o Codex, ele pode avisar que o servico em segundo plano e
mais antigo que o CLI. O aviso nao impede o uso; para atualizar o servico,
digite `/daemon` no Codex, como o proprio aviso indica. Os avisos sobre
bubblewrap tambem sao esperados: instala-lo nao resolve, porque no PRoot ele
nao isola de verdade.

## Orquestracao de agentes

Faca varios agentes trabalharem juntos na mesma tarefa, pela aba **Orquestrar**
do [painel](#acesso-pelo-navegador) ou pelo Termux:

```sh
ia orquestrar comparar -a claude,copilot -j auto "Onde fica a validacao de login?"
ia orquestrar pipeline -e planejar:claude,implementar:copilot,revisar:agy "Adicionar cache ao cliente HTTP"
ia orquestrar maestro -a claude,copilot,opencode "Mapear o projeto e listar riscos"
```

| Modo | Como funciona |
| --- | --- |
| **Comparar** | Os agentes respondem a mesma tarefa em paralelo; um juiz opcional compara as respostas (`-j auto` escolhe o melhor disponivel) |
| **Pipeline** | Linha de montagem de 2 a 6 etapas (planejar, implementar, revisar); cada etapa recebe a tarefa e o resultado da anterior |
| **Maestro** | Um coordenador divide a tarefa em ate 6 subtarefas, os agentes as executam em paralelo e ele integra os resultados |
| **Auto** | O [Jev](#frente-de-decisao-com-typesafe-jev-opcional) decide (risco, clareza e modo) e o **Hermes**, se instalado, coordena: escolhe o agente e o modelo de cada subtarefa e integra o resultado |

### Modo auto: o Jev decide, o Hermes conduz

```sh
ia orquestrar modelos claude opus,sonnet      # modelos que o coordenador pode escolher
ia orquestrar auto "Revisar a seguranca do login e propor correcoes"
```

1. **O Jev decide:** bloqueia tarefas perigosas, pede confirmacao ou mais detalhes e escolhe o modo.
2. **O Hermes coordena** (ou o agente indicado pelo Jev, se o Hermes nao estiver instalado): divide a tarefa e escolhe, para cada parte, o agente e o modelo.
3. **Voce ve o plano numa linha e confirma** (`--sim` sem terminal).
4. Claude, Codex, Copilot, OpenCode e Antigravity executam as partes em paralelo; o Hermes integra a resposta final.

O Hermes so escolhe modelos da lista que voce definir com `ia orquestrar modelos`;
sem lista, cada agente usa o modelo padrao da sua conta. Aceitam modelo: Claude
Code (`--model`), Codex (`-m`), Copilot (`--model`) e OpenCode (`-m
provedor/modelo`). O modo auto exige o Jev ativo e segue em **somente leitura**:
os agentes propoem, voce aplica.

> [!NOTE]
> **Somente leitura, sempre.** Na orquestracao os agentes leem e analisam o
> projeto, mas nao alteram arquivos nem executam comandos: uma etapa
> "implementar" **propoe** o codigo no texto. Para aplicar uma proposta, abra o
> agente na pasta do projeto e peca a alteracao, revisando cada passo.

| Comando ou opcao | O que faz |
| --- | --- |
| `ia orquestrar agentes` | Lista os agentes e o que cada um consegue fazer |
| `ia orquestrar modelos [agente lista\|limpar]` | Mostra ou define os modelos que o coordenador pode escolher por agente |
| `ia orquestrar historico` | Lista as ultimas execucoes (as 50 mais recentes ficam salvas) |
| `ia orquestrar ver ID [--tudo]` | Mostra o resultado de uma execucao; `--tudo` inclui cada etapa |
| `-d PASTA`, `-t SEGUNDOS`, `--json` | Pasta de trabalho (padrao: a atual), tempo limite por etapa (30 a 1800; padrao 600) e saida em JSON |

A tarefa tambem pode vir da entrada padrao, como em
`git diff | ia orquestrar comparar -a claude,copilot -j auto -`. O progresso vai
para o stderr e o resultado final para o stdout. `ia orquestrar --ajuda` mostra
todas as opcoes. Ate 4 agentes rodam ao mesmo tempo, e as execucoes ficam em
`~/.local/share/termux-ai/runs` dentro do Linux.

<details>
<summary>Como cada agente fica em somente leitura</summary>

Cada pedido comeca com uma instrucao de somente leitura e, alem disso, cada
agente roda com as travas da propria CLI:

| Agente | Trava |
| --- | --- |
| Copilot | `--deny-tool=write` e `--deny-tool=shell` |
| Claude Code | Apenas as ferramentas Read, Grep e Glob, no modo `dontAsk` |
| Codex | `exec -s read-only`; sem sandbox funcional no Android, ele pode nao conseguir ler arquivos (veja [Codex no Android](#codex-no-android)) |
| Antigravity | Modo `plan` |
| OpenCode | Agente `plan`, com edicao negada |
| Hermes | Apenas as ferramentas `web` e `search`: nao le nem altera arquivos |

O progresso e o resultado de cada etapa tambem aparecem no painel, na aba
**Orquestrar**, com o historico na aba **Historico**.

</details>

## Frente de decisao com TypeSafe Jev (opcional)

> [!NOTE]
> **Experimental.** O cliente segue o SDK oficial `@typesafe-ai/sdk` e foi
> testado contra um servidor simulado; a chamada a API real ainda precisa ser
> validada no aparelho.

Com o [TypeSafe Jev](https://console.typesafe.ai) ativado, toda orquestracao
(`ia orquestrar` e o painel) passa antes por uma decisao rapida. No
[modo auto](#modo-auto-o-jev-decide-o-hermes-conduz), a decisao de modo do Jev
tambem e aplicada:

| O Jev avalia | O que acontece |
| --- | --- |
| **Risco** | Tarefa perigosa (roubo de credenciais, malware, ataque) e **bloqueada**, sem atalho para ignorar. Tarefa que pode apagar dados, publicar ou mexer em contas **pede confirmacao**. |
| **Clareza** | Tarefa vaga para e pede mais detalhes antes de gastar os agentes. |
| **Roteamento** | Sugere o agente (inclusive o Hermes) e o modo: direto, comparar, pipeline ou maestro. A escolha final e sua. |

Se o Jev estiver indisponivel (sem internet, sem chave, fora do ar), nada segue
sem a sua confirmacao: no terminal ele pergunta; sem terminal, repita com
`--sem-jev`. Um bloqueio nunca e ignorado.

```sh
ia typesafe configurar      # cole a chave criada em console.typesafe.ai (nao aparece na tela)
ia typesafe testar          # confere chave e conexao, sem enviar dados do projeto
ia decidir "Adicionar cache ao cliente HTTP"   # so a decisao, sem executar agentes
ia typesafe desativar       # volta ao comportamento sem o Jev
```

**O que sai do aparelho:** o texto da tarefa e os **nomes** de ate 300 arquivos
da pasta, nunca o conteudo. Pastas ocultas, `node_modules` e nomes de
credenciais (`.env`, chaves, `auth.json`) ficam de fora. Se a tarefa ou um nome
de arquivo parecer conter um segredo, nada e enviado. A chave fica em arquivo
privado no Linux (`~/.local/share/termux-ai/typesafe/key`) ou na variavel
`TYPESAFE_API_KEY`; o registro local de decisoes guarda so um resumo, sem o
texto da tarefa.

## Hermes Agent (opcional)

O [Hermes Agent](https://github.com/NousResearch/hermes-agent), da Nous
Research, e o sexto agente do ambiente. Ele e **opcional e so e instalado quando
voce pede**: o download tem cerca de 2 GB e a instalacao leva varios minutos,
por isso `bash install.sh` nao o inclui.

```sh
ia atualizar hermes
ia hermes setup
ia hermes
```

`ia atualizar hermes` mostra o plano, pede confirmacao e roda o instalador
oficial do Hermes no Linux; se ele ja estiver instalado, usa `hermes update`.
`ia hermes setup` (ou `ia hermes model`) conecta um provedor de modelos: sem isso
o Hermes nao responde. `ia hermes` abre o agente na pasta atual, assim como a
opcao `10` do menu; sem a instalacao, o comando apenas avisa como instalar.

No painel e na orquestracao, o Hermes usa so as ferramentas `web` e `search`:
ele nao le nem altera os arquivos do projeto. Ele aparece em `ia versoes` e em
`ia diagnostico` (versao e login, sem exibir chaves).

## LFM3 local (opcional)

O [LFM3](https://www.liquid.ai/blog/lfm3), da Liquid AI, e um modelo pequeno
(1,7 bilhao de parametros) que roda **no proprio aparelho**: sem conta, sem
assinatura e, depois de baixado, sem internet. Ele nao substitui os agentes de
nuvem em tarefas grandes; serve para perguntas rapidas, rascunhos e uso offline
(no aviao, no metro, sem sinal).

```sh
ia lfm3 instalar          # pacote llama-cpp do Termux + modelo (cerca de 1 a 2 GB)
ia lfm3                   # conversa no terminal, offline
ia lfm3 servidor          # API compativel com OpenAI em http://127.0.0.1:8086/v1
ia lfm3 token             # token da API (Authorization: Bearer <token>)
ia lfm3 status
ia lfm3 remover           # apaga o modelo baixado
```

- Roda no Termux, fora do Linux do PRoot, com o pacote oficial `llama-cpp`
  (versao 0.8.0 ou mais nova, a primeira com suporte ao LFM3). Uma versao antiga
  e recusada. Se o `pkg` so oferecer uma versao antiga (como `0.0.0-b9590`), o
  espelho esta desatualizado: rode `termux-change-repo`, escolha outro espelho e
  depois `pkg update && pkg install llama-cpp`.
- `instalar` confere o espaco livre, avisa quando a RAM e baixa, mostra a
  licenca e pede confirmacao (`--sim` confirma). `--quant Q4_0` escolhe uma
  versao menor do modelo.
- O modelo fica em `~/.local/share/termux-ai/lfm3` (pasta 700). Conversa e
  servidor usam `--offline`: nada sai do aparelho depois da instalacao.
- O servidor escuta so em `127.0.0.1`, exige o token (arquivo 600) e roda sem a
  interface web do `llama-server`, porque outros apps do Android alcancam
  `127.0.0.1`. `Ctrl+C` encerra.

**Licenca:** LFM Open License v1.0, gratuita para uso pessoal e para empresas
com receita anual abaixo de US$ 10 milhoes. Leia a licenca na pagina do modelo
antes de uso comercial.

## Continuar em outro aparelho

> [!NOTE]
> **Experimental.** Os testes automatizados cobrem repositorios locais, mas o
> recurso ainda nao foi validado em Android/PRoot. Teste primeiro com um projeto
> sem dados sensiveis.

Comecou no celular e quer continuar no tablet? O handoff leva **o trabalho**, nao a
conversa: seus arquivos alterados e uma nota de continuidade, em um branch dedicado
do seu repositorio **privado** no GitHub. Funciona com qualquer um dos agentes e
permite trocar de agente no meio do caminho.

**Uma vez, em cada aparelho** (`ia terminal`): conecte o GitHub e configure o git.

```sh
gh auth login
git config --global user.name "Seu Nome"
git config --global user.email "voce@exemplo.com"
```

**No aparelho de origem**, dentro do projeto (o remoto `origin` deve ser um repositorio privado do GitHub):

```sh
ia handoff --dry-run                      # mostra o que seria enviado, sem enviar
ia handoff --note "Proximo passo: testar o login"
```

**No outro aparelho**, dentro do mesmo repositorio clonado:

```sh
ia continuar
```

O trabalho volta como alteracoes nao confirmadas em um branch novo
`ia/continuar/...`, e a nota fica em `.ia/HANDOFF.md`. Abra o agente e peca:
"Leia .ia/HANDOFF.md e continue o trabalho". Revise `git status` e `git diff`
antes de executar qualquer coisa.

<details>
<summary>O que protege voce, e o que nao protege</summary>

**Protecoes (cobertas por testes):**

- So envia se o GitHub confirmar que o repositorio e privado. Remoto publico ou nao verificavel e recusado.
- Seu branch, arquivos e indice nao sao alterados, e os commits sao montados sem hooks. Nunca usa force-push e so escreve em `ia/handoff/*`, em um branch novo.
- Nao envia `.env*`, chaves, `.npmrc`, bancos locais, `node_modules` nem as pastas de credenciais dos agentes. Os arquivos excluidos sao listados na previa.
- Varre tokens e chaves de formato conhecido (GitHub, Anthropic, OpenAI, AWS, Google, Slack, chaves privadas, JWT, credenciais em URL) nos arquivos alterados, nos commits locais ainda nao publicados e na nota. Se achar algo, aborta sem mostrar o valor.
- Ao continuar, recusa handoffs de outra identidade git e nao sobrescreve alteracoes pendentes.

**Limites:**

- A varredura e uma rede de seguranca, **nao uma garantia**: uma senha em texto comum passa. Mantenha o `.gitignore` em dia.
- Privado nao significa so seu: colaboradores do repositorio enxergam os branches `ia/handoff/*`. Apague-os quando terminar: `git push origin --delete ia/handoff/<aparelho>/<data>`.
- A checagem de autoria evita engano (por exemplo, retomar o handoff de um colega), mas o e-mail de um commit pode ser forjado por quem tem acesso de escrita. Trate o branch como qualquer codigo de colaboradores.
- Nao leva a conversa do agente, apenas o estado do trabalho e a nota. Nao e em tempo real.
- Outros remotos alem do GitHub exigem `--allow-unverified-remote`, por sua conta e risco.

Detalhes e limitacoes da instalacao: [SECURITY.md](SECURITY.md).

</details>

## Como funciona

**Android + Termux** &rarr; **Menu ia e atalhos** &rarr; **Linux via PRoot**
&rarr; **CLI escolhida** &rarr; **Provedor de IA**

1. **Verifica o ambiente:** Android, arquitetura, espaco livre e conflitos com comandos existentes.
2. **Prepara o Linux:** instala o PRoot oficial e cria o ambiente `termux-ai`, usando Debian com Node.js 24, ou reaproveita um Ubuntu existente com `--adopt-ubuntu`.
3. **Instala as CLIs oficiais:** instala as ausentes ou abaixo da versao validada, nunca rebaixa as mais novas e verifica os executaveis, sem pedir logins nem chamar modelos.
4. **Cria os atalhos:** adiciona `ia` e os comandos dos agentes, com menu automatico opcional.

O ambiente inclui **Git, GitHub CLI, ripgrep, nano, Node.js, tmux e ttyd**. Os agentes rodam
como o usuario Linux `node` (no Ubuntu adotado, como o root simulado do PRoot),
sem root real no Android. A imagem base e
`node:24-bookworm-slim`; nao e necessario instalar ou executar Docker.

Isso nao transforma Android em Windows. PRoot fornece um ambiente Linux sobre
o kernel do Android, com limitacoes de compatibilidade e isolamento.

## Atualizar

**Consulte e atualize os agentes pelo Termux:**

```sh
ia versoes
ia atualizar
```

`ia versoes` compara a versao instalada de cada agente com a mais recente
publicada no npm, no manifesto oficial do Antigravity e, para o Hermes, nas
versoes do GitHub. `ia atualizar` mostra o plano, pede confirmacao e verifica
cada agente com `--version` depois da instalacao. A opcao `8` do menu tambem
atualiza os agentes.

| Comando | O que faz |
| --- | --- |
| `ia versoes` | Mostra a versao instalada, a disponivel e a situacao dos agentes, incluindo o Hermes opcional |
| `ia atualizar` | Atualiza os agentes desatualizados apos confirmacao; nao instala o Hermes ausente |
| `ia atualizar claude codex` | Limita a atualizacao aos agentes informados |
| `ia atualizar hermes` | Instala o [Hermes Agent](#hermes-agent-opcional) (cerca de 2 GB) ou o atualiza |
| `ia atualizar --yes` | Confirma o plano sem pergunta interativa |

Feche os agentes antes de atualizar. Cada atualizacao reaproveita o local em
que o agente ja esta instalado: prefixo npm, instalador nativo do Claude Code
ou binario do Antigravity. Contas e conversas sao mantidas. Depois de atualizar
o Codex, ele pode avisar que o servico em segundo plano esta desatualizado;
veja [Codex no Android](#codex-no-android).

Para atualizar o menu e os scripts deste projeto, saia dos agentes e execute:

```sh
cd ~/AI-Termux-Android
git pull --ff-only
bash install.sh
```

O Linux e seus dados sao reaproveitados. Use `--no-menu` novamente se nao
deseja o menu automatico. Comandos personalizados nao sao sobrescritos.

<details>
<summary>Versoes validadas e verificacoes</summary>

O instalador garante pelo menos Codex 0.159.3, Copilot 1.0.90, Claude Code
2.1.286 e OpenCode 1.18.34, versoes validadas no Android. **Versoes iguais ou
mais novas sao mantidas: reexecutar o instalador nunca rebaixa um agente.**
Antigravity segue seu manifesto oficial. Atualizacoes dos fornecedores podem
mudar a compatibilidade. O Hermes Agent opcional tem a versao de referencia
0.22.1 e so e instalado quando voce pede; com ele instalado, `ia atualizar`
tambem o atualiza.

Para conferir as versoes diretamente pelo Termux:

```sh
copilot --version
claude --version
codex --version
antigravity --version
opencode --version
hermes --version
```

O ultimo comando so funciona com o Hermes instalado.

No OpenCode, o instalador executa explicitamente apenas o pos-instalador oficial,
sem liberar scripts globalmente no npm. O download do Antigravity verifica o
dominio do pacote, a versao anunciada e o SHA-512 antes de instalar o binario.
O configurador de aliases e perfis do Antigravity nao e executado.

</details>

## Diagnostico

**Confira o ambiente, os agentes e os logins com um comando no Termux:**

```sh
ia diagnostico
```

Execute na pasta do projeto; a opcao `9` do menu faz o mesmo. O diagnostico
nao chama modelos nem altera seus arquivos e termina com os proximos passos,
como o comando de login de um agente desconectado.

| Parte | O que verifica |
| --- | --- |
| Termux | Versoes do Android, Termux e PRoot-Distro, espaco livre e o Linux em uso |
| Linux | Sistema, Node.js 22+, Git, acesso a internet e gravacao na pasta atual |
| Agentes | Versao e login de cada agente, sem exibir contas, emails ou tokens; o Hermes aparece como opcional enquanto nao for instalado |
| Recursos locais | Situacao do EmbeddingGemma 2 (cache local) e dos servicos `ia web` (painel, terminal e embedding) |
| Protecao | Se o sandbox do Codex funciona e os limites de isolamento do PRoot |

O login e lido do estado local de cada CLI: `codex login status`,
`claude auth status`, a configuracao do Copilot, `opencode auth list`, o token
do Antigravity e, no Hermes, as chaves de provedor do `.env` dele ou
`hermes auth list`. Um token do Copilot em variavel de ambiente tambem conta como
login. Inclua a saida do diagnostico ao [relatar um problema](#ajuda).

## Instalacoes existentes

**Ja usa Ubuntu e um menu `ia` manual no Android?** A adocao passa os comandos
para o menu gerenciado e reaproveita o Ubuntu, sem reinstalar o Linux nem pedir
novos logins. Clone este repositorio, caso ainda nao o tenha, usando o comando da
[instalacao](#instalacao). Depois, no Termux e **fora do Ubuntu**:

```sh
cd ~/AI-Termux-Android
git pull --ff-only
bash install.sh --adopt-ubuntu --check
bash install.sh --adopt-ubuntu
```

- Usa o Ubuntu do PRoot-Distro com o usuario root ja configurado. Contas,
  projetos e agentes em versao igual ou mais nova que a validada sao mantidos.
- Instala Git, GitHub CLI, ripgrep e nano, se faltarem, e os agentes ausentes
  ou abaixo da versao validada. O Ubuntu precisa de Node.js 22 ou superior.
- Substitui `ia` e os comandos dos agentes pelo menu gerenciado. Os anteriores
  ficam em `~/.local/share/termux-ai/adopted/bin`.
- Remove do `~/.bashrc` somente o bloco exato que abria o menu manual e
  acrescenta a linha do menu gerenciado. A copia anterior fica em
  `~/.local/share/termux-ai/bashrc.before`.

A adocao reconhece o menu manual que termina em
`exec proot-distro login ubuntu --work-dir "$PWD"`, links para ele e copias
identicas. Com outro formato ou comandos de outra origem, ela para sem alterar
nada. Depois da adocao, `bash install.sh` atualiza o menu e `ia atualizar`
atualiza os agentes.

<details>
<summary>Desfazer a adocao</summary>

Feche os agentes e execute no Termux para voltar ao menu manual. Somente os
comandos identicos ao menu gerenciado sao trocados pelas copias de seguranca.
O `~/.bashrc` volta a versao anterior a adocao; o atual fica em
`~/.bashrc.termux-ai-undo`, caso voce o tenha alterado depois.

```sh
s=~/.local/share/termux-ai
if grep -qx 'name=ubuntu' "$s/linux.conf" 2>/dev/null; then
    ok=1
    for t in ia codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
        f="$PREFIX/bin/$t"
        b="$s/adopted/bin/$t"
        if [ -f "$s/bin/ia" ] && [ ! -L "$f" ] && cmp -s "$f" "$s/bin/ia"; then
            rm -f "$f" || ok=0
        fi
        if { [ -e "$b" ] || [ -L "$b" ]; } && [ ! -e "$f" ] && [ ! -L "$f" ]; then
            cp -P -p "$b" "$f" || ok=0
        fi
    done
    if [ "$ok" = 1 ] && [ -f "$s/bashrc.before" ]; then
        if [ -f ~/.bashrc ]; then cp -p ~/.bashrc ~/.bashrc.termux-ai-undo || ok=0; fi
        if [ "$ok" = 1 ]; then cp "$s/bashrc.before" ~/.bashrc || ok=0; fi
    fi
    if [ "$ok" = 1 ]; then
        rm -rf "$s"
        echo 'Adocao desfeita. Abra uma nova sessao do Termux.'
    else
        echo "Falha ao desfazer. As copias continuam em $s/adopted/bin."
    fi
else
    echo 'Nenhuma adocao do Ubuntu encontrada; nada foi alterado.'
fi
```

Repetir os comandos nao altera mais nada. Tambem e seguro executa-los apos uma
adocao interrompida: o menu manual e mantido. O Ubuntu, as contas e os agentes
atualizados continuam como estao.

</details>

<details>
<summary>Acrescentar apenas o OpenCode ao menu manual</summary>

Para manter o menu manual e acrescentar somente o OpenCode, sem adotar o Ubuntu:

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

</details>

## Compatibilidade

**Testado no Android, sem root.** Instalacao, menu, atalhos, versao e ajuda
dos cinco agentes verificados. Login e acesso via API nos cinco agentes
tambem foram confirmados pelo usuario.

O projeto atende a **Android 11+ com Termux de 64 bits**. O resultado depende
da configuracao do Android, da versao da CLI e do provedor escolhido.
Autenticar nao garante que toda ferramenta ou sandbox funcione no PRoot.

<details>
<summary>Limites conhecidos e solucao de problemas</summary>

- **Codex:** o sandbox nao funciona no PRoot. O menu e o atalho `codex` abrem o Codex no modo Pedir aprovacao; `codex exec` e `codex review` nao conseguem executar comandos. Veja [Codex no Android](#codex-no-android).
- **OpenCode:** o login foi confirmado; ferramentas, plugins e tarefas dependem do provedor e das permissoes. O menu ainda usa a marcacao experimental para essa integracao.
- **Antigravity:** o login Linux pode depender de Secret Service/D-Bus; persistencia de credenciais nao e garantida em todas as configuracoes PRoot.
- **Hermes Agent:** e opcional e usa o instalador oficial do fornecedor (cerca de 2 GB); sem um provedor configurado com `ia hermes setup`, ele nao responde. Na orquestracao so usa as ferramentas `web` e `search`.
- **Painel e orquestracao:** rodam dentro do Linux, com `tmux` e `ttyd`, em ate 6 sessoes. A orquestracao so le e propoe; nao aplica alteracoes. Com varios agentes abertos, a memoria do aparelho e o limite: o painel recusa novas sessoes com menos de 512 MB livres. Veja tambem as observacoes sobre Android 12+ em [Acesso pelo navegador](#acesso-pelo-navegador).
- **Arquitetura:** um processador de 64 bits com Termux de 32 bits nao atende aos requisitos.
- **Repositorios:** se a sua variante nao oferece PRoot-Distro 5.3.0+, nao misture repositorios para forcar a instalacao.
- **Conflitos:** comandos dos agentes de outra origem nao sao substituidos. Para o menu Ubuntu manual, use a [adocao](#instalacoes-existentes).
- **Interrupcao:** se a execucao anterior ja terminou, volte a `~/AI-Termux-Android` e execute `bash install.sh` novamente. O ambiente gerenciado e reaproveitado. Se houver aviso de `install.lock`, confirme que nao existe outra instalacao ativa antes de agir; nao apague o Linux como tentativa de reparo.

Referencias: [Termux](https://github.com/termux/termux-app#installation),
[PRoot-Distro](https://github.com/termux/proot-distro),
[Antigravity](https://antigravity.google/docs/cli/install) e
[OpenCode](https://opencode.ai/docs/cli/).

</details>

## Ajuda

<details>
<summary>Preciso de PC, cabo USB ou root?</summary>

Nao. Instale diretamente no Termux e use no Android. O projeto nao exige
root, PC, cabo USB ou depuracao USB para instalar e usar os agentes.

</details>

<details>
<summary>Os modelos rodam no aparelho? Posso usar sem internet?</summary>

As CLIs e as ferramentas de desenvolvimento rodam no Android, dentro do Linux
via PRoot. Os modelos dos provedores em nuvem dependem de internet e de uma
conta. O EmbeddingGemma 2 e opcional: depois de instalar suas dependencias,
gera embeddings localmente; o modelo e baixado na primeira inferencia.

</details>

<details>
<summary>O projeto inclui os planos dos provedores?</summary>

Nao. Cada provedor define autenticacao, modelos, limites e cobranca. Ter uma
assinatura em um servico nao conecta nem libera automaticamente os outros.

</details>

**Encontrou um problema?** [Abra uma issue](https://github.com/micheljatuba/AI-Termux-Android/issues/new)
com a saida de `ia diagnostico`, o comando executado e a mensagem de erro. Se a
instalacao nao terminou, informe a versao do Android e do Termux e a arquitetura.
Remova tokens, emails, caminhos pessoais e outros dados privados antes de enviar
logs ou capturas. Informe se e uma instalacao nova ou uma atualizacao.

## Seguranca e backups

Para relatar uma vulnerabilidade de forma privada e conhecer as limitacoes
conhecidas da instalacao, leia [SECURITY.md](SECURITY.md).

> [!WARNING]
> **PRoot nao e um sandbox de seguranca.** Os agentes podem acessar arquivos
> disponiveis ao Termux. Revise as permissoes e mantenha backups dos projetos.

O instalador nao desativa sandboxes, nao habilita aprovacao irrestrita, nao
configura compartilhamento automatico de sessoes e nao abre acesso SSH/ADB.
As permissoes dos agentes seguem os padroes de cada fornecedor. A excecao e o
Codex: sem sandbox no Android, ele abre no modo Pedir aprovacao, que confirma
cada comando ou edicao.

Digite chaves somente no prompt oficial do agente. Nao publique credenciais,
logs privados ou backups. No OpenCode, as credenciais ficam em
`~/.local/share/opencode/auth.json`, dentro do Linux em que ele roda.
O terminal web com menu (`ia web start terminal`) e as sessoes do
painel concedem ao usuario da sessao os mesmos acessos que um shell Linux local;
mantenha-os em `127.0.0.1`, trate os links com token como uma senha e encerre tudo
com `ia web stop` ao terminar (isso tambem encerra as sessoes dos agentes do
painel).

<details>
<summary>Onde ficam os dados e como fazer backup</summary>

O estado do instalador fica em `~/.local/share/termux-ai` no Termux. Quando havia
um arquivo Bash anterior, sua copia e preservada em
`~/.local/share/termux-ai/bashrc.before`. O menu usa apenas uma linha adicional
de carregamento nesse arquivo. Na adocao, os comandos anteriores ficam em
`~/.local/share/termux-ai/adopted/bin`.

Para copiar o Linux dedicado, escolha um nome de arquivo ainda inexistente:

```sh
proot-distro backup termux-ai --output ~/termux-ai-backup.tar.gz
```

No Ubuntu adotado, use `ubuntu` no lugar de `termux-ai`.
Esse backup pode conter credenciais. Guarde-o em local privado. Projetos na
home do Termux, fora do Linux dedicado, precisam de backup separado.
Nao use `proot-distro reset` ou `remove` como reparo sem backup: eles apagam
os dados do ambiente.

</details>

## Desenvolvimento

Os testes exigem Bash, Python 3.10+, Node.js 22+ e utilitarios GNU, incluindo
`tar` e `sha512sum`. Com `tmux` e `ttyd` instalados, os testes do painel tambem
exercitam sessoes reais; sem eles, esses casos sao ignorados.

```sh
python3 -m py_compile scripts/embeddinggemma_cli.py scripts/embeddinggemma_web.py
for file in scripts/hub/*.mjs; do node --check "$file"; done
node --test tests/hub/*.test.mjs
bash tests/run.sh
shellcheck --severity=warning install.sh bin/ia scripts/setup-linux.sh scripts/add-opencode-ubuntu.sh scripts/menu.bash scripts/webui.sh scripts/web-menu.sh scripts/embeddinggemma-launcher.sh scripts/hub/attach.sh tests/run.sh
```

A suite verifica argumentos, conflitos, preservacao de configuracoes,
repeticao da instalacao, validacao de downloads, consulta e atualizacao de
versoes sem rebaixamento, adocao do Ubuntu manual, atualizacao do menu Ubuntu,
diagnostico do ambiente, o modo Pedir aprovacao do Codex, a instalacao opcional
do Hermes e o servico real do painel (token privado, ponte de terminal em
loopback e rotacao do token). Os testes em `tests/hub` cobrem a API do painel,
as sessoes tmux, a orquestracao (comparar, pipeline e maestro, sempre somente
leitura) e a interface.
Execute-a em Linux; no Android, rode-a dentro do Linux do PRoot com `ia terminal`.
Antes de anunciar suporte a uma nova configuracao Android, teste instalacao,
login e uma tarefa controlada em cada agente, sem publicar dados pessoais.

---

Projeto independente de integracao, sob a [licenca MIT](LICENSE). Termux, as CLIs e os servicos de IA
continuam sujeitos as licencas e condicoes dos respectivos fornecedores.

**Mais gente criando com IA no Android.** Marque este repositorio com uma
estrela para encontra-lo depois e compartilhe o guia com quem quer programar
sem depender de um PC.

[Relatar um problema](https://github.com/micheljatuba/AI-Termux-Android/issues/new) &middot; [Ver testes](https://github.com/micheljatuba/AI-Termux-Android/actions) &middot; [Voltar ao topo](#ai-termux-android)
