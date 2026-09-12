#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

assume_yes=0
case "${1:-}" in
    --help|-h)
        printf '%s\n' 'Uso: bash scripts/add-opencode-ubuntu.sh [--yes]' \
            'Acrescenta apenas OpenCode ao menu Ubuntu manual com Antigravity na opcao 5.'
        exit 0
        ;;
    --yes) assume_yes=1 ;;
    '') ;;
    *) fail 'Opcao desconhecida. Use --help.' ;;
esac
(( $# <= 1 )) || fail 'Argumentos em excesso. Use --help.'
[[ -n ${PREFIX:-} && -x "$PREFIX/bin/pkg" && ${TERMUX_AI_GUEST:-0} != 1 && $(id -u) != 0 ]] || fail 'Execute no Termux, fora do Ubuntu.'
command -v proot-distro >/dev/null 2>&1 || fail 'PRoot-Distro nao encontrado.'
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$script_dir/setup-linux.sh" ]] || fail 'Baixe o repositorio completo antes de executar este complemento.'
launcher="$PREFIX/bin/ia"
[[ -f "$launcher" && ! -L "$launcher" ]] || fail 'Menu ia manual nao encontrado como arquivo regular.'
[[ ! -e "$HOME/.local/share/termux-ai/owner" ]] || fail 'Instalacao gerenciada: use bash install.sh no lugar deste complemento.'
grep -Fq 'exec proot-distro login ubuntu --work-dir "$PWD" -- /bin/bash -lc ' "$launcher" || fail 'O menu existente nao usa o Ubuntu manual esperado.'
bash -n "$launcher"

if [[ -e "$PREFIX/bin/opencode" || -L "$PREFIX/bin/opencode" ]]; then
    if [[ ! -L "$PREFIX/bin/opencode" ]] && cmp -s "$launcher" "$PREFIX/bin/opencode" \
        && grep -Fq '6) tool_name=opencode ;;' "$launcher" \
        && grep -Fq '\n6. OpenCode (experimental)\n' "$launcher"; then
        bash "$launcher" opencode --version
        printf '%s\n' 'OpenCode ja esta integrado. Nenhum menu foi alterado.'
        exit 0
    fi
    fail 'O comando opencode ja existe e nao pertence a este complemento.'
fi

umask 077
work_dir="$(mktemp -d "$PREFIX/bin/.opencode-update.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
cp -p -- "$launcher" "$work_dir/ia.before"
if ! awk '
    /\\n5[.] Google Antigravity CLI \(experimental\)\\n0[.] Sair/ {
        position = index($0, "\\n0. Sair")
        $0 = substr($0, 1, position - 1) "\\n6. OpenCode (experimental)" substr($0, position)
        menus++
    }
    /^[[:space:]]*5\) tool_name=agy ;;[[:space:]]*$/ {
        print
        sub(/5\) tool_name=agy/, "6) tool_name=opencode")
        choices++
    }
    /^[[:space:]]*codex\|copilot\|claude\) ;;[[:space:]]*$/ {
        sub(/claude\)/, "claude|opencode)")
        dispatches++
    }
    {
        gsub(/antigravity\|agy\|ubuntu/, "antigravity|agy|opencode|ubuntu")
        gsub(/antigravity, agy ou ubuntu/, "antigravity, agy, opencode ou ubuntu")
        print
    }
    END { if (menus != 1 || choices != 1 || dispatches != 1) exit 1 }
' "$work_dir/ia.before" > "$work_dir/ia"; then
    fail 'Formato de menu nao reconhecido. Nada foi instalado nem substituido.'
fi
bash -n "$work_dir/ia"

printf '%s\n' 'Sera instalado apenas OpenCode 1.18.30 no Ubuntu existente.' \
    'A opcao 6 sera acrescentada ao menu; contas e outros agentes nao serao reconfigurados.' \
    'Login e tarefas do OpenCode ainda precisam de teste neste Android/PRoot.'
if (( ! assume_yes )); then
    [[ -t 0 ]] || fail 'Sem entrada interativa. Revise o complemento e use --yes para confirmar.'
    read -r -p 'Continuar? [s/N] ' answer
    case "$answer" in
        s|S|sim|SIM|y|Y|yes) ;;
        *) printf '%s\n' 'Cancelado.'; exit 0 ;;
    esac
fi

proot-distro login ubuntu -- /bin/bash -se -- opencode < "$script_dir/setup-linux.sh"
bash "$work_dir/ia" opencode --version
[[ ! -L "$launcher" ]] && cmp -s "$launcher" "$work_dir/ia.before" || fail 'O menu mudou durante a instalacao; nao sera substituido.'
[[ ! -e "$PREFIX/bin/opencode" && ! -L "$PREFIX/bin/opencode" ]] || fail 'Outro comando opencode apareceu; nao sera substituido.'
mkdir -p "$HOME/.cache"
backup_dir="$(mktemp -d "$HOME/.cache/termux-ai-opencode.XXXXXX")"
cp -p -- "$work_dir/ia.before" "$backup_dir/ia"
cp -- "$work_dir/ia" "$work_dir/opencode"
chmod 755 "$work_dir/ia" "$work_dir/opencode"
mv -- "$work_dir/ia" "$launcher"
mv -n -- "$work_dir/opencode" "$PREFIX/bin/opencode"
[[ ! -e "$work_dir/opencode" ]] || fail 'Conflito ao criar o atalho; use ia opencode e verifique o comando existente.'
printf '\nOpenCode integrado. Execute ia e escolha 6, ou use opencode.\nMenu anterior: %s/ia\n' "$backup_dir"