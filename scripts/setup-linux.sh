#!/usr/bin/env bash
set -euo pipefail

# Versoes minimas validadas no Android. O instalador nunca rebaixa versoes mais novas.
codex_version=0.159.3
copilot_version=1.0.90
claude_version=2.1.286
opencode_version=1.18.34
hermes_version=0.22.1
agent_tools=(copilot claude codex agy opencode)
# O Hermes Agent e opcional: so e instalado quando pedido (ia atualizar hermes).
optional_tools=(hermes)
version_pattern='([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
antigravity_manifest_base='https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests'
hermes_installer_url='https://hermes-agent.nousresearch.com/install.sh'
hermes_release_url='https://api.github.com/repos/NousResearch/hermes-agent/releases/latest'

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
        hermes) printf '%s\n' 'Hermes Agent' ;;
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
        hermes) printf '%s\n' "$hermes_version" ;;
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
    output="$(timeout 60s "$tool_path" --version < /dev/null 2> "$work_dir/$1.version.err")" || return 1
    extract_version "$output" || extract_version "$(< "$work_dir/$1.version.err")"
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
        --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 600 \
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
        --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 600 \
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
        --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 600 \
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

# Imprime a versao da ultima release estavel do Hermes (so o esquema 0.x.y; calendario e prerelease sao ignorados).
hermes_latest() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 30 --header 'Accept: application/vnd.github+json' \
        --output "$work_dir/hermes-release.json" "$hermes_release_url" || return 1
    node - "$work_dir/hermes-release.json" <<'NODE' || return 1
const { readFileSync } = require('node:fs');
const release = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const match = /^v?([0-9]+\.[0-9]+\.[0-9]+)$/.exec(String(release.tag_name ?? ''));
if (!match || release.draft || release.prerelease || Number(match[1].split('.')[0]) >= 1000) process.exit(1);
console.log(match[1]);
NODE
}

# O instalador oficial recusa o ambiente do Termux; o Linux convidado e um Linux comum.
# Um Hermes que nao responde a --version e tratado como ausente: o instalador oficial o refaz.
install_hermes() {
    local tool_path installer="$work_dir/hermes-install.sh"
    if installed_version hermes > /dev/null 2>&1 && tool_path="$(command -v hermes)"; then
        printf 'Atualizando o Hermes Agent pelo proprio comando de atualizacao.\n'
        timeout 1500s "$tool_path" update --yes --no-gateway-restart < /dev/null
        return
    fi
    printf 'Instalando o Hermes Agent pelo instalador oficial (cerca de 2 GB; pode levar varios minutos).\n'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 600 \
        --output "$installer" "$hermes_installer_url"
    [[ -s $installer ]] || fail 'O instalador do Hermes veio vazio; nada foi instalado.'
    timeout 1800s env -u TERMUX_VERSION -u PREFIX \
        bash "$installer" --non-interactive --skip-browser --skip-computer-use < /dev/null
}

install_agent() {
    case "$1" in
        codex|copilot) install_npm_agent "$1" "$2" ;;
        claude) install_claude "$2" ;;
        opencode) install_opencode "$2" ;;
        agy) install_antigravity "$2" ;;
        hermes) install_hermes ;;
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
    (
        latest="$(hermes_latest 2> /dev/null)" && printf '%s\n' "$latest" > "$work_dir/hermes.latest"
    ) &
    (
        installed_version hermes > "$work_dir/hermes.installed" 2> /dev/null || true
    ) &
    for tool in "${agent_tools[@]}"; do
        installed_version "$tool" > "$work_dir/$tool.installed" 2> /dev/null || true
    done
    wait
    for tool in "${agent_tools[@]}" "${optional_tools[@]}"; do
        installed=''
        latest=''
        [[ ! -s "$work_dir/$tool.installed" ]] || installed="$(< "$work_dir/$tool.installed")"
        [[ ! -s "$work_dir/$tool.latest" ]] || latest="$(< "$work_dir/$tool.latest")"
        # Sem consulta, a versao validada serve de alvo para instalar o Hermes ausente.
        if [[ -z $installed && -z $latest && $tool == hermes ]]; then
            latest="$hermes_version"
        fi
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

# Roda como nas sessoes dos agentes: shell de login, PATH local primeiro e sem entrada.
in_agent_env() {
    # shellcheck disable=SC2016
    timeout 30s bash -lc 'export TERMUX_AI_GUEST=1; export PATH="$HOME/.local/bin:$PATH"; exec "$@"' termux-ai "$@" < /dev/null
}

codex_login() {
    local output
    if output="$(in_agent_env "$1" login status 2>&1)"; then
        printf 'yes'
    elif [[ $output == *'Not logged in'* ]]; then
        printf 'no'
    else
        printf 'unknown'
    fi
}

# Le somente o campo loggedIn; email e organizacao nunca sao exibidos.
claude_login() {
    local output pattern='"loggedIn"[[:space:]]*:[[:space:]]*(true|false)'
    output="$(in_agent_env "$1" auth status 2> /dev/null)" || true
    if [[ ! $output =~ $pattern ]]; then
        printf 'unknown'
    elif [[ ${BASH_REMATCH[1]} == true ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# O ambiente de login informa so se ha token e onde fica a configuracao, nunca valores.
copilot_login() {
    local report config content pattern='"loggedInUsers"[[:space:]]*:[[:space:]]*\[[[:space:]]*[^][:space:]]'
    # shellcheck disable=SC2016
    report="$(in_agent_env /bin/bash -c '
        for name in COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN COPILOT_PROVIDER_BASE_URL; do
            if [[ -n ${!name:-} ]]; then
                printf "\n%s\n" @token
                exit 0
            fi
        done
        printf "\n%s\n" "${COPILOT_HOME:-$HOME/.copilot}/config.json"
    ' 2> /dev/null)" || {
        printf 'unknown'
        return 0
    }
    config="${report##*$'\n'}"
    if [[ $config == @token ]]; then
        printf 'yes'
    elif [[ $config != /* || ! -e $config ]]; then
        printf 'no'
    elif ! content="$(< "$config")"; then
        printf 'unknown'
    elif [[ $content =~ $pattern ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

opencode_login() {
    local output credentials='' variables=0 pattern
    output="$(in_agent_env "$1" auth list 2>&1 | sed 's/\x1b\[[0-9;]*m//g')" || {
        printf 'unknown'
        return 0
    }
    pattern='([0-9]+) credentials?'
    if [[ $output =~ $pattern ]]; then
        credentials="${BASH_REMATCH[1]}"
    fi
    pattern='([0-9]+) environment variables?'
    if [[ $output =~ $pattern ]]; then
        variables="${BASH_REMATCH[1]}"
    fi
    if [[ -z $credentials ]]; then
        printf 'unknown'
    elif (( 10#$credentials > 0 || 10#$variables > 0 )); then
        printf 'yes'
    else
        printf 'no'
    fi
}

agy_login() {
    if [[ -s "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# Chaves em ~/.hermes/.env ou credenciais listadas por "hermes auth list"; so a presenca e lida, nunca os valores.
hermes_login() {
    local output env_file="${HERMES_HOME:-$HOME/.hermes}/.env"
    local pattern="^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*(_KEY|_TOKEN)[[:space:]]*=[[:space:]]*(\"[^\"]+\"|'[^']+'|[^[:space:]#\"'])"
    if [[ -f $env_file ]] && grep -Eq -- "$pattern" "$env_file" 2> /dev/null; then
        printf 'yes'
    elif ! output="$(in_agent_env "$1" auth list 2> /dev/null)"; then
        printf 'unknown'
    elif [[ -n ${output//[[:space:]]/} ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

diagnose_agent() {
    local tool_path version state
    if ! tool_path="$(command -v "$1" 2> /dev/null)" || [[ $tool_path != /* ]]; then
        printf '@diag\tagent\t%s\tmissing\t-\n' "$1"
        return 0
    fi
    if ! version="$(installed_version "$1")"; then
        printf '@diag\tagent\t%s\tbroken\t-\n' "$1"
        return 0
    fi
    case "$1" in
        codex) state="$(codex_login "$tool_path")" ;;
        claude) state="$(claude_login "$tool_path")" ;;
        copilot) state="$(copilot_login)" ;;
        opencode) state="$(opencode_login "$tool_path")" ;;
        agy) state="$(agy_login)" ;;
        hermes) state="$(hermes_login "$tool_path")" ;;
    esac
    printf '@diag\tagent\t%s\t%s\t%s\n' "$1" "$state" "$version"
}

# So conta como protecao se o sandbox iniciar e bloquear uma gravacao fora da pasta de trabalho.
codex_isolation() {
    local codex_path probe="$HOME/.termux-ai-sandbox-probe"
    if ! codex_path="$(command -v codex 2> /dev/null)" || [[ $codex_path != /* ]]; then
        printf 'missing'
        return 0
    fi
    if ! (cd "$work_dir" && in_agent_env "$codex_path" sandbox -c 'sandbox_mode="read-only"' -- /bin/true) > /dev/null 2>&1; then
        printf 'unavailable'
        return 0
    fi
    rm -f -- "$probe"
    # shellcheck disable=SC2016
    (cd "$work_dir" && in_agent_env "$codex_path" sandbox -c 'sandbox_mode="read-only"' -- /bin/sh -c ': > "$1"' sh "$probe") \
        > /dev/null 2>&1 || true
    if [[ -e $probe ]]; then
        rm -f -- "$probe"
        printf 'ineffective'
    else
        printf 'active'
    fi
}

diagnose_system() {
    local line pretty='' version probe
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line == PRETTY_NAME=* ]]; then
                pretty="$(printf '%s' "${line#PRETTY_NAME=}" | tr -cd 'A-Za-z0-9 ._()/+:-')"
                break
            fi
        done < /etc/os-release
    fi
    pretty="${pretty:0:60}"
    printf '@diag\tcheck\tdistro\tok\t%s\n' "${pretty:--}"
    if version="$(timeout 30s node --version < /dev/null 2> /dev/null)" && version="$(extract_version "$version")"; then
        if version_at_least "$version" 22.0.0; then
            printf '@diag\tcheck\tnode\tok\t%s\n' "$version"
        else
            printf '@diag\tcheck\tnode\told\t%s\n' "$version"
        fi
    else
        printf '@diag\tcheck\tnode\tmissing\t-\n'
    fi
    if version="$(timeout 30s git --version < /dev/null 2> /dev/null)" && version="$(extract_version "$version")"; then
        printf '@diag\tcheck\tgit\tok\t%s\n' "$version"
    else
        printf '@diag\tcheck\tgit\tmissing\t-\n'
    fi
    # A pasta aberta pelo ia precisa aceitar gravacao dentro do Linux.
    if [[ $1 != /* ]]; then
        printf '@diag\tcheck\tworkdir\tskip\t-\n'
    elif probe="$(mktemp "$1/.termux-ai-diag.XXXXXX" 2> /dev/null)"; then
        rm -f -- "$probe"
        printf '@diag\tcheck\tworkdir\tok\t-\n'
    else
        printf '@diag\tcheck\tworkdir\tfail\t-\n'
    fi
}

diagnose_network() {
    if curl --head --silent --output /dev/null --max-time 10 --proto '=https' https://registry.npmjs.org/ < /dev/null; then
        printf '@diag\tcheck\tnetwork\tok\t-\n'
    else
        printf '@diag\tcheck\tnetwork\tfail\t-\n'
    fi
}

web_service_active() {
    local expected="$2" pid_file="$HOME/.local/share/termux-ai/web/$1.pid" pid
    [[ -f "$pid_file" ]] || return 1
    IFS= read -r pid < "$pid_file" || return 1
    [[ $pid =~ ^[1-9][0-9]*$ && -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$expected"
}

diagnose_local() {
    local venv_py="$HOME/.venv-ai/bin/python3"
    local hf_cache="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--google--embeddinggemma-2"
    if [[ ! -e "$HOME/.venv-ai" && ! -L "$HOME/.venv-ai" ]]; then
        printf '@diag\tlocal\tembeddinggemma\tmissing\t-\n'
    elif [[ -x "$venv_py" ]] && timeout 30s "$venv_py" -c 'import fastapi, sentence_transformers, uvicorn' < /dev/null > /dev/null 2>&1; then
        if [[ -d "$hf_cache" ]]; then
            printf '@diag\tlocal\tembeddinggemma\tready\t2.0.0\n'
        else
            printf '@diag\tlocal\tembeddinggemma\tinstalled\t2.0.0\n'
        fi
    else
        printf '@diag\tlocal\tembeddinggemma\tbroken\t-\n'
    fi
    if web_service_active painel 'termux-ai/hub/server.mjs'; then
        printf '@diag\tweb\tpainel\tactive\t127.0.0.1:7690\n'
    else
        printf '@diag\tweb\tpainel\tstopped\t-\n'
    fi
    if web_service_active terminal 'ttyd -i lo -p 7680'; then
        printf '@diag\tweb\tterminal\tactive\t127.0.0.1:7680\n'
    else
        printf '@diag\tweb\tterminal\tstopped\t-\n'
    fi
    if web_service_active embedding 'embeddinggemma_web.py --host 127.0.0.1 --port 8085'; then
        printf '@diag\tweb\tembedding\tactive\t127.0.0.1:8085\n'
    else
        printf '@diag\tweb\tembedding\tstopped\t-\n'
    fi
}

# Saida para o Termux: @diag, tipo, nome, situacao e detalhe.
print_diagnostics() {
    local tool
    for tool in "${agent_tools[@]}" "${optional_tools[@]}"; do
        (
            diagnose_agent "$tool" > "$work_dir/$tool.diag"
            if [[ $tool == codex ]]; then
                codex_isolation > "$work_dir/isolation.diag"
            fi
        ) &
    done
    diagnose_network > "$work_dir/network.diag" &
    diagnose_local > "$work_dir/local.diag" &
    diagnose_system "$1"
    wait
    for tool in "${agent_tools[@]}" "${optional_tools[@]}"; do
        cat -- "$work_dir/$tool.diag"
    done
    cat -- "$work_dir/network.diag"
    printf '@diag\tisolation\tcodex\t%s\t-\n' "$(< "$work_dir/isolation.diag")"
    cat -- "$work_dir/local.diag"
}

stage="${1:-}"
case "$stage" in
    system)
        [[ $(id -u) == 0 ]] || fail 'Esta etapa exige o root simulado do PRoot.'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl git gh ripgrep nano ttyd tmux libatomic1
        exit 0
        ;;
    embeddinggemma-system)
        [[ $(id -u) == 0 ]] || fail 'Esta etapa exige o root simulado do PRoot.'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends python3 python3-venv
        exit 0
        ;;
    agents|opencode|versions|update|diagnose|embeddinggemma-install|install-assets) ;;
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
    embeddinggemma-install)
        [[ $# -eq 1 ]] || fail 'Uso interno: embeddinggemma-install.'
        command -v python3 >/dev/null 2>&1 || fail 'Python 3 nao instalado; execute ia embeddinggemma install novamente.'
        if [[ ! -e "$HOME/.venv-ai" ]]; then
            python3 -m venv "$HOME/.venv-ai"
        fi
        [[ -x "$HOME/.venv-ai/bin/python3" && -x "$HOME/.venv-ai/bin/pip" ]] \
            || fail "$HOME/.venv-ai existe, mas nao e um ambiente Python utilizavel."
        "$HOME/.venv-ai/bin/pip" install sentence-transformers fastapi uvicorn
        "$HOME/.venv-ai/bin/python3" -c 'import fastapi, sentence_transformers, uvicorn'
        printf '%s\n' 'EmbeddingGemma instalado. O modelo sera baixado no primeiro uso.'
        ;;
    install-assets)
        [[ $# -eq 2 ]] || fail 'Uso interno: install-assets <repositorio>.'
        source_dir="$2"
        [[ -d "$source_dir/scripts" ]] || fail "Repositorio nao encontrado: $source_dir"
        mkdir -p "$HOME/.local/share/termux-ai/tools" "$HOME/.local/share/termux-ai/web" "$HOME/.local/share/termux-ai/hub" "$HOME/.local/bin"
        install -m 644 "$source_dir/scripts/setup-linux.sh" "$HOME/.local/share/termux-ai/setup-linux.sh"
        install -m 644 "$source_dir/scripts/webui.sh" "$HOME/.local/share/termux-ai/webui.sh"
        install -m 644 "$source_dir/scripts/web-menu.sh" "$HOME/.local/share/termux-ai/web/menu.sh"
        for hub_file in util.mjs agents.mjs orchestrator.mjs sessions.mjs server.mjs cli.mjs index.html attach.sh tmux.conf; do
            install -m 644 "$source_dir/scripts/hub/$hub_file" "$HOME/.local/share/termux-ai/hub/$hub_file"
        done
        install -m 644 "$source_dir/scripts/embeddinggemma_web.py" "$HOME/.local/share/termux-ai/tools/embeddinggemma_web.py"
        install -m 644 "$source_dir/scripts/embeddinggemma_cli.py" "$HOME/.local/share/termux-ai/tools/embeddinggemma_cli.py"
        if [[ ! -e "$HOME/.local/bin/embeddinggemma" && ! -L "$HOME/.local/bin/embeddinggemma" ]]; then
            install -m 755 "$source_dir/scripts/embeddinggemma-launcher.sh" "$HOME/.local/bin/embeddinggemma"
        fi
        if [[ ! -e "$HOME/.local/bin/embedding" && ! -L "$HOME/.local/bin/embedding" ]]; then
            ln -s embeddinggemma "$HOME/.local/bin/embedding"
        fi
        ;;
    versions)
        print_versions
        ;;
    diagnose)
        [[ $# -le 2 ]] || fail 'Uso interno: diagnose [pasta].'
        print_diagnostics "${2:-}"
        ;;
    update)
        [[ $# -eq 3 ]] || fail 'Uso interno: update <agente> <versao>.'
        tool_name="$2"
        target_version="$3"
        case "$tool_name" in
            copilot|claude|codex|agy|opencode|hermes) ;;
            *) fail "Agente desconhecido: $tool_name" ;;
        esac
        [[ $target_version =~ ^${version_pattern}$ ]] || fail "Versao invalida: $target_version"
        check_node
        install_agent "$tool_name" "$target_version"
        actual_version="$(installed_version "$tool_name")" \
            || fail "$(display_name "$tool_name") nao respondeu ao teste de versao apos a atualizacao."
        if [[ $tool_name == hermes ]]; then
            # O Hermes segue o proprio canal de atualizacao e pode ficar acima ou abaixo da versao consultada.
            version_at_least "$actual_version" "$target_version" \
                || printf 'Aviso: o Hermes Agent informou %s; a ultima release consultada e %s.\n' "$actual_version" "$target_version" >&2
        else
            [[ $actual_version == "$target_version" ]] \
                || fail "$(display_name "$tool_name") informou $actual_version; esperado $target_version."
        fi
        printf 'Atualizado: %s %s\n' "$(display_name "$tool_name")" "$actual_version"
        ;;
esac