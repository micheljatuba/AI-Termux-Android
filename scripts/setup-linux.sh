#!/usr/bin/env bash
set -euo pipefail

# Versoes minimas validadas no Android. O instalador nunca rebaixa versoes mais novas.
codex_version=0.159.3
copilot_version=1.0.90
claude_version=2.1.286
opencode_version=1.18.34
agent_tools=(copilot claude codex agy opencode)
version_pattern='([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
antigravity_manifest_base='https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests'

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

display_name() {
    case "$1" in
        copilot) printf '%s\n' 'GitHub Copilot' ;;
        claude) printf '%s\n' 'Claude Code' ;;
        codex) printf '%s\n' 'Codex' ;;
        agy) printf '%s\n' 'Antigravity CLI' ;;
        opencode) printf '%s\n' 'OpenCode' ;;
    esac
}

package_name() {
    case "$1" in
        copilot) printf '%s\n' '@github/copilot' ;;
        claude) printf '%s\n' '@anthropic-ai/claude-code' ;;
        codex) printf '%s\n' '@openai/codex' ;;
        opencode) printf '%s\n' 'opencode-ai' ;;
        *) return 1 ;;
    esac
}

pinned_version() {
    case "$1" in
        copilot) printf '%s\n' "$copilot_version" ;;
        claude) printf '%s\n' "$claude_version" ;;
        codex) printf '%s\n' "$codex_version" ;;
        opencode) printf '%s\n' "$opencode_version" ;;
        *) printf '\n' ;;
    esac
}

# Remove do PATH as pastas do Android, onde ficam os atalhos do Termux.
use_linux_path() {
    local entry linux_path="$HOME/.local/bin"
    local -a entries
    IFS=: read -r -a entries <<< "$PATH"
    for entry in "${entries[@]}"; do
        case "$entry" in
            ''|/data/*|/system/*|/apex/*|/vendor/*|/product/*|/odm/*) ;;
            *) [[ ":$linux_path:" == *":$entry:"* ]] || linux_path+=":$entry" ;;
        esac
    done
    PATH="$linux_path"
    export PATH
}

extract_version() {
    [[ $1 =~ $version_pattern ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
}

version_at_least() {
    local pattern="^${version_pattern}\$" index
    local -a left right
    [[ $1 =~ $pattern ]] || return 1
    left=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]#-}")
    [[ $2 =~ $pattern ]] || return 1
    right=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]#-}")
    for index in 0 1 2; do
        if (( 10#${left[index]} > 10#${right[index]} )); then
            return 0
        fi
        if (( 10#${left[index]} < 10#${right[index]} )); then
            return 1
        fi
    done
    [[ -n ${left[3]} ]] || return 0
    [[ -n ${right[3]} ]] || return 1
    [[ "$(printf '%s\n' "${left[3]}" "${right[3]}" | sort -V | tail -n 1)" == "${left[3]}" ]]
}

installed_version() {
    local tool_path output
    tool_path="$(command -v "$1" 2> /dev/null)" || return 1
    [[ $tool_path == /* ]] || return 1
    output="$(timeout 60s "$tool_path" --version < /dev/null 2> "$work_dir/version.err")" || return 1
    extract_version "$output" || extract_version "$(< "$work_dir/version.err")"
}

# Reaproveita o prefixo npm em que o agente ja esta instalado.
npm_prefix_for() {
    local package tool_path real_path prefix
    package="$(package_name "$1")" || return 1
    tool_path="$(command -v "$1" 2> /dev/null)" || return 1
    [[ $tool_path == /* ]] || return 1
    real_path="$(readlink -f -- "$tool_path")" || return 1
    case "$real_path" in
        */lib/node_modules/"$package"/*) prefix="${real_path%%/lib/node_modules/*}" ;;
        *) prefix="$(dirname -- "$(dirname -- "$tool_path")")" ;;
    esac
    [[ -n $prefix && -d "$prefix/lib/node_modules/$package" ]] || return 1
    printf '%s\n' "$prefix"
}

check_node() {
    node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' \
        || fail 'O Linux precisa de Node.js 22 ou superior.'
}

install_npm_agent() {
    local package prefix
    package="$(package_name "$1")"
    prefix="$(npm_prefix_for "$1")" || prefix="$HOME/.local"
    printf 'Instalando %s %s em %s.\n' "$(display_name "$1")" "$2" "$prefix"
    npm install -g --prefix "$prefix" "$package@$2" < /dev/null
}

install_opencode() {
    local prefix
    check_node
    prefix="$(npm_prefix_for opencode)" || prefix="$HOME/.local"
    printf 'Instalando OpenCode %s em %s.\n' "$1" "$prefix"
    npm install -g --prefix "$prefix" --ignore-scripts "opencode-ai@$1" < /dev/null
    node "$prefix/lib/node_modules/opencode-ai/postinstall.mjs" < /dev/null
    timeout 60s "$prefix/bin/opencode" --version < /dev/null
}

install_claude() {
    local prefix
    if prefix="$(npm_prefix_for claude)"; then
        printf 'Instalando Claude Code %s em %s.\n' "$1" "$prefix"
        npm install -g --prefix "$prefix" "@anthropic-ai/claude-code@$1" < /dev/null
        return 0
    fi
    printf 'Instalando Claude Code %s pelo instalador oficial.\n' "$1"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --output "$work_dir/claude-install.sh" https://claude.ai/install.sh
    bash "$work_dir/claude-install.sh" "$1" < /dev/null
}

# Imprime URL, SHA-512, versao e plataforma de um manifesto oficial validado.
antigravity_release() {
    local platform
    case "$(uname -m)" in
        aarch64|arm64) platform=linux_arm64 ;;
        x86_64|amd64) platform=linux_amd64 ;;
        *) printf '%s\n' 'Arquitetura nao suportada pelo Antigravity CLI.' >&2; return 1 ;;
    esac
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$1/antigravity.json" "$antigravity_manifest_base/$platform.json" || return 1
    node - "$1/antigravity.json" <<'NODE' || return 1
const { readFileSync } = require('node:fs');
const manifest = JSON.parse(readFileSync(process.argv[2], 'utf8'));
if (typeof manifest.url !== 'string' || /\s/.test(manifest.url)
    || typeof manifest.sha512 !== 'string' || !/^[a-f0-9]{128}$/i.test(manifest.sha512)
    || typeof manifest.version !== 'string' || !/^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/.test(manifest.version)) {
    throw new Error('Manifesto Antigravity invalido: URL, versao ou SHA-512 ausente/incorreto.');
}
const releaseUrl = new URL(manifest.url);
if (releaseUrl.protocol !== 'https:' || releaseUrl.hostname !== 'storage.googleapis.com'
    || !releaseUrl.pathname.startsWith('/antigravity-public/antigravity-cli/')
    || releaseUrl.username || releaseUrl.password || releaseUrl.port || releaseUrl.search || releaseUrl.hash) {
    throw new Error('O manifesto nao aponta para um pacote oficial do Antigravity.');
}
console.log(releaseUrl.href);
console.log(manifest.sha512.toLowerCase());
console.log(manifest.version);
NODE
    printf '%s\n' "$platform"
}

install_antigravity() {
    local release_dir="$work_dir/antigravity" release_text
    local -a release
    rm -rf -- "$release_dir"
    mkdir -p "$release_dir"
    release_text="$(antigravity_release "$release_dir")"
    mapfile -t release <<< "$release_text"
    if [[ -n ${1:-} && ${release[2]} != "$1" ]]; then
        fail "O manifesto do Antigravity agora indica ${release[2]}. Consulte as versoes novamente."
    fi
    printf 'Instalando Antigravity CLI %s (%s).\n' "${release[2]}" "${release[3]}"
    curl --fail --progress-bar --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$release_dir/antigravity-package" "${release[0]}"
    if ! printf '%s  %s\n' "${release[1]}" "$release_dir/antigravity-package" | sha512sum --check --status; then
        fail 'SHA-512 do Antigravity nao confere; instalacao interrompida.'
    fi
    case "${release[0]}" in
        *.tar.gz)
            tar --extract --gzip --file "$release_dir/antigravity-package" \
                --directory "$release_dir" --no-same-owner --no-same-permissions antigravity
            ;;
        *) cp -- "$release_dir/antigravity-package" "$release_dir/antigravity" ;;
    esac
    [[ -f "$release_dir/antigravity" && ! -L "$release_dir/antigravity" ]] \
        || fail 'O pacote Antigravity nao contem um executavel regular.'
    chmod 755 "$release_dir/antigravity"
    timeout 60s "$release_dir/antigravity" --version < /dev/null
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$release_dir/antigravity" "$HOME/.local/bin/agy"
}

install_agent() {
    case "$1" in
        codex|copilot) install_npm_agent "$1" "$2" ;;
        claude) install_claude "$2" ;;
        opencode) install_opencode "$2" ;;
        agy) install_antigravity "$2" ;;
    esac
}

# Instala somente agentes ausentes ou abaixo da versao validada.
ensure_agent() {
    local current minimum
    minimum="$(pinned_version "$1")"
    if current="$(installed_version "$1")"; then
        if [[ -z $minimum ]] || version_at_least "$current" "$minimum"; then
            printf '%s %s ja instalado; mantido.\n' "$(display_name "$1")" "$current"
            return 0
        fi
        printf '%s %s esta abaixo da versao validada %s.\n' "$(display_name "$1")" "$current" "$minimum"
    fi
    install_agent "$1" "$minimum"
}

update_profile_path() {
    # shellcheck disable=SC2016
    local profile_entry='export PATH="$HOME/.local/bin:$PATH"'
    if [[ ! -f "$HOME/.profile" ]] || ! grep -Fqx "$profile_entry" "$HOME/.profile"; then
        if [[ -f "$HOME/.profile" && ! -e "$HOME/.profile.termux-ai.before" ]]; then
            cp -p -- "$HOME/.profile" "$HOME/.profile.termux-ai.before"
        fi
        printf '\n%s\n' "$profile_entry" >> "$HOME/.profile"
    fi
}

verify_agents() {
    local tool version
    for tool in "${agent_tools[@]}"; do
        version="$(installed_version "$tool")" || fail "$(display_name "$tool") nao respondeu ao teste de versao."
        printf 'Verificado: %s %s\n' "$(display_name "$tool")" "$version"
    done
}

# Saida para o Termux: @version, agente, instalada, disponivel e situacao.
print_versions() {
    local tool package installed latest status
    for tool in codex copilot claude opencode; do
        package="$(package_name "$tool")"
        (
            latest="$(timeout 30s npm view "$package" version < /dev/null 2> /dev/null)" \
                && extract_version "$latest" > "$work_dir/$tool.latest"
        ) &
    done
    (
        mkdir -p "$work_dir/agy-manifest"
        latest="$(antigravity_release "$work_dir/agy-manifest" 2> /dev/null)" \
            && sed -n '3p' <<< "$latest" > "$work_dir/agy.latest"
    ) &
    for tool in "${agent_tools[@]}"; do
        installed_version "$tool" > "$work_dir/$tool.installed" 2> /dev/null || true
    done
    wait
    for tool in "${agent_tools[@]}"; do
        installed=''
        latest=''
        [[ ! -s "$work_dir/$tool.installed" ]] || installed="$(< "$work_dir/$tool.installed")"
        [[ ! -s "$work_dir/$tool.latest" ]] || latest="$(< "$work_dir/$tool.latest")"
        if [[ -z $installed ]]; then
            status=missing
        elif [[ -z $latest ]]; then
            status=unknown
        elif version_at_least "$installed" "$latest"; then
            status=current
        else
            status=outdated
        fi
        printf '@version\t%s\t%s\t%s\t%s\n' "$tool" "${installed:--}" "${latest:--}" "$status"
    done
}

stage="${1:-}"
case "$stage" in
    system)
        [[ $(id -u) == 0 ]] || fail 'Esta etapa exige o root simulado do PRoot.'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl git gh ripgrep nano
        exit 0
        ;;
    agents|opencode|versions|update) ;;
    *) printf '%s\n' 'Etapa interna desconhecida. Use install.sh no Termux.' >&2; exit 2 ;;
esac

if [[ $(id -u) == 0 ]]; then
    umask 022
else
    umask 077
fi
use_linux_path
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

case "$stage" in
    agents)
        if [[ $(id -u) == 0 && ${2:-} != --root ]]; then
            fail 'Esta etapa deve rodar como o usuario comum do Linux dedicado.'
        fi
        check_node
        mkdir -p "$HOME/.local/bin"
        for tool_name in codex copilot opencode claude agy; do
            ensure_agent "$tool_name"
        done
        update_profile_path
        verify_agents
        ;;
    opencode)
        mkdir -p "$HOME/.local/bin"
        ensure_agent opencode
        ;;
    versions)
        print_versions
        ;;
    update)
        [[ $# -eq 3 ]] || fail 'Uso interno: update <agente> <versao>.'
        tool_name="$2"
        target_version="$3"
        case "$tool_name" in
            copilot|claude|codex|agy|opencode) ;;
            *) fail "Agente desconhecido: $tool_name" ;;
        esac
        [[ $target_version =~ ^${version_pattern}$ ]] || fail "Versao invalida: $target_version"
        check_node
        install_agent "$tool_name" "$target_version"
        actual_version="$(installed_version "$tool_name")" \
            || fail "$(display_name "$tool_name") nao respondeu ao teste de versao apos a atualizacao."
        [[ $actual_version == "$target_version" ]] \
            || fail "$(display_name "$tool_name") informou $actual_version; esperado $target_version."
        printf 'Atualizado: %s %s\n' "$(display_name "$tool_name")" "$actual_version"
        ;;
esac