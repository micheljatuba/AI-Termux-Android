#!/usr/bin/env bash
# LFM3 (Liquid AI) local no Termux, fora do PRoot: o pacote llama-cpp do Termux (0.8.0+) ja reconhece a arquitetura LFM3.
# Uso: ia lfm3 [chat|instalar|servidor|token|status|remover] [opcoes]
set -euo pipefail

state_dir="$HOME/.local/share/termux-ai"
lfm3_dir="$state_dir/lfm3"
cache_dir="$lfm3_dir/modelos"
config_file="$lfm3_dir/lfm3.conf"
token_file="$lfm3_dir/token"
default_repo='LiquidAI/LFM3-1.7B-GGUF'
repo_pattern='^LiquidAI/LFM3-[A-Za-z0-9._-]{1,40}-GGUF$'
quant_pattern='^[A-Za-z0-9_]{1,16}$'
min_package=0.8.0
package_version=''
min_build=11960
min_free_kib=$((3 * 1024 * 1024))
low_ram_kib=$((3 * 1024 * 1024))
default_port=8086

usage() {
    printf '%s\n' \
        'Uso: ia lfm3 [chat]                 conversa com o LFM3 no aparelho, sem internet' \
        '     ia lfm3 instalar [--sim] [--modelo LiquidAI/LFM3-...-GGUF] [--quant Q4_K_M]' \
        '     ia lfm3 servidor [--porta 8086]  API compativel com OpenAI em 127.0.0.1, com token' \
        '     ia lfm3 token                    mostra o token do servidor' \
        '     ia lfm3 status' \
        '     ia lfm3 remover [--sim]          apaga o modelo baixado' \
        'Licenca do modelo: LFM Open License v1.0 (gratuita abaixo de US$ 10 milhoes de receita anual).'
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    (( assume_yes )) && return 0
    [[ -t 0 ]] || fail 'Confirme com --sim fora de um terminal interativo.'
    read -r -p "$1 [s/N] " answer || return 1
    [[ $answer == [sS] || $answer == [sS][iI][mM] ]]
}

require_termux() {
    [[ ${TERMUX_AI_GUEST:-} != 1 ]] || fail 'Use ia lfm3 no Termux, fora do Linux.'
    [[ -n ${PREFIX:-} && -x "$PREFIX/bin/pkg" ]] || fail 'O LFM3 roda no Termux para Android.'
}

# lfm3.conf e lido como dados, nunca executado.
load_config() {
    local key value
    repo="$default_repo"
    quant=''
    [[ -f $config_file ]] || return 0
    while IFS='=' read -r key value; do
        if [[ $key == repo && $value =~ $repo_pattern ]]; then
            repo="$value"
        elif [[ $key == quant && $value =~ $quant_pattern ]]; then
            quant="$value"
        fi
    done < "$config_file"
}

save_config() {
    mkdir -p "$lfm3_dir"
    chmod 700 "$lfm3_dir"
    printf 'repo=%s\nquant=%s\n' "$repo" "$quant" > "$config_file.next"
    chmod 600 "$config_file.next"
    mv -f -- "$config_file.next" "$config_file"
}

model_ref() {
    if [[ -n $quant ]]; then
        printf '%s:%s' "$repo" "$quant"
    else
        printf '%s' "$repo"
    fi
}

# Versao a >= b, com numeros separados por ponto.
version_at_least() {
    local IFS=. index
    local -a left right
    read -r -a left <<< "$1"
    read -r -a right <<< "$2"
    for index in 0 1 2; do
        (( 10#${left[index]:-0} > 10#${right[index]:-0} )) && return 0
        (( 10#${left[index]:-0} < 10#${right[index]:-0} )) && return 1
    done
    return 0
}

# O pacote do Termux traz a versao do llama.cpp: 0.8.0 (= build 11960) e a primeira com LFM3. Os pacotes antigos usam
# 0.0.0-bNNNN, com o numero do build.
llama_supports_lfm3() {
    local build
    package_version="$(dpkg-query -W -f='${Version}' llama-cpp 2> /dev/null || true)"
    if [[ $package_version =~ ^0\.0\.0-b([0-9]+)(-[0-9]+)?$ ]]; then
        (( 10#${BASH_REMATCH[1]} >= min_build ))
        return
    fi
    if [[ $package_version =~ ^([0-9]+(\.[0-9]+){1,2})(-[0-9]+)?$ ]]; then
        version_at_least "${BASH_REMATCH[1]}" "$min_package"
        return
    fi
    build="$(llama-cli --version 2>&1 | grep -Eo 'version: [0-9]+' | head -n 1 || true)"
    build="${build#version: }"
    [[ $build =~ ^[0-9]+$ ]] && (( build >= min_build ))
}

# Um espelho desatualizado entrega um llama-cpp antigo mesmo depois de pkg upgrade.
old_llama_hint() {
    printf '%s\n' \
        "Este llama-cpp (${package_version:-versao desconhecida}) nao reconhece o LFM3: precisa da versao $min_package ou mais nova." \
        'O espelho do Termux pode estar desatualizado. Troque de espelho e atualize:' \
        '  termux-change-repo   (escolha outro espelho)' \
        '  pkg update && pkg install llama-cpp' \
        'Depois rode de novo: ia lfm3 instalar' >&2
}

model_present() {
    [[ -d $cache_dir ]] && find "$cache_dir" -type f -name '*.gguf' -print -quit 2> /dev/null | grep -q .
}

ensure_private_dirs() {
    mkdir -p "$cache_dir"
    chmod 700 "$lfm3_dir" "$cache_dir"
}

ensure_token() {
    ensure_private_dirs
    if [[ ! -s $token_file ]] || ! grep -Eqx '[0-9a-f]{64}' "$token_file"; then
        (umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$token_file.next")
        mv -f -- "$token_file.next" "$token_file"
    fi
    chmod 600 "$token_file"
}

parse_options() {
    assume_yes=0
    port="$default_port"
    new_repo=''
    new_quant=''
    while (( $# > 0 )); do
        case "$1" in
            --sim|--yes|-y) assume_yes=1 ;;
            --modelo) new_repo="${2:-}"; shift ;;
            --quant) new_quant="${2:-}"; shift ;;
            --porta) port="${2:-}"; shift ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done
    [[ -z $new_repo || $new_repo =~ $repo_pattern ]] || fail 'Modelo invalido: use um repositorio LiquidAI/LFM3-...-GGUF.'
    [[ -z $new_quant || $new_quant =~ $quant_pattern ]] || fail 'Quantizacao invalida (exemplo: Q4_K_M).'
    [[ $port =~ ^[0-9]{4,5}$ ]] && (( port >= 1024 && port <= 65535 )) || fail 'Porta invalida: use de 1024 a 65535.'
}

cmd_install() {
    local free_kib ram_kib
    [[ -z $new_repo ]] || repo="$new_repo"
    [[ -z $new_quant ]] || quant="$new_quant"
    free_kib="${TERMUX_AI_TEST_FREE_KIB:-$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')}"
    [[ $free_kib =~ ^[0-9]+$ ]] && (( free_kib >= min_free_kib )) \
        || fail 'Espaco insuficiente: o LFM3 precisa de cerca de 3 GB livres.'
    ram_kib="${TERMUX_AI_TEST_RAM_KIB:-$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2> /dev/null || true)}"
    printf '%s\n' \
        "LFM3 (Liquid AI): $(model_ref), roda no aparelho, sem conta e sem enviar dados." \
        'Sera instalado o pacote llama-cpp do Termux e baixado o modelo (cerca de 1 a 2 GB) do Hugging Face.' \
        'Licenca: LFM Open License v1.0, gratuita para uso pessoal e empresas abaixo de US$ 10 milhoes de receita anual.' \
        "  Leia antes de uso comercial: https://huggingface.co/$repo"
    if [[ $ram_kib =~ ^[0-9]+$ ]] && (( ram_kib < low_ram_kib )); then
        printf '%s\n' 'Aviso: menos de 3 GB de RAM; o Android pode encerrar o modelo. Prefira --quant Q4_0.'
    fi
    confirm 'Instalar o LFM3?' || fail 'Nada foi instalado.'
    "$PREFIX/bin/pkg" install -y llama-cpp
    command -v llama-cli > /dev/null 2>&1 && command -v llama-server > /dev/null 2>&1 \
        || fail 'O pacote llama-cpp nao instalou llama-cli e llama-server.'
    if ! llama_supports_lfm3; then
        old_llama_hint
        exit 1
    fi
    ensure_private_dirs
    save_config
    printf '%s\n' 'Baixando o modelo; pode levar alguns minutos.'
    LLAMA_CACHE="$cache_dir" llama-cli -hf "$(model_ref)" -no-cnv -p 'ok' -n 1 --log-disable > /dev/null \
        || fail 'O download do modelo falhou. Confira a internet e rode novamente: ia lfm3 instalar'
    model_present || fail 'O modelo nao apareceu na pasta do LFM3 depois do download.'
    printf '%s\n' 'LFM3 pronto. Converse com: ia lfm3   API local: ia lfm3 servidor'
}

require_model() {
    command -v llama-cli > /dev/null 2>&1 || fail 'LFM3 nao instalado (e opcional). Rode: ia lfm3 instalar'
    model_present || fail 'Modelo LFM3 nao baixado. Rode: ia lfm3 instalar'
}

cmd_chat() {
    require_model
    # --offline: depois da instalacao nada sai do aparelho, nem a checagem de versao do modelo.
    LLAMA_CACHE="$cache_dir" exec llama-cli -hf "$(model_ref)" --offline --jinja -c 4096
}

# Outros apps do Android alcancam 127.0.0.1: a API exige o token e a interface web do llama-server fica desligada.
cmd_server() {
    require_model
    command -v llama-server > /dev/null 2>&1 || fail 'llama-server ausente. Rode: ia lfm3 instalar'
    ensure_token
    printf '%s\n' \
        "LFM3 em http://127.0.0.1:$port/v1 (compativel com OpenAI)." \
        'Token: ia lfm3 token  (envie como Authorization: Bearer <token>). Ctrl+C encerra.' >&2
    LLAMA_CACHE="$cache_dir" exec llama-server -hf "$(model_ref)" --offline --jinja -c 4096 \
        --host 127.0.0.1 --port "$port" --api-key-file "$token_file" --no-webui
}

cmd_token() {
    [[ -s $token_file ]] || fail 'Sem token ainda: ele e criado no primeiro ia lfm3 servidor.'
    cat -- "$token_file"
    printf '\n'
}

cmd_status() {
    if command -v llama-cli > /dev/null 2>&1 && llama_supports_lfm3; then
        printf '%s\n' 'llama-cpp: instalado, com suporte ao LFM3'
    elif command -v llama-cli > /dev/null 2>&1; then
        printf '%s\n' "llama-cpp: ${package_version:-versao antiga}, sem LFM3 (precisa de $min_package+); troque o espelho com termux-change-repo e rode pkg update"
    else
        printf '%s\n' 'llama-cpp: nao instalado'
    fi
    if model_present; then
        printf 'Modelo: %s (baixado)\n' "$(model_ref)"
    else
        printf '%s\n' 'Modelo: nao baixado. Rode: ia lfm3 instalar'
    fi
    printf 'Pasta: %s\n' "$lfm3_dir"
}

cmd_remove() {
    [[ -d $cache_dir ]] || { printf '%s\n' 'Nenhum modelo LFM3 baixado.'; return 0; }
    confirm "Apagar os modelos em $cache_dir?" || fail 'Nada foi apagado.'
    rm -rf -- "$cache_dir"
    printf '%s\n' 'Modelo apagado. O pacote llama-cpp continua; remova com: pkg uninstall llama-cpp'
}

command_name="${1:-chat}"
(( $# == 0 )) || shift
case "$command_name" in
    -h|--help|--ajuda|ajuda) usage; exit 0 ;;
esac
require_termux
parse_options "$@"
load_config
case "$command_name" in
    chat|conversar) cmd_chat ;;
    instalar|install) cmd_install ;;
    servidor|server|serve) cmd_server ;;
    token) cmd_token ;;
    status) cmd_status ;;
    remover|remove) cmd_remove ;;
    *) usage >&2; exit 2 ;;
esac
