#!/usr/bin/env bash
set -euo pipefail

while true; do
    printf '\nTermux AI - Linux\n\n1. GitHub Copilot\n2. Claude Code\n3. Codex (Pedir aprovacao)\n4. Terminal Linux\n5. Google Antigravity CLI\n6. OpenCode\n0. Sair\n\n'
    if ! read -r -p 'Escolha: ' selection; then
        exit 0
    fi
    case "$selection" in
        1) copilot ;;
        2) claude ;;
        3) codex -s workspace-write -a on-request ;;
        4) exec /bin/bash --login ;;
        5) agy ;;
        6) opencode ;;
        0) exit 0 ;;
        *) printf '%s\n' 'Opcao invalida.' >&2 ;;
    esac
done
