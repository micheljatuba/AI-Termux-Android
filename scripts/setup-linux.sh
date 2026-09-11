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
        installer_dir="$(mktemp -d)"
        trap 'rm -rf -- "$installer_dir"' EXIT
        curl --fail --show-error --location --proto '=https' --tlsv1.2 \
            --output "$installer_dir/claude-install.sh" https://claude.ai/install.sh
        bash "$installer_dir/claude-install.sh" 2.1.269

        case "$(uname -m)" in
            aarch64|arm64) antigravity_platform=linux_arm64 ;;
            x86_64|amd64) antigravity_platform=linux_amd64 ;;
            *) printf '%s\n' 'Arquitetura nao suportada pelo Antigravity CLI.' >&2; exit 1 ;;
        esac
        antigravity_manifest_base='https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests'
        curl --fail --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --output "$installer_dir/antigravity.json" "$antigravity_manifest_base/$antigravity_platform.json"
        antigravity_release="$(node - "$installer_dir/antigravity.json" <<'NODE'
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
        )"
        mapfile -t antigravity_fields <<< "$antigravity_release"
        printf 'Instalando Antigravity CLI %s (%s).\n' "${antigravity_fields[2]}" "$antigravity_platform"
        curl --fail --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --output "$installer_dir/antigravity-package" "${antigravity_fields[0]}"
        if ! printf '%s  %s\n' "${antigravity_fields[1]}" "$installer_dir/antigravity-package" | sha512sum --check --status; then
            printf '%s\n' 'SHA-512 do Antigravity nao confere; instalacao interrompida.' >&2
            exit 1
        fi
        case "${antigravity_fields[0]}" in
            *.tar.gz)
                tar --extract --gzip --file "$installer_dir/antigravity-package" \
                    --directory "$installer_dir" --no-same-owner --no-same-permissions antigravity
                ;;
            *) cp -- "$installer_dir/antigravity-package" "$installer_dir/antigravity" ;;
        esac
        [[ -f "$installer_dir/antigravity" && ! -L "$installer_dir/antigravity" ]] || {
            printf '%s\n' 'O pacote Antigravity nao contem um executavel regular.' >&2; exit 1;
        }
        chmod 755 "$installer_dir/antigravity"
        timeout 60s "$installer_dir/antigravity" --version
        install -m 755 "$installer_dir/antigravity" "$HOME/.local/bin/agy"

        profile_entry='export PATH="$HOME/.local/bin:$PATH"'
        if [[ ! -f "$HOME/.profile" ]] || ! grep -Fqx "$profile_entry" "$HOME/.profile"; then
            if [[ -f "$HOME/.profile" && ! -e "$HOME/.profile.termux-ai.before" ]]; then
                cp -p -- "$HOME/.profile" "$HOME/.profile.termux-ai.before"
            fi
            printf '\n%s\n' "$profile_entry" >> "$HOME/.profile"
        fi
        for tool_name in codex copilot claude agy; do
            timeout 60s "$HOME/.local/bin/$tool_name" --version
        done
        ;;
    *) printf '%s\n' 'Etapa interna desconhecida. Use install.sh no Termux.' >&2; exit 2 ;;
esac