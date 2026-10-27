#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
web_dir="$HOME/.local/share/termux-ai/web"
hub_dir="$HOME/.local/share/termux-ai/hub"
mkdir -p "$web_dir"
chmod 700 "$web_dir"

panel_port="${TERMUX_AI_PANEL_PORT:-7690}"
panel_ttyd_port="${TERMUX_AI_PANEL_TTYD_PORT:-7681}"
panel_pattern='termux-ai/hub/server.mjs'
panel_ttyd_pattern="ttyd -i 127.0.0.1 -p $panel_ttyd_port"
hub_socket="${TERMUX_AI_HUB_SOCKET:-termux-ai}"
terminal_pattern='ttyd -i lo -p 7680'
embedding_pattern='embeddinggemma_web.py --host 127.0.0.1 --port 8085'
# No Android, outros apps alcancam 127.0.0.1: terminal e embedding exigem o mesmo token do painel.
# Uma instancia de versao anterior, sem token, e reiniciada em vez de reaproveitada.
terminal_token_marker=' -b /'
embedding_token_marker=' --token-file '
token_pattern='^[0-9a-f]{32}$'

fail() {
    printf 'WebUI: %s\n' "$*" >&2
    exit 1
}

service_pid() {
    local name="$1" expected="$2" pid_file="$web_dir/$1.pid" pid
    [[ -f "$pid_file" ]] || return 1
    IFS= read -r pid < "$pid_file" || return 1
    [[ $pid =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$expected" || return 1
    printf '%s\n' "$pid"
}

start_service() {
    local name="$1" expected="$2" port="$3" log_file="$web_dir/$1.log" pid_file="$web_dir/$1.pid"
    shift 3
    local pid=''
    if pid="$(service_pid "$name" "$expected")"; then
        printf '%s ja esta ativo (PID %s, porta %s).\n' "$name" "$pid" "$port"
        return 0
    fi
    rm -f -- "$pid_file"
    nohup "$@" </dev/null >"$log_file" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$pid_file.next"
    mv -f -- "$pid_file.next" "$pid_file"
    for _ in {1..30}; do
        if service_pid "$name" "$expected" >/dev/null; then
            printf '%s iniciado em 127.0.0.1:%s (PID %s).\n' "$name" "$port" "$pid"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    printf 'Falha ao iniciar %s; log: %s\n' "$name" "$log_file" >&2
    cat -- "$log_file" >&2
    rm -f -- "$pid_file"
    return 1
}

stop_service() {
    local name="$1" expected="$2" pid_file="$web_dir/$1.pid" pid
    if ! pid="$(service_pid "$name" "$expected")"; then
        rm -f -- "$pid_file"
        printf '%s nao esta ativo.\n' "$name"
        return 0
    fi
    kill -TERM "$pid"
    for _ in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f -- "$pid_file"
            printf '%s encerrado.\n' "$name"
            return 0
        fi
        sleep 1
    done
    if pid="$(service_pid "$name" "$expected")"; then
        kill -KILL "$pid"
        for _ in {1..5}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                rm -f -- "$pid_file"
                printf '%s encerrado a forca apos nao responder a SIGTERM.\n' "$name" >&2
                return 0
            fi
            sleep 1
        done
    fi
    printf 'O processo de %s nao encerrou; investigue antes de tentar novamente.\n' "$name" >&2
    return 1
}

# PIDs do tmux do painel (servidor e clientes), lidos de /proc. Dentro do PRoot cada instancia so alcanca o tmux da
# propria instancia ("access not allowed" para as outras, com codigo de saida 0), entao nao da para mandar o tmux se
# encerrar: o servidor e identificado pela linha de comando e sinalizado direto.
tmux_pids() {
    local IFS=' ' file argv line first pid
    for file in /proc/[0-9]*/cmdline; do
        { mapfile -d '' -t argv < "$file"; } 2>/dev/null || continue
        line="${argv[*]}"
        first="${line%% *}"
        [[ ${first##*/} == tmux ]] || continue
        [[ ${line#"$first "} == "-L $hub_socket" || ${line#"$first "} == "-L $hub_socket "* ]] || continue
        pid="${file#/proc/}"
        printf '%s\n' "${pid%/cmdline}"
    done
}

# Zumbi conta como encerrado: ele so espera o pai recolher o codigo de saida. Com "read" e nao com $(< arquivo): se o
# processo ja sumiu, o $(< ...) derruba o shell inteiro, mesmo com "|| return 1", e o live_pids pararia nesse PID.
pid_running() {
    local stat
    { read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
    [[ ${stat##*) } != Z* ]]
}

live_pids() {
    local pid
    for pid in "$@"; do
        if pid_running "$pid"; then
            printf '%s\n' "$pid"
        fi
    done
}

# SIGTERM e, para quem nao sair em ~5 s, SIGKILL. Sem sobras o retorno e 0. Nada de substituicao de processo aqui: o
# PRoot nao abre /dev/fd/N e o mapfile falharia dentro do Linux.
kill_tmux() {
    local pids=() list signal
    list="$(tmux_pids)"
    [[ -z $list ]] || mapfile -t pids <<< "$list"
    ((${#pids[@]} > 0)) || return 0
    for signal in TERM KILL; do
        kill "-$signal" "${pids[@]}" 2>/dev/null || true
        for _ in {1..25}; do
            list="$(live_pids "${pids[@]}")"
            pids=()
            [[ -z $list ]] || mapfile -t pids <<< "$list"
            ((${#pids[@]} > 0)) || return 0
            sleep 0.2
        done
    done
    printf 'O tmux do painel nao encerrou (PID %s); investigue antes de tentar novamente.\n' "${pids[*]}" >&2
    return 1
}

stop_tmux() {
    [[ -n "$(tmux_pids)" ]] || return 0
    kill_tmux
    printf '%s\n' 'Sessoes de agente do painel encerradas.'
}

# Um tmux que sobrou de um painel anterior fica inalcancavel para o painel novo (cada ia web start e outra instancia
# do PRoot) e travaria a abertura de sessoes. Um tmux acessivel, como fora do PRoot, e mantido.
drop_blocked_tmux() {
    local reply
    [[ -n "$(tmux_pids)" ]] || return 0
    reply="$(timeout 10 tmux -L "$hub_socket" list-sessions 2>&1 || true)"
    [[ $reply == *'access not allowed'* ]] || return 0
    if kill_tmux; then
        printf '%s\n' 'Um tmux de um painel anterior estava inacessivel nesta instancia do Linux; suas sessoes foram encerradas.'
    fi
}

panel_token() {
    local token_file="$web_dir/token" token=''
    if [[ -f $token_file ]]; then
        IFS= read -r token < "$token_file" || true
    fi
    if [[ ! $token =~ $token_pattern ]]; then
        token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        [[ $token =~ $token_pattern ]] || fail 'Nao foi possivel gerar o token do painel.'
        (umask 077 && printf '%s\n' "$token" > "$token_file.next")
        mv -f -- "$token_file.next" "$token_file"
    fi
    printf '%s\n' "$token"
}

panel_url() {
    printf 'http://127.0.0.1:%s/%s/\n' "$panel_port" "$1"
}

panel_ready() {
    local token="$1"
    for _ in {1..30}; do
        if curl --fail --silent --max-time 2 --output /dev/null "http://127.0.0.1:$panel_port/$token/api/state"; then
            return 0
        fi
        service_pid painel "$panel_pattern" >/dev/null || return 1
        sleep 0.5
    done
    return 1
}

# A ponte de terminal so serve com o painel: se ele nao subiu, nao deixa o ttyd orfao.
drop_panel_ttyd() {
    stop_service painel-ttyd "$panel_ttyd_pattern" >/dev/null || true
}

start_panel() {
    local token hub_file
    command -v node >/dev/null 2>&1 || fail 'node nao encontrado no Linux. Execute novamente bash install.sh no Termux.'
    command -v ttyd >/dev/null 2>&1 || fail 'ttyd nao encontrado no Linux. Execute novamente bash install.sh no Termux.'
    for hub_file in server.mjs index.html attach.sh tmux.conf; do
        [[ -f "$hub_dir/$hub_file" ]] \
            || fail 'Componentes do painel ausentes no Linux. Execute novamente bash install.sh no Termux.'
    done
    if ! command -v tmux >/dev/null 2>&1; then
        printf '%s\n' 'Aviso: tmux nao encontrado no Linux; o painel abre sem terminais ao vivo. Execute novamente bash install.sh no Termux.'
    elif ! service_pid painel "$panel_pattern" >/dev/null; then
        drop_blocked_tmux
    fi
    token="$(panel_token)"
    start_service painel-ttyd "$panel_ttyd_pattern" "$panel_ttyd_port" \
        ttyd -i 127.0.0.1 -p "$panel_ttyd_port" -W -a -b "/$token/t" -m 0 -O \
        -t fontSize=14 -t 'theme={"background":"#0d1117","foreground":"#e6edf3","cursor":"#58a6ff"}' \
        -t disableLeaveAlert=true bash "$hub_dir/attach.sh"
    if ! TERMUX_AI_HUB_ROOT="$PWD" TERMUX_AI_HUB_PORT="$panel_port" TERMUX_AI_HUB_TTYD_PORT="$panel_ttyd_port" \
        start_service painel "$panel_pattern" "$panel_port" node "$hub_dir/server.mjs"; then
        drop_panel_ttyd
        return 1
    fi
    if ! panel_ready "$token"; then
        if service_pid painel "$panel_pattern" >/dev/null; then
            printf '%s\n' 'O painel esta ativo, mas nao respondeu com o token atual; se o token foi trocado, execute: ia web stop' >&2
        else
            printf 'O painel encerrou ao iniciar; log: %s\n' "$web_dir/painel.log" >&2
            tail -n 20 -- "$web_dir/painel.log" >&2 || true
            drop_panel_ttyd
        fi
        return 1
    fi
    printf 'Painel: %s\n' "$(panel_url "$token")"
}

# As sessoes dos agentes vivem no tmux do painel e so existem enquanto ele roda: sem o painel nenhuma instancia nova
# do PRoot as alcanca, entao parar o painel encerra tambem o tmux (e os agentes dentro dele).
stop_panel() {
    stop_service painel "$panel_pattern"
    stop_service painel-ttyd "$panel_ttyd_pattern"
    stop_tmux
}

# Encerra a instancia que ainda roda sem token (versao anterior), para a nova subir protegida.
stop_without_token() {
    local name="$1" expected="$2" marker="$3" pid
    pid="$(service_pid "$name" "$expected")" || return 0
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$marker" && return 0
    printf '%s rodava sem token (versao anterior); reiniciando com token.\n' "$name"
    stop_service "$name" "$expected" > /dev/null
}

terminal_url() {
    printf 'http://127.0.0.1:7680/%s/menu/\n' "$1"
}

embedding_url() {
    printf 'http://127.0.0.1:8085/%s/\n' "$1"
}

start_terminal() {
    local token
    command -v ttyd >/dev/null 2>&1 || fail 'ttyd nao encontrado no Linux. Instale com: apt-get install ttyd'
    token="$(panel_token)"
    stop_without_token terminal "$terminal_pattern" "$terminal_token_marker" || return 1
    start_service terminal "$terminal_pattern" 7680 \
        ttyd -i lo -p 7680 -b "/$token/menu" -W -O -m 1 -t titleFixed='Termux AI' \
        /bin/bash "$HOME/.local/share/termux-ai/web/menu.sh" || return 1
    printf 'Terminal: %s\n' "$(terminal_url "$token")"
}

start_embedding() {
    local python="$HOME/.venv-ai/bin/python3" token
    [[ -x "$python" ]] || fail "Python do EmbeddingGemma nao encontrado: $python"
    "$python" -c 'import fastapi, sentence_transformers, uvicorn' \
        || fail 'Dependencias do EmbeddingGemma incompletas no ambiente virtual.'
    token="$(panel_token)"
    stop_without_token embedding "$embedding_pattern" "$embedding_token_marker" || return 1
    TERMUX_AI_SEARCH_ROOT="$PWD" start_service embedding "$embedding_pattern" 8085 \
        "$python" "$HOME/.local/share/termux-ai/tools/embeddinggemma_web.py" \
        --host 127.0.0.1 --port 8085 --token-file "$web_dir/token" || return 1
    printf 'EmbeddingGemma: %s\n' "$(embedding_url "$token")"
}

start_default() {
    start_panel
    [[ $1 != todos ]] || start_terminal
    if [[ -x "$HOME/.venv-ai/bin/python3" ]]; then
        if ! start_embedding; then
            printf '%s\n' 'Os demais servicos continuam ativos.'
            return 1
        fi
    else
        printf '%s\n' 'EmbeddingGemma nao instalado; para instalar: ia embeddinggemma install'
    fi
}

# Os links carregam o token (e uma senha): so aparecem quando o servico e pedido pelo nome.
print_status() {
    local name="$1" show_link="${2:-}" expected port pid
    case "$name" in
        painel) expected="$panel_pattern"; port="$panel_port" ;;
        terminal) expected="$terminal_pattern"; port=7680 ;;
        embedding) expected="$embedding_pattern"; port=8085 ;;
    esac
    if ! pid="$(service_pid "$name" "$expected")"; then
        printf '%s parado\n' "$name"
    elif [[ $name == painel && $show_link == link ]]; then
        printf 'painel ativo: %s (PID %s)\n' "$(panel_url "$(panel_token)")" "$pid"
    elif [[ $name == painel ]]; then
        printf 'painel ativo (PID %s); para ver o link: ia web status painel\n' "$pid"
    elif [[ $show_link == link ]]; then
        printf '%s ativo: %s (PID %s)\n' "$name" "$("${name}_url" "$(panel_token)")" "$pid"
    else
        printf '%s ativo em 127.0.0.1:%s (PID %s); para ver o link: ia web status %s\n' "$name" "$port" "$pid" "$name"
    fi
}

action="${1:-}"
# O proot-distro so volta quando o ultimo processo do Linux termina, e os servicos ficam ativos de proposito.
# Com --marcador a ultima linha da saida e "__WEBUI_FIM__ <status>", e o launcher le o fim do script por ela.
if [[ ${3:-} == --marcador ]]; then
    trap 'printf "__WEBUI_FIM__ %s\n" "$?"' EXIT
fi
case "$action" in
    start) target="${2:-padrao}" ;;
    stop|status) target="${2:-todos}" ;;
    *) fail 'Uso interno: webui.sh {start|stop|status} [padrao|painel|terminal|embedding|todos]' ;;
esac

case "$action:$target" in
    start:padrao|start:todos) start_default "$target" ;;
    start:painel) start_panel ;;
    start:terminal) start_terminal ;;
    start:embedding) start_embedding ;;
    stop:todos)
        stop_service embedding "$embedding_pattern"
        stop_service terminal "$terminal_pattern"
        stop_panel
        ;;
    stop:painel) stop_panel ;;
    stop:terminal) stop_service terminal "$terminal_pattern" ;;
    stop:embedding) stop_service embedding "$embedding_pattern" ;;
    status:todos)
        for name in painel terminal embedding; do
            print_status "$name"
        done
        ;;
    status:painel) print_status painel link ;;
    status:terminal|status:embedding) print_status "$target" link ;;
    *) fail "Alvo invalido para $action: $target" ;;
esac
