#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
web_dir="$HOME/.local/share/termux-ai/web"
mkdir -p "$web_dir"
chmod 700 "$web_dir"

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

start_terminal() {
    command -v ttyd >/dev/null 2>&1 || fail 'ttyd nao encontrado no Linux. Instale com: apt-get install ttyd'
    start_service terminal 'ttyd -i lo -p 7680' 7680 \
        ttyd -i lo -p 7680 -W -O -m 1 -t titleFixed='Termux AI' \
        /bin/bash "$HOME/.local/share/termux-ai/web/menu.sh"
}

start_embedding() {
    local python="$HOME/.venv-ai/bin/python3"
    [[ -x "$python" ]] || fail "Python do EmbeddingGemma nao encontrado: $python"
    "$python" -c 'import fastapi, sentence_transformers, uvicorn' \
        || fail 'Dependencias do EmbeddingGemma incompletas no ambiente virtual.'
    TERMUX_AI_SEARCH_ROOT="$PWD" start_service embedding 'embeddinggemma_web.py --host 127.0.0.1 --port 8085' 8085 \
        "$python" "$HOME/.local/share/termux-ai/tools/embeddinggemma_web.py" \
        --host 127.0.0.1 --port 8085
}

case "${1:-}" in
    start)
        case "${2:-both}" in
            both)
                start_terminal
                if ! start_embedding; then
                    printf '%s\n' 'O terminal continua ativo em http://127.0.0.1:7680'
                    exit 1
                fi
                ;;
            terminal) start_terminal ;;
            embedding) start_embedding ;;
            *) fail 'Uso interno: start [both|terminal|embedding]' ;;
        esac
        ;;
    stop)
        case "${2:-both}" in
            both)
                stop_service embedding 'embeddinggemma_web.py --host 127.0.0.1 --port 8085'
                stop_service terminal 'ttyd -i lo -p 7680'
                ;;
            terminal) stop_service terminal 'ttyd -i lo -p 7680' ;;
            embedding) stop_service embedding 'embeddinggemma_web.py --host 127.0.0.1 --port 8085' ;;
            *) fail 'Uso interno: stop [both|terminal|embedding]' ;;
        esac
        ;;
    status)
        case "${2:-both}" in
            terminal) names=(terminal) ;;
            embedding) names=(embedding) ;;
            both) names=(terminal embedding) ;;
            *) fail 'Uso interno: status [both|terminal|embedding]' ;;
        esac
        for name in "${names[@]}"; do
            case "$name" in
                terminal) expected='ttyd -i lo -p 7680'; port=7680 ;;
                embedding) expected='embeddinggemma_web.py --host 127.0.0.1 --port 8085'; port=8085 ;;
            esac
            if pid="$(service_pid "$name" "$expected")"; then
                printf '%s ativo: http://127.0.0.1:%s (PID %s)\n' "$name" "$port" "$pid"
            else
                printf '%s parado\n' "$name"
            fi
        done
        ;;
    *)
        fail 'Uso interno: webui.sh {start|stop|status} [both|terminal|embedding]'
        ;;
esac
