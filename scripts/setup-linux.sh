#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    system)
        [[ $(id -u) == 0 ]] || { printf '%s\n' 'Esta etapa exige o root simulado do PRoot.' >&2; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl git gh ripgrep nano
        ;;
    agents)
        [[ $(id -u) != 0 && ${USER:-} == node ]] || { printf '%s\n' 'Esta etapa deve rodar como o usuario node do Linux dedicado.' >&2; exit 1; }
        umask 077
        export PATH="$HOME/.local/bin:$PATH"
        node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)'
        mkdir -p "$HOME/.local/bin"
        npm install -g --prefix "$HOME/.local" @openai/codex@0.154.0 @github/copilot@1.0.83
        claude_installer="$(mktemp)"
        trap 'rm -f -- "$claude_installer"' EXIT
        curl --fail --show-error --location --proto '=https' --tlsv1.2 \
            --output "$claude_installer" https://claude.ai/install.sh
        bash "$claude_installer" 2.1.269
        profile_entry='export PATH="$HOME/.local/bin:$PATH"'
        if [[ ! -f "$HOME/.profile" ]] || ! grep -Fqx "$profile_entry" "$HOME/.profile"; then
            if [[ -f "$HOME/.profile" && ! -e "$HOME/.profile.termux-ai.before" ]]; then
                cp -p -- "$HOME/.profile" "$HOME/.profile.termux-ai.before"
            fi
            printf '\n%s\n' "$profile_entry" >> "$HOME/.profile"
        fi
        for tool_name in codex copilot claude; do
            timeout 60s "$HOME/.local/bin/$tool_name" --version
        done
        ;;
    *) printf '%s\n' 'Etapa interna desconhecida. Use install.sh no Termux.' >&2; exit 2 ;;
esac