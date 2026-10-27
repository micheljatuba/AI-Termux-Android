#!/usr/bin/env bash
# Comando do ttyd do painel: anexa a uma sessao tmux ja existente.
set -u

name=${1-}
if [[ ! $name =~ ^ia-[a-z0-9]+-[0-9]{1,3}$ ]]; then
    printf 'Sessao invalida.\n'
    sleep 3
    exit 1
fi

exec tmux -L "${TERMUX_AI_HUB_SOCKET:-termux-ai}" -u attach-session -t "=$name"
