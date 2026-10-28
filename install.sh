#!/usr/bin/env bash
set -euo pipefail

show_help() {
    printf '%s\n' \
        'Uso: bash install.sh [--check] [--yes] [--no-menu] [--adopt-ubuntu]' \
        '  --check         Verifica o aparelho sem instalar nem alterar arquivos.' \
        '  --yes           Confirma a instalacao sem uma pergunta interativa.' \
        '  --no-menu       Nao abre o menu automaticamente nas sessoes Bash.' \
        '  --adopt-ubuntu  Integra o Ubuntu e o menu ia manuais, preservando contas e projetos.'
}

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

# Remove somente o bloco exato que abria o menu ia manual.
strip_manual_menu() {
    awk '
        function trim(text) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            return text
        }
        BEGIN {
            block[1] = "if [[ $- == *i* && -z ${SSH_CONNECTION:-} && -t 0 && -t 1 ]]; then"
            block[2] = "if command -v ia >/dev/null 2>&1; then"
            block[3] = "ia"
            block[4] = "fi"
            block[5] = "fi"
        }
        { lines[NR] = $0 }
        END {
            found = 0
            for (line = 1; line <= NR; line++) {
                matched = line + 4 <= NR
                for (offset = 0; matched && offset < 5; offset++) {
                    if (trim(lines[line + offset]) != block[offset + 1]) {
                        matched = 0
                    }
                }
                if (matched) {
                    found++
                    line += 4
                    continue
                }
                print lines[line]
            }
            exit (found == 1 ? 0 : 1)
        }
    ' "$1"
}

check_only=0
assume_yes=0
enable_menu=1
adopt_ubuntu=0
for argument in "$@"; do
    case "$argument" in
        --check) check_only=1 ;;
        --yes) assume_yes=1 ;;
        --no-menu) enable_menu=0 ;;
        --adopt-ubuntu) adopt_ubuntu=1 ;;
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
distro_dir="${TERMUX__PREFIX:-$PREFIX}/var/lib/proot-distro"
container_dir="$distro_dir/containers/termux-ai"
legacy_dir="$distro_dir/installed-rootfs/termux-ai"
owner_id='termux-ai-installer-v1'
tool_names=(ia codex copilot claude antigravity agy opencode embeddinggemma embedding)
hub_files=(util.mjs agents.mjs jev.mjs models.mjs orchestrator.mjs sessions.mjs server.mjs cli.mjs index.html attach.sh tmux.conf)
linux_name=termux-ai
linux_user=node
if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ ! -L "$state_dir" && -f "$state_dir/owner" ]] || fail "A pasta $state_dir ja existe e nao pertence a este instalador."
    [[ $(< "$state_dir/owner") == "$owner_id" ]] || fail 'Identificador de instalacao desconhecido; nada sera sobrescrito.'
    if [[ -f "$state_dir/linux.conf" ]]; then
        while IFS='=' read -r config_key config_value || [[ -n $config_key ]]; do
            case "$config_key" in
                name) linux_name="$config_value" ;;
                user) linux_user="$config_value" ;;
            esac
        done < "$state_dir/linux.conf"
    fi
fi
if (( adopt_ubuntu )); then
    [[ ! -f "$state_dir/owner" || $linux_name == ubuntu ]] \
        || fail 'Esta instalacao gerenciada usa o Linux termux-ai; a adocao do Ubuntu nao sera aplicada.'
    linux_name=ubuntu
    linux_user=root
fi
case "$linux_name:$linux_user" in
    termux-ai:node) adopted=0 ;;
    ubuntu:root) adopted=1 ;;
    *) fail "Configuracao desconhecida em $state_dir/linux.conf; nada sera alterado." ;;
esac

if (( adopted )); then
    [[ -d "$distro_dir/containers/ubuntu" || -d "$distro_dir/installed-rootfs/ubuntu" ]] \
        || fail 'Nenhum Ubuntu do PRoot-Distro foi encontrado para integrar.'
elif [[ -e "$container_dir" || -L "$container_dir" || -e "$legacy_dir" || -L "$legacy_dir" ]]; then
    [[ -f "$state_dir/container.managed" ]] || fail 'Ja existe um Linux chamado termux-ai que nao foi concluido por este instalador. Preserve seus dados antes de resolver o conflito.'
fi

# Na adocao, aceita o menu manual, links para ele e copias identicas.
manual_launcher=''
if (( adopted )); then
    if [[ -f "$PREFIX/bin/ia" && ! -L "$PREFIX/bin/ia" ]] \
        && grep -Fq 'exec proot-distro login ubuntu --work-dir "$PWD" -- /bin/bash -lc ' "$PREFIX/bin/ia"; then
        bash -n "$PREFIX/bin/ia" || fail 'O menu ia manual tem erro de sintaxe; nada sera alterado.'
        manual_launcher="$PREFIX/bin/ia"
    elif [[ -f "$state_dir/adopted/bin/ia" && ! -L "$state_dir/adopted/bin/ia" ]]; then
        manual_launcher="$state_dir/adopted/bin/ia"
    fi
fi
for tool_name in "${tool_names[@]}"; do
    target="$PREFIX/bin/$tool_name"
    [[ -e "$target" || -L "$target" ]] || continue
    if [[ ! -L "$target" && -f "$state_dir/bin/ia" ]] && cmp -s "$target" "$state_dir/bin/ia"; then
        continue
    fi
    if [[ -n $manual_launcher ]]; then
        if [[ -L "$target" ]]; then
            link_target="$(readlink -- "$target")"
            if [[ $tool_name != ia && ( $link_target == ia || $link_target == "$PREFIX/bin/ia" ) ]]; then
                continue
            fi
        elif cmp -s "$target" "$manual_launcher"; then
            continue
        fi
    fi
    fail "O comando $tool_name ja existe ou foi personalizado. Nao sera substituido."
done

# O Hermes Agent e opcional: um comando hermes que nao e deste instalador e mantido, sem interromper a instalacao.
hermes_shortcut=1
hermes_target="$PREFIX/bin/hermes"
if [[ -e "$hermes_target" || -L "$hermes_target" ]]; then
    if [[ -L "$hermes_target" || ! -f "$state_dir/bin/ia" ]] || ! cmp -s "$hermes_target" "$state_dir/bin/ia"; then
        hermes_shortcut=0
    fi
fi

manual_menu_block=0
if (( adopted )) && [[ -f "$HOME/.bashrc" && ! -L "$HOME/.bashrc" ]] && strip_manual_menu "$HOME/.bashrc" > /dev/null; then
    manual_menu_block=1
fi
if (( enable_menu )) && [[ -e "$HOME/.bashrc" || -L "$HOME/.bashrc" ]]; then
    [[ -f "$HOME/.bashrc" && ! -L "$HOME/.bashrc" ]] || fail 'A configuracao Bash nao e um arquivo comum; use --no-menu.'
    bash -n "$HOME/.bashrc" || fail 'Corrija a sintaxe da configuracao Bash ou use --no-menu.'
    if (( adopted && ! manual_menu_block )) && grep -Eq '^[[:space:]]*ia[[:space:]]*$' "$HOME/.bashrc"; then
        fail 'A configuracao Bash ja abre o menu ia; remova essa chamada ou use --no-menu.'
    fi
fi
required_files=(bin/ia scripts/setup-linux.sh scripts/menu.bash scripts/webui.sh scripts/web-menu.sh scripts/embeddinggemma_web.py scripts/embeddinggemma_cli.py scripts/embeddinggemma_auth.py scripts/embeddinggemma-launcher.sh scripts/handoff.sh)
for hub_file in "${hub_files[@]}"; do
    required_files+=("scripts/hub/$hub_file")
done
for relative_path in "${required_files[@]}"; do
    [[ -f "$project_root/$relative_path" ]] || fail 'Baixe o repositorio completo antes de executar install.sh.'
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        fail "O arquivo $relative_path precisa de finais de linha LF."
    fi
done

printf 'Android API %s; arquitetura %s; espaco livre suficiente.\n' "$android_sdk" "$architecture"
if (( adopted )); then
    printf '%s\n' \
        'Sera usado o Ubuntu existente do PRoot-Distro, com o usuario root ja configurado.' \
        'Contas, projetos e agentes atualizados serao mantidos; agentes abaixo da versao validada serao atualizados.' \
        'Os comandos ia e dos agentes passam ao menu gerenciado; os anteriores ficam em copia de seguranca.'
else
    printf '%s\n' 'Sera usado um Linux dedicado: termux-ai (Debian + Node.js 24).'
fi
printf '%s\n' \
    'Os agentes exigem contas proprias e internet. PRoot nao e isolamento de seguranca.' \
    'Codex permanece experimental: o sandbox falhou no teste inicial em Android/PRoot.' \
    'Antigravity CLI: uso confirmado pelo usuario no Android; outras configuracoes precisam de validacao.' \
    'OpenCode permanece experimental: login e execucao ainda nao testados em Android/PRoot.' \
    'Hermes Agent e opcional e fica fora desta instalacao (cerca de 2 GB): use depois ia atualizar hermes.'
if (( ! hermes_shortcut )); then
    printf '%s\n' 'Ja existe um comando hermes que nao pertence a este instalador; ele foi mantido. Use ia hermes para abrir o Hermes Agent do Linux.'
fi
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
printf 'name=%s\nuser=%s\n' "$linux_name" "$linux_user" > "$state_dir/linux.conf"

"$PREFIX/bin/pkg" update
"$PREFIX/bin/pkg" install -y proot-distro
proot_version="$(dpkg-query -W -f='${Version}' proot-distro)"
dpkg --compare-versions "$proot_version" ge 5.3.0 || fail 'O repositorio do seu Termux precisa oferecer proot-distro 5.3.0 ou superior. Nao misture repositorios de variantes diferentes.'

if (( adopted )); then
    agent_login=(login ubuntu)
    agent_stage=(agents --root)
else
    if [[ ! -e "$container_dir" && ! -e "$legacy_dir" ]]; then
        proot-distro install node:24-bookworm-slim --name termux-ai
        printf '%s\n' "$owner_id" > "$state_dir/container.managed"
    fi
    agent_login=(login termux-ai --user node)
    agent_stage=(agents)
fi
proot-distro login "$linux_name" -- /bin/bash -se -- system < "$project_root/scripts/setup-linux.sh"
proot-distro "${agent_login[@]}" -- /bin/bash -se -- "${agent_stage[@]}" < "$project_root/scripts/setup-linux.sh"
proot-distro "${agent_login[@]}" -- /bin/bash -se -- install-assets "$project_root" < "$project_root/scripts/setup-linux.sh"

mkdir -p "$state_dir/tools" "$state_dir/web"
install -m 644 "$project_root/scripts/embeddinggemma_cli.py" "$state_dir/tools/embeddinggemma_cli.py"
install -m 644 "$project_root/scripts/embeddinggemma_auth.py" "$state_dir/tools/embeddinggemma_auth.py"
install -m 644 "$project_root/scripts/embeddinggemma_web.py" "$state_dir/tools/embeddinggemma_web.py"
install -m 644 "$project_root/scripts/webui.sh" "$state_dir/webui.sh"
install -m 644 "$project_root/scripts/web-menu.sh" "$state_dir/web/menu.sh"

if (( adopted )); then
    mkdir -p "$state_dir/adopted/bin"
    for tool_name in "${tool_names[@]}"; do
        target="$PREFIX/bin/$tool_name"
        backup="$state_dir/adopted/bin/$tool_name"
        [[ -e "$target" || -L "$target" ]] || continue
        [[ ! -e "$backup" && ! -L "$backup" ]] || continue
        if [[ ! -L "$target" && -f "$state_dir/bin/ia" ]] && cmp -s "$target" "$state_dir/bin/ia"; then
            continue
        fi
        cp -P -p -- "$target" "$backup"
    done
fi

install -m 644 "$project_root/scripts/setup-linux.sh" "$state_dir/setup-linux.sh"
{
    printf '#!%s/bin/bash\n' "$PREFIX"
    tail -n +2 "$project_root/bin/ia"
} > "$state_dir/bin/ia.next"
chmod 755 "$state_dir/bin/ia.next"
mv -- "$state_dir/bin/ia.next" "$state_dir/bin/ia"
installed_tools=("${tool_names[@]}")
if (( hermes_shortcut )); then
    installed_tools+=(hermes)
fi
for tool_name in "${installed_tools[@]}"; do
    install -m 755 "$state_dir/bin/ia" "$state_dir/bin/$tool_name.next"
    mv -f -- "$state_dir/bin/$tool_name.next" "$PREFIX/bin/$tool_name"
done

if (( manual_menu_block )); then
    strip_manual_menu "$HOME/.bashrc" > "$state_dir/bashrc.next" \
        || fail 'A configuracao Bash mudou durante a instalacao. Revise ~/.bashrc e execute novamente.'
    if [[ ! -e "$state_dir/bashrc.before" ]]; then
        cp -p -- "$HOME/.bashrc" "$state_dir/bashrc.before"
    fi
    # Reescreve no mesmo arquivo para manter permissoes e links fisicos.
    cat -- "$state_dir/bashrc.next" > "$HOME/.bashrc"
    rm -f -- "$state_dir/bashrc.next"
fi
if (( enable_menu )); then
    install -m 644 "$project_root/scripts/menu.bash" "$state_dir/menu.bash"
    # shellcheck disable=SC2016
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

if (( adopted )); then
    printf '\n%s\n' \
        'Ubuntu existente integrado; os comandos de versao dos cinco agentes passaram.' \
        'Contas e projetos foram mantidos. Comandos anteriores: ~/.local/share/termux-ai/adopted/bin' \
        'Abra uma nova sessao Bash ou execute ia. Use ia versoes para consultar atualizacoes.'
else
    printf '\n%s\n' \
        'Instalacao concluida; os comandos de versao dos cinco agentes passaram.' \
        'Abra uma nova sessao Bash ou execute ia. Use 0 no menu para chegar ao shell.' \
        'Faltam seus logins e os testes com modelos. Nenhuma credencial foi solicitada.'
fi
printf '%s\n' \
    'Codex sem sandbox no Android: ia codex abre no modo Pedir aprovacao.' \
    'Use ia diagnostico para conferir logins e protecoes. Nenhuma conexao SSH/ADB foi criada.' \
    'Painel web com varios agentes e orquestracao: ia web (acesso somente neste aparelho). No terminal: ia orquestrar.' \
    'Hermes Agent e opcional (cerca de 2 GB e varios minutos): ia atualizar hermes.'