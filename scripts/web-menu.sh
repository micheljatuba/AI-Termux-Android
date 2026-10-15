#!/usr/bin/env bash
set -euo pipefail

setup_script="$HOME/.local/share/termux-ai/setup-linux.sh"

display_name() {
    case "$1" in
        copilot) printf '%s' 'GitHub Copilot' ;;
        claude) printf '%s' 'Claude Code' ;;
        codex) printf '%s' 'Codex' ;;
        agy) printf '%s' 'Antigravity CLI' ;;
        opencode) printf '%s' 'OpenCode' ;;
        hermes) printf '%s' 'Hermes Agent' ;;
        embeddinggemma) printf '%s' 'EmbeddingGemma 2' ;;
    esac
}

status_label() {
    case "$1" in
        current) printf '%s' 'atualizado' ;;
        outdated) printf '%s' 'atualizacao disponivel' ;;
        missing)
            if [[ $2 == hermes ]]; then
                printf '%s' 'nao instalado (opcional)'
            else
                printf '%s' 'nao instalado'
            fi
            ;;
        unknown) printf '%s' 'sem consulta' ;;
    esac
}

web_update_agents() {
    local output marker tool installed latest status answer
    local -a rows=() plan=()
    if [[ ! -f "$setup_script" ]]; then
        printf '%s\n' 'Script de manutencao ausente. Execute bash install.sh no Termux.' >&2
        return 1
    fi
    printf '%s\n' 'Consultando versoes dos agentes...'
    output="$(bash "$setup_script" versions)" || return 1
    printf '\n%-16s %-12s %-12s %s\n' 'Agente' 'Instalada' 'Disponivel' 'Situacao'
    while IFS=$'\t' read -r marker tool installed latest status; do
        [[ $marker == @version ]] || continue
        rows+=("$tool $installed $latest $status")
        printf '%-16s %-12s %-12s %s\n' "$(display_name "$tool")" "$installed" "$latest" "$(status_label "$status" "$tool")"
        if [[ $latest != - && ( $status == outdated || ( $status == missing && $tool != hermes ) ) ]]; then
            plan+=("$tool $installed $latest")
        fi
    done <<< "$output"
    if (( ${#plan[@]} == 0 )); then
        printf '\n%s\n' 'Todos os agentes consultados estao atualizados.'
        return 0
    fi
    read -r -p $'\nAtualizar os agentes disponiveis agora? [s/N] ' answer || answer=''
    case "$answer" in
        s|S|sim|SIM|y|Y|yes) ;;
        *) printf '%s\n' 'Atualizacao cancelada.'; return 0 ;;
    esac
    for row in "${plan[@]}"; do
        read -r tool installed latest <<< "$row"
        printf '\n== %s %s -> %s ==\n' "$(display_name "$tool")" "$installed" "$latest"
        bash "$setup_script" update "$tool" "$latest" || true
    done
}

web_show_diagnostics() {
    local output marker kind name status detail
    if [[ ! -f "$setup_script" ]]; then
        printf '%s\n' 'Script de diagnostico ausente. Execute bash install.sh no Termux.' >&2
        return 1
    fi
    printf '%s\n' 'Executando diagnostico no Linux...'
    output="$(bash "$setup_script" diagnose "$PWD")" || return 1
    printf '\n%-18s %-14s %s\n' 'Componente' 'Situacao' 'Detalhe'
    while IFS=$'\t' read -r marker kind name status detail; do
        [[ $marker == @diag ]] || continue
        printf '%-18s %-14s %s\n' "$kind:$name" "$status" "$detail"
    done <<< "$output"
}

web_hermes() {
    if command -v hermes >/dev/null 2>&1; then
        hermes
    else
        printf '%s\n' 'Hermes Agent e opcional e nao esta instalado (cerca de 2 GB). No Termux, rode: ia atualizar hermes'
    fi
}

while true; do
    printf '\nTermux AI - Linux\n\n1. GitHub Copilot\n2. Claude Code\n3. Codex (Pedir aprovacao)\n4. Terminal Linux\n5. Google Antigravity CLI\n6. OpenCode\n7. EmbeddingGemma 2 (local, opcional)\n8. Versoes e atualizacoes dos agentes\n9. Diagnostico do ambiente\n10. Hermes Agent (opcional)\n0. Sair\n\n'
    if ! read -r -p 'Escolha: ' selection; then
        exit 0
    fi
    case "$selection" in
        1) copilot || true ;;
        2) claude || true ;;
        3) codex -s workspace-write -a on-request || true ;;
        4) exec /bin/bash --login ;;
        5) agy || true ;;
        6) opencode || true ;;
        7) embeddinggemma || true ;;
        8) web_update_agents || true ;;
        9) web_show_diagnostics || true ;;
        10) web_hermes || true ;;
        0) exit 0 ;;
        *) printf '%s\n' 'Opcao invalida.' >&2 ;;
    esac
done
