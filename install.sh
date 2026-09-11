#!/usr/bin/env bash
set -euo pipefail

show_help() {
    printf '%s\n' \
        'Uso: bash install.sh [--check] [--yes] [--no-menu]' \
        '  --check    Verifica o aparelho sem instalar nem alterar arquivos.' \
        '  --yes      Confirma a instalacao sem uma pergunta interativa.' \
        '  --no-menu  Nao abre o menu automaticamente nas sessoes Bash.'
}

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

check_only=0
assume_yes=0
enable_menu=1
for argument in "$@"; do
    case "$argument" in
        --check) check_only=1 ;;
        --yes) assume_yes=1 ;;
        --no-menu) enable_menu=0 ;;
        --help|-h) show_help; exit 0 ;;
        *) show_help >&2; exit 2 ;;
    esac
done

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -n ${PREFIX:-} && -x "$PREFIX/bin/pkg" ]] || fail 'Execute no Termux para Android, fora do Ubuntu/PRoot.'
[[ ${TERMUX_AI_GUEST:-0} != 1 && $(id -u) != 0 ]] || fail 'Execute no Termux, sem root e fora do Linux convidado.'
command -v getprop >/dev/null 2>&1 || fail 'Android nao detectado. iOS/App Store nao e suportado.'
android_sdk="$(getprop ro.build.version.sdk)"
[[ "$android_sdk" =~ ^[0-9]+$ ]] || fail 'Nao foi possivel identificar a versao do Android.'
(( android_sdk >= 30 )) || fail 'Esta versao do instalador exige Android 11 ou superior.'
architecture="$(dpkg --print-architecture)"
case "$architecture" in
    aarch64|x86_64) ;;
    *) fail "Arquitetura $architecture nao suportada. E necessario Termux de 64 bits (ARM64 ou x86_64)." ;;
esac
available_kib="$(df -Pk "$PREFIX" | awk 'NR == 2 { print $4 }')"
[[ "$available_kib" =~ ^[0-9]+$ ]] || fail 'Nao foi possivel verificar o espaco livre.'
(( available_kib >= 6 * 1024 * 1024 )) || fail 'Reserve pelo menos 6 GiB livres para instalar e atualizar os agentes.'

state_dir="$HOME/.local/share/termux-ai"
container_dir="${TERMUX__PREFIX:-$PREFIX}/var/lib/proot-distro/containers/termux-ai"
legacy_dir="${TERMUX__PREFIX:-$PREFIX}/var/lib/proot-distro/installed-rootfs/termux-ai"
owner_id='termux-ai-installer-v1'
if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ ! -L "$state_dir" && -f "$state_dir/owner" ]] || fail "A pasta $state_dir ja existe e nao pertence a este instalador."
    [[ $(< "$state_dir/owner") == "$owner_id" ]] || fail 'Identificador de instalacao desconhecido; nada sera sobrescrito.'
fi
if [[ -e "$container_dir" || -L "$container_dir" || -e "$legacy_dir" || -L "$legacy_dir" ]]; then
    [[ -f "$state_dir/container.managed" ]] || fail 'Ja existe um Linux chamado termux-ai que nao foi concluido por este instalador. Preserve seus dados antes de resolver o conflito.'
fi
for tool_name in ia codex copilot claude antigravity agy; do
    target="$PREFIX/bin/$tool_name"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ ! -L "$target" && -f "$state_dir/bin/ia" ]] || fail "O comando $tool_name ja existe. Nao sera substituido."
        cmp -s "$target" "$state_dir/bin/ia" || fail "O comando $tool_name ja existe ou foi personalizado. Nao sera substituido."
    fi
done
if (( enable_menu )) && [[ -e "$HOME/.bashrc" || -L "$HOME/.bashrc" ]]; then
    [[ -f "$HOME/.bashrc" && ! -L "$HOME/.bashrc" ]] || fail 'A configuracao Bash nao e um arquivo comum; use --no-menu.'
    bash -n "$HOME/.bashrc" || fail 'Corrija a sintaxe da configuracao Bash ou use --no-menu.'
fi
for relative_path in bin/ia scripts/setup-linux.sh scripts/menu.bash; do
    [[ -f "$project_root/$relative_path" ]] || fail 'Baixe o repositorio completo antes de executar install.sh.'
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        fail "O arquivo $relative_path precisa de finais de linha LF."
    fi
done

printf 'Android API %s; arquitetura %s; espaco livre suficiente.\n' "$android_sdk" "$architecture"
printf '%s\n' \
    'Sera usado um Linux dedicado: termux-ai (Debian + Node.js 24).' \
    'Os agentes exigem contas proprias e internet. PRoot nao e isolamento de seguranca.' \
    'Codex permanece experimental: o sandbox falhou no teste inicial em Android/PRoot.' \
    'Antigravity CLI permanece experimental: login e execucao ainda nao testados em Android/PRoot.'
if (( check_only )); then
    printf '%s\n' 'Pre-verificacao concluida. Nada foi instalado; a execucao real dos agentes ainda precisa ser testada.'
    exit 0
fi
if (( ! assume_yes )); then
    [[ -t 0 ]] || fail 'Sem entrada interativa. Revise o instalador e use --yes para confirmar.'
    read -r -p 'Instalar pacotes e configurar os atalhos? [s/N] ' answer
    case "$answer" in
        s|S|sim|SIM|y|Y|yes) ;;
        *) printf '%s\n' 'Instalacao cancelada.'; exit 0 ;;
    esac
fi

umask 077
mkdir -p "$state_dir/bin"
printf '%s\n' "$owner_id" > "$state_dir/owner"
mkdir "$state_dir/install.lock" 2>/dev/null || fail 'Outra instalacao esta em andamento, ou deixou install.lock apos uma interrupcao.'
trap 'rmdir -- "$state_dir/install.lock"' EXIT

"$PREFIX/bin/pkg" update
"$PREFIX/bin/pkg" install -y proot-distro
proot_version="$(dpkg-query -W -f='${Version}' proot-distro)"
dpkg --compare-versions "$proot_version" ge 5.3.0 || fail 'O repositorio do seu Termux precisa oferecer proot-distro 5.3.0 ou superior. Nao misture repositorios de variantes diferentes.'

if [[ ! -e "$container_dir" && ! -e "$legacy_dir" ]]; then
    proot-distro install node:24-bookworm-slim --name termux-ai
    printf '%s\n' "$owner_id" > "$state_dir/container.managed"
fi
proot-distro login termux-ai -- /bin/bash -se -- system < "$project_root/scripts/setup-linux.sh"
proot-distro login termux-ai --user node -- /bin/bash -se -- agents < "$project_root/scripts/setup-linux.sh"

{
    printf '#!%s/bin/bash\n' "$PREFIX"
    tail -n +2 "$project_root/bin/ia"
} > "$state_dir/bin/ia.next"
chmod 755 "$state_dir/bin/ia.next"
mv -- "$state_dir/bin/ia.next" "$state_dir/bin/ia"
for tool_name in ia codex copilot claude antigravity agy; do
    install -m 755 "$state_dir/bin/ia" "$PREFIX/bin/$tool_name"
done

if (( enable_menu )); then
    install -m 644 "$project_root/scripts/menu.bash" "$state_dir/menu.bash"
    menu_hook='if [ -f "$HOME/.local/share/termux-ai/menu.bash" ]; then . "$HOME/.local/share/termux-ai/menu.bash"; fi'
    if [[ ! -f "$HOME/.bashrc" ]] || ! grep -Fqx "$menu_hook" "$HOME/.bashrc"; then
        if [[ -f "$HOME/.bashrc" && ! -e "$state_dir/bashrc.before" ]]; then
            cp -p -- "$HOME/.bashrc" "$state_dir/bashrc.before"
        fi
        printf '\n%s\n' "$menu_hook" >> "$HOME/.bashrc"
    fi
else
    rm -f -- "$state_dir/menu.bash"
fi

printf '\n%s\n' \
    'Instalacao concluida; os comandos de versao dos quatro agentes passaram.' \
    'Abra uma nova sessao Bash ou execute ia. Use 0 no menu para chegar ao shell.' \
    'Faltam seus logins e os testes com modelos. Nenhuma credencial foi solicitada.' \
    'O sandbox do Codex nao foi desativado. Nenhuma conexao SSH/ADB foi criada.'