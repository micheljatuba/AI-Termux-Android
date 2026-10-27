#!/usr/bin/env bash
set -euo pipefail

venv_dir="$HOME/.venv-ai"
cli_script="$HOME/.local/share/termux-ai/tools/embeddinggemma_cli.py"

if [[ ! -x "$venv_dir/bin/python3" ]]; then
    printf '%s\n' 'EmbeddingGemma nao instalado. Execute ia embeddinggemma install no Termux.' >&2
    exit 1
fi
if [[ ! -f "$cli_script" ]]; then
    printf '%s\n' 'CLI EmbeddingGemma ausente. Atualize o repositorio e execute bash install.sh.' >&2
    exit 1
fi

exec "$venv_dir/bin/python3" "$cli_script" "$@"
