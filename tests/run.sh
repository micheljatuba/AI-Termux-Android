#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_script="$project_root/scripts/setup-linux.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/project with spaces" "$test_root/launcher-home"
export HOME="$test_root/launcher-home"
export TERMUX_AI_TEST_ARGS="$test_root/arguments"
export TERMUX_AI_TEST_STAGE_INPUT="$test_root/stage-input"
export TERMUX_AI_TEST_STAGE_VERBOSE="$test_root/stage-verbose"
export TERMUX_AI_TEST_VERSIONS="$test_root/versions.txt"
export TERMUX_AI_TEST_UPDATES="$test_root/updates.log"
export PATH="$test_root/bin:$PATH"
unset TERMUX_AI_GUEST PROOT_VERBOSE

cat > "$test_root/bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$TERMUX_AI_TEST_ARGS"
arguments=("$@")
for index in "${!arguments[@]}"; do
    if [[ ${arguments[index]} == -se && ${arguments[index + 1]:-} == -- ]]; then
        cat > "$TERMUX_AI_TEST_STAGE_INPUT"
        printf '%s\n' "${PROOT_VERBOSE-unset}" > "$TERMUX_AI_TEST_STAGE_VERBOSE"
        case "${arguments[index + 2]:-}" in
            versions) cat "$TERMUX_AI_TEST_VERSIONS" ;;
            update)
                printf '%s %s\n' "${arguments[index + 3]:-}" "${arguments[index + 4]:-}" >> "$TERMUX_AI_TEST_UPDATES"
                if [[ " ${TERMUX_AI_TEST_UPDATE_FAILURES:-} " == *" ${arguments[index + 3]:-} "* ]]; then
                    exit 1
                fi
                ;;
        esac
        exit 0
    fi
done
exit "${TERMUX_AI_TEST_EXIT:-0}"
MOCK
chmod +x "$test_root/bin/proot-distro"

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s\nExpected: <%s>\nActual: <%s>\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local description="$1"
    shift
    if "$@" > "$test_root/expected-failure.log" 2>&1; then
        fail_test "$description"
    fi
}

cd "$test_root/project with spaces"
bash "$project_root/bin/ia" copilot 'two words' 'literal;value' '"quoted"' ''
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[0]}" login 'uses login'
assert_equal "${actual_args[1]}" termux-ai 'uses a dedicated container'
assert_equal "${actual_args[3]}" node 'uses the image non-root user'
assert_equal "${actual_args[5]}" "$PWD" 'preserves the working directory'
assert_equal "${actual_args[7]}" /bin/bash 'uses the Linux shell'
assert_equal "${actual_args[8]}" -lc 'loads the Linux login profile'
assert_equal "${actual_args[11]}" copilot 'selects the requested agent'
assert_equal "${actual_args[12]}" 'two words' 'preserves spaces'
assert_equal "${actual_args[13]}" 'literal;value' 'does not evaluate punctuation'
assert_equal "${actual_args[14]}" '"quoted"' 'preserves quotes'
assert_equal "${actual_args[15]}" '' 'preserves empty arguments'
printf '%s\n' 'PASS launcher argument transport'

for tool_name in codex copilot claude antigravity agy opencode; do
    cp "$project_root/bin/ia" "$test_root/bin/$tool_name"
    bash "$test_root/bin/$tool_name" --version
    mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
    expected_tool="$tool_name"
    if [[ "$tool_name" == antigravity ]]; then
        expected_tool=agy
    fi
    assert_equal "${actual_args[11]}" "$expected_tool" "dispatches $tool_name shortcut"
    assert_equal "${actual_args[12]}" --version 'preserves shortcut arguments'
done
printf '%s\n' 'PASS all agent shortcuts'

for tool_name in antigravity agy; do
    bash "$project_root/bin/ia" "$tool_name" 'two words' 'literal;value' ''
    mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
    assert_equal "${actual_args[11]}" agy 'uses the official Antigravity CLI command'
    assert_equal "${actual_args[12]}" 'two words' 'preserves Antigravity prompt spaces'
    assert_equal "${actual_args[13]}" 'literal;value' 'preserves Antigravity punctuation'
    assert_equal "${actual_args[14]}" '' 'preserves Antigravity empty arguments'
done
printf '%s\n' 'PASS Antigravity aliases and argument transport'

bash "$project_root/bin/ia" opencode auth login --provider 'GitHub Copilot'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" opencode 'uses the official OpenCode command'
assert_equal "${actual_args[12]}" auth 'preserves the auth subcommand'
assert_equal "${actual_args[13]}" login 'preserves the login action'
assert_equal "${actual_args[14]}" --provider 'preserves the provider flag'
assert_equal "${actual_args[15]}" 'GitHub Copilot' 'preserves provider names with spaces'
printf '%s\n' 'PASS OpenCode auth argument transport'

bash "$project_root/bin/ia" terminal -c 'printf terminal-ok'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" /bin/bash 'opens the Linux terminal'
assert_equal "${actual_args[12]}" -l 'loads the terminal profile'
assert_equal "${actual_args[14]}" 'printf terminal-ok' 'preserves terminal command'
bash "$project_root/bin/ia" ubuntu -c 'printf ubuntu-ok'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" /bin/bash 'accepts the ubuntu terminal alias'
assert_equal "${actual_args[12]}" -l 'loads the profile for the ubuntu alias'
assert_equal "${actual_args[14]}" 'printf ubuntu-ok' 'preserves the ubuntu alias command'
printf '%s\n' 'PASS terminal dispatch'

launcher_state="$HOME/.local/share/termux-ai"
mkdir -p "$launcher_state"
printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" claude 'two words'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[1]}" ubuntu 'uses the adopted Ubuntu'
assert_equal "${actual_args[2]}" --work-dir 'keeps the default root user of the adopted Ubuntu'
assert_equal "${actual_args[3]}" "$PWD" 'preserves the working directory in the adopted Ubuntu'
assert_equal "${actual_args[9]}" claude 'selects the agent in the adopted Ubuntu'
assert_equal "${actual_args[10]}" 'two words' 'preserves arguments in the adopted Ubuntu'
printf 'name=ubuntu\nuser=dev' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" codex
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[2]}" --user 'passes a configured Linux user'
assert_equal "${actual_args[3]}" dev 'uses the configured Linux user'
assert_equal "${actual_args[11]}" codex 'selects the agent for a configured user'
for invalid_config in $'name=../other\nuser=root' $'name=ubuntu\nuser=root;id' 'name=-ubuntu'; do
    printf '%s\n' "$invalid_config" > "$launcher_state/linux.conf"
    rm -f "$TERMUX_AI_TEST_ARGS"
    expect_failure 'invalid Linux configuration was accepted' bash "$project_root/bin/ia" copilot
    grep -q 'Configuracao invalida' "$test_root/expected-failure.log"
    test ! -e "$TERMUX_AI_TEST_ARGS"
done
rm "$launcher_state/linux.conf"
printf '%s\n' 'PASS Linux selection from the installer configuration'

for tool_name in claude antigravity agy opencode; do
    if TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" "$tool_name" > "$test_root/nested.log" 2>&1; then
        printf '%s\n' 'FAIL nested launcher was accepted' >&2
        exit 1
    fi
    grep -q 'nao foi encontrado' "$test_root/nested.log"
done
printf '%s\n' 'PASS recursion guard'

rm -f "$TERMUX_AI_TEST_ARGS"
bash "$project_root/bin/ia" --help > "$test_root/help.log"
bash "$project_root/bin/ia" < /dev/null >> "$test_root/help.log"
test ! -e "$TERMUX_AI_TEST_ARGS"
grep -q 'Uso:' "$test_root/help.log"
grep -q 'OpenCode:' "$test_root/help.log"
grep -q 'ia versoes' "$test_root/help.log"
grep -q 'ia atualizar' "$test_root/help.log"
if bash "$project_root/bin/ia" unknown > /dev/null 2>&1; then
    printf '%s\n' 'FAIL unknown command was accepted' >&2
    exit 1
fi
printf '%s\n' 'PASS help and invalid commands'

actual_status=0
TERMUX_AI_TEST_EXIT=17 bash "$project_root/bin/ia" copilot || actual_status=$?
assert_equal "$actual_status" 17 'preserves agent exit status'
printf '%s\n' 'PASS exit status'

mkdir -p "$launcher_state"
cp "$setup_script" "$launcher_state/setup-linux.sh"
printf '%s\n' \
    'proot info: unrelated output' \
    $'@version\tcopilot\t1.0.90\t1.0.91\toutdated' \
    $'@version\tclaude\t2.1.289\t2.1.289\tcurrent' \
    $'@version\tcodex\t0.159.3\t0.160.0\toutdated' \
    $'@version\tagy\t-\t1.2.16\tmissing' \
    $'@version\topencode\t1.18.34\t-\tunknown' \
    $'@version\tgemini\t1.0.0\t2.0.0\toutdated' \
    $'@version\tcopilot\t1.0;id\t2.0.0\toutdated' \
    > "$TERMUX_AI_TEST_VERSIONS"
bash "$project_root/bin/ia" versoes > "$test_root/versions.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]}" 'login termux-ai --user node -- /bin/bash -se -- versions' 'queries versions inside the managed Linux'
cmp "$TERMUX_AI_TEST_STAGE_INPUT" "$launcher_state/setup-linux.sh"
assert_equal "$(< "$TERMUX_AI_TEST_STAGE_VERBOSE")" -1 'silences PRoot warnings during maintenance'
grep -Eq '^GitHub Copilot +1\.0\.90 +1\.0\.91 +atualizacao disponivel$' "$test_root/versions.log"
grep -Eq '^Claude Code +2\.1\.289 +2\.1\.289 +atualizado$' "$test_root/versions.log"
grep -Eq '^Codex +0\.159\.3 +0\.160\.0 +atualizacao disponivel$' "$test_root/versions.log"
grep -Eq '^Antigravity CLI +- +1\.2\.16 +nao instalado$' "$test_root/versions.log"
grep -Eq '^OpenCode +1\.18\.34 +- +sem consulta$' "$test_root/versions.log"
assert_equal "$(grep -Ec '^(GitHub Copilot|Claude Code|Codex|Antigravity CLI|OpenCode) ' "$test_root/versions.log")" 5 'shows one row per agent'
if grep -Eq 'gemini|unrelated|;id' "$test_root/versions.log"; then
    fail_test 'unexpected Linux output reached the version table'
fi
grep -q 'Para atualizar: ia atualizar' "$test_root/versions.log"
printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" versoes > /dev/null
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]}" 'login ubuntu -- /bin/bash -se -- versions' 'queries versions inside the adopted Ubuntu'
rm "$launcher_state/linux.conf"
printf '%s\n' 'PASS version table from the Linux stage'

: > "$TERMUX_AI_TEST_UPDATES"
expect_failure 'update ran without confirmation' bash "$project_root/bin/ia" atualizar < /dev/null
grep -q 'ia atualizar --yes' "$test_root/expected-failure.log"
grep -Eq '^  GitHub Copilot +1\.0\.90 -> 1\.0\.91$' "$test_root/expected-failure.log"
test ! -s "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar --yes > "$test_root/update.log"
assert_equal "$(< "$TERMUX_AI_TEST_UPDATES")" $'copilot 1.0.91\ncodex 0.160.0\nagy 1.2.16' 'updates only agents with a newer known version'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]}" 'login termux-ai --user node -- /bin/bash -se -- update agy 1.2.16' 'updates inside the managed Linux'
grep -q 'Atualizacao concluida' "$test_root/update.log"
: > "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar -y antigravity > /dev/null
assert_equal "$(< "$TERMUX_AI_TEST_UPDATES")" 'agy 1.2.16' 'updates only the selected agent'
: > "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar --yes claude opencode > "$test_root/update-none.log"
grep -q 'Nenhuma atualizacao disponivel' "$test_root/update-none.log"
test ! -s "$TERMUX_AI_TEST_UPDATES"
expect_failure 'failed update was reported as success' env TERMUX_AI_TEST_UPDATE_FAILURES=copilot bash "$project_root/bin/ia" atualizar --yes
assert_equal "$(< "$TERMUX_AI_TEST_UPDATES")" $'copilot 1.0.91\ncodex 0.160.0\nagy 1.2.16' 'continues after a failed update'
grep -q 'Falha ao atualizar: GitHub Copilot\.' "$test_root/expected-failure.log"
printf '%s\n' 'PASS updates follow the confirmed plan and report failures'

rm -f "$TERMUX_AI_TEST_ARGS"
actual_status=0
bash "$project_root/bin/ia" atualizar --yes gemini > /dev/null 2>&1 || actual_status=$?
assert_equal "$actual_status" 2 'rejects unknown agents'
actual_status=0
bash "$project_root/bin/ia" versoes extra > /dev/null 2>&1 || actual_status=$?
assert_equal "$actual_status" 2 'rejects extra version arguments'
test ! -e "$TERMUX_AI_TEST_ARGS"
expect_failure 'empty version output was accepted' env TERMUX_AI_TEST_VERSIONS=/dev/null bash "$project_root/bin/ia" versoes
grep -q 'Nao foi possivel consultar' "$test_root/expected-failure.log"
mv "$launcher_state/setup-linux.sh" "$test_root/setup-linux.saved"
rm -f "$TERMUX_AI_TEST_ARGS"
expect_failure 'maintenance ran without the installed Linux stage' bash "$project_root/bin/ia" atualizar --yes
grep -q 'bash install.sh' "$test_root/expected-failure.log"
test ! -e "$TERMUX_AI_TEST_ARGS"
mv "$test_root/setup-linux.saved" "$launcher_state/setup-linux.sh"
expect_failure 'maintenance ran inside Linux' env TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" versoes
grep -q 'fora do Linux' "$test_root/expected-failure.log"
test ! -e "$TERMUX_AI_TEST_ARGS"
printf '%s\n' 'PASS maintenance commands validate their environment'

export HOME="$test_root/home"
export PREFIX="$test_root/prefix"
export TERMUX__PREFIX="$PREFIX"
export TERMUX_AI_TEST_INSTALL_LOG="$test_root/install.log"
mkdir -p "$HOME" "$PREFIX/bin"
cat > "$PREFIX/bin/pkg" <<'MOCK'
#!/usr/bin/env bash
printf 'pkg %s\n' "$*" >> "$TERMUX_AI_TEST_INSTALL_LOG"
MOCK
cat > "$test_root/bin/getprop" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${TERMUX_AI_TEST_SDK:-30}"
MOCK
cat > "$test_root/bin/dpkg" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    --print-architecture) printf '%s\n' "${TERMUX_AI_TEST_ARCH:-aarch64}" ;;
    --compare-versions) exit "${TERMUX_AI_TEST_OLD_PROOT:-0}" ;;
    *) exit 2 ;;
esac
MOCK
cat > "$test_root/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
printf '5.3.0\n'
MOCK
cat > "$test_root/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf '/data 20000000 10000000 %s 50%% /data\n' "${TERMUX_AI_TEST_FREE:-10000000}"
MOCK
cat > "$test_root/bin/id" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${TERMUX_AI_TEST_UID:-10001}"
MOCK
cat > "$test_root/bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
printf 'proot %s\n' "$*" >> "$TERMUX_AI_TEST_INSTALL_LOG"
case "$1" in
    install)
        test "$2" = node:24-bookworm-slim || exit 2
        test "$3" = --name || exit 2
        test "$4" = termux-ai || exit 2
        mkdir -p "$PREFIX/var/lib/proot-distro/containers/termux-ai/rootfs"
        ;;
    login)
        if [[ "$*" == *'/bin/bash -se -- '* ]]; then
            cat > /dev/null
        fi
        exit "${TERMUX_AI_TEST_GUEST_FAILURE:-0}"
        ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$PREFIX/bin/pkg" "$test_root/bin/"*

expect_preflight_failure() {
    if env "$1" bash "$project_root/install.sh" --check > "$test_root/preflight.log" 2>&1; then
        printf 'FAIL: unsupported environment accepted: %s\n' "$1" >&2
        exit 1
    fi
    test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
    test ! -e "$HOME/.local"
}

expect_preflight_failure TERMUX_AI_TEST_SDK=29
expect_preflight_failure TERMUX_AI_TEST_ARCH=arm
expect_preflight_failure TERMUX_AI_TEST_FREE=1024
expect_preflight_failure TERMUX_AI_GUEST=1
expect_preflight_failure PREFIX=/not-termux
bash "$project_root/install.sh" --check > "$test_root/preflight.log"
test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
test ! -e "$HOME/.local"
printf '%s\n' 'PASS read-only preflight and unsupported environments'

for tool_name in copilot antigravity agy opencode; do
    printf 'existing launcher\n' > "$PREFIX/bin/$tool_name"
    if bash "$project_root/install.sh" --yes > "$test_root/conflict.log" 2>&1; then
        printf '%s\n' 'FAIL existing command was overwritten' >&2
        exit 1
    fi
    assert_equal "$(< "$PREFIX/bin/$tool_name")" 'existing launcher' 'preserves existing commands'
    test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
    rm "$PREFIX/bin/$tool_name"
done
mkdir -p "$PREFIX/var/lib/proot-distro/containers/termux-ai/rootfs"
if bash "$project_root/install.sh" --yes > "$test_root/conflict.log" 2>&1; then
    printf '%s\n' 'FAIL unrelated container was accepted' >&2
    exit 1
fi
test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
rmdir "$PREFIX/var/lib/proot-distro/containers/termux-ai/rootfs" "$PREFIX/var/lib/proot-distro/containers/termux-ai"
printf '%s\n' 'PASS existing commands and unrelated Linux are preserved'

mkdir -p "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs"
printf 'keep this project\n' > "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs/project"
printf 'export ORIGINAL_SETTING=kept\n' > "$HOME/.bashrc"
bash "$project_root/install.sh" --yes > "$test_root/first-install.log"
state_dir="$HOME/.local/share/termux-ai"
printf 'export ORIGINAL_SETTING=kept\n' > "$test_root/bashrc.expected"
cmp "$state_dir/bashrc.before" "$test_root/bashrc.expected"
assert_equal "$(< "$state_dir/linux.conf")" $'name=termux-ai\nuser=node' 'records the managed Linux'
cmp "$state_dir/setup-linux.sh" "$setup_script"
grep -Fqx 'proot login termux-ai -- /bin/bash -se -- system' "$TERMUX_AI_TEST_INSTALL_LOG"
grep -Fqx 'proot login termux-ai --user node -- /bin/bash -se -- agents' "$TERMUX_AI_TEST_INSTALL_LOG"
bash "$project_root/install.sh" --yes > "$test_root/reinstall.log"
assert_equal "$(grep -c '^proot install ' "$TERMUX_AI_TEST_INSTALL_LOG")" 1 'does not reinstall the Linux image'
assert_equal "$(grep -c 'menu.bash' "$HOME/.bashrc")" 1 'does not duplicate the startup hook'
assert_equal "$(< "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs/project")" 'keep this project' 'preserves other Linux data'
for tool_name in ia codex copilot claude antigravity agy opencode; do
    test -x "$PREFIX/bin/$tool_name"
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
assert_equal "$(head -n 1 "$PREFIX/bin/ia")" "#!$PREFIX/bin/bash" 'uses the actual Termux prefix'
printf '%s\n' 'PASS mock installation, managed rerun and preserved configuration'

expect_failure 'adoption replaced the managed Linux' bash "$project_root/install.sh" --yes --adopt-ubuntu
grep -q 'usa o Linux termux-ai' "$test_root/expected-failure.log"
assert_equal "$(< "$state_dir/linux.conf")" $'name=termux-ai\nuser=node' 'keeps the managed Linux selected'
for tool_name in ia codex copilot claude antigravity agy opencode; do
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
printf '%s\n' 'PASS managed installation refuses Ubuntu adoption'

cp "$HOME/.bashrc" "$test_root/bashrc.installed"
bash "$project_root/install.sh" --yes --no-menu > "$test_root/no-menu.log"
test ! -e "$state_dir/menu.bash"
cmp "$HOME/.bashrc" "$test_root/bashrc.installed"
printf '%s\n' 'PASS optional menu can be disabled without rewriting Bash configuration'

printf 'user customization\n' >> "$PREFIX/bin/claude"
if bash "$project_root/install.sh" --yes > "$test_root/customization.log" 2>&1; then
    printf '%s\n' 'FAIL customized launcher was overwritten' >&2
    exit 1
fi
grep -q 'user customization' "$PREFIX/bin/claude"
printf '%s\n' 'PASS customized launcher is preserved'

export HOME="$test_root/failed-home"
export PREFIX="$test_root/failed-prefix"
export TERMUX__PREFIX="$PREFIX"
mkdir -p "$HOME" "$PREFIX/bin"
cp "$test_root/prefix/bin/pkg" "$PREFIX/bin/pkg"
if TERMUX_AI_TEST_GUEST_FAILURE=3 bash "$project_root/install.sh" --yes > "$test_root/failed-install.log" 2>&1; then
    printf '%s\n' 'FAIL guest installation failure was ignored' >&2
    exit 1
fi
test -d "$PREFIX/var/lib/proot-distro/containers/termux-ai/rootfs"
test ! -e "$PREFIX/bin/ia"
test ! -e "$HOME/.bashrc"
test ! -e "$HOME/.local/share/termux-ai/install.lock"
bash "$project_root/install.sh" --yes > "$test_root/recovered-install.log"
test -x "$PREFIX/bin/ia"
printf '%s\n' 'PASS guest failure stops cleanly and can be retried'

export HOME="$test_root/guest-home"
export TERMUX_AI_TEST_DOWNLOAD_LOG="$test_root/download.log"
export TERMUX_AI_TEST_NPM_LOG="$test_root/npm.log"
export TERMUX_AI_TEST_AGY_PAYLOAD="$test_root/antigravity.tar.gz"
mkdir -p "$HOME" "$test_root/payload"
codex_pin="$(sed -n 's/^codex_version=//p' "$setup_script")"
copilot_pin="$(sed -n 's/^copilot_version=//p' "$setup_script")"
claude_pin="$(sed -n 's/^claude_version=//p' "$setup_script")"
opencode_pin="$(sed -n 's/^opencode_version=//p' "$setup_script")"
for pinned_version in "$codex_pin" "$copilot_pin" "$claude_pin" "$opencode_pin"; do
    [[ $pinned_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_test "invalid pinned version <$pinned_version>"
done

# Bloqueia agentes reais do ambiente de teste: nenhum deve ser consultado ou alterado.
for tool_name in codex copilot claude agy opencode antigravity; do
    printf '#!/usr/bin/env bash\nexit 127\n' > "$test_root/bin/$tool_name"
done

make_agy_payload() {
    printf '#!/usr/bin/env bash\n[[ "$1" == --version ]] || exit 2\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" \
        > "$test_root/payload/antigravity"
    chmod 755 "$test_root/payload/antigravity"
    tar -czf "$TERMUX_AI_TEST_AGY_PAYLOAD" -C "$test_root/payload" antigravity
    TERMUX_AI_TEST_AGY_SHA512="$(sha512sum "$TERMUX_AI_TEST_AGY_PAYLOAD" | awk '{ print $1 }')"
    export TERMUX_AI_TEST_AGY_SHA512
}

cat > "$test_root/bin/npm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TERMUX_AI_TEST_NPM_LOG"
select_package() {
    case "$1" in
        @openai/codex) tool=codex; latest="${TERMUX_AI_TEST_LATEST_CODEX:-}" ;;
        @github/copilot) tool=copilot; latest="${TERMUX_AI_TEST_LATEST_COPILOT:-}" ;;
        @anthropic-ai/claude-code) tool=claude; latest="${TERMUX_AI_TEST_LATEST_CLAUDE:-}" ;;
        opencode-ai) tool=opencode; latest="${TERMUX_AI_TEST_LATEST_OPENCODE:-}" ;;
        *) printf 'Unexpected package: %s\n' "$1" >&2; exit 2 ;;
    esac
}
case "${1:-}" in
    view)
        [[ $# -eq 3 && $3 == version ]] || exit 2
        select_package "$2"
        [[ -n $latest && $latest != fail ]] || exit 1
        printf '%s\n' "$latest"
        ;;
    install)
        shift
        prefix=''
        ignore_scripts=0
        spec=''
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -g) ;;
                --prefix) prefix="$2"; shift ;;
                --ignore-scripts) ignore_scripts=1 ;;
                -*) exit 2 ;;
                *) [[ -z $spec ]] || exit 2; spec="$1" ;;
            esac
            shift
        done
        [[ -n $prefix && $spec == ?*@* ]] || exit 2
        package="${spec%@*}"
        version="${TERMUX_AI_TEST_NPM_REPORTED_VERSION:-${spec##*@}}"
        select_package "$package"
        package_dir="$prefix/lib/node_modules/$package"
        mkdir -p "$package_dir" "$prefix/bin"
        if [[ $tool == opencode ]]; then
            [[ $ignore_scripts == 1 ]] || exit 2
            [[ ${TERMUX_AI_TEST_OPENCODE_NPM_FAILURE:-0} == 0 ]] || exit 3
            printf '%s\n' "$version" > "$package_dir/version.txt"
            cat > "$package_dir/postinstall.mjs" <<'NODE'
import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
if (process.env.TERMUX_AI_TEST_OPENCODE_POSTINSTALL_FAILURE === '1') process.exit(4);
const version = readFileSync(new URL('./version.txt', import.meta.url), 'utf8').trim();
const target = new URL('../../../bin/opencode', import.meta.url);
writeFileSync(target, `#!/usr/bin/env bash\nprintf '%s\\n' '${version}'\nexit "\${TERMUX_AI_TEST_OPENCODE_VERSION_FAILURE:-0}"\n`);
chmodSync(target, 0o755);
console.log('OpenCode postinstall executed');
NODE
            exit 0
        fi
        case "$tool" in
            codex) version_line="codex-cli $version" ;;
            copilot) version_line="GitHub Copilot CLI $version." ;;
            claude) version_line="$version (Claude Code)" ;;
        esac
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$version_line" > "$package_dir/cli.sh"
        if [[ $tool == copilot ]]; then
            printf '%s\n' "printf '%s\\n' \"Run 'copilot update' to check for updates.\"" >> "$package_dir/cli.sh"
        fi
        chmod 755 "$package_dir/cli.sh"
        ln -sfn "../lib/node_modules/$package/cli.sh" "$prefix/bin/$tool"
        ;;
    *) exit 2 ;;
esac
MOCK
cat > "$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
destination=''
source_url=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) destination="$2"; shift ;;
        https://*) source_url="$1" ;;
    esac
    shift
done
printf '%s\n' "$source_url" >> "$TERMUX_AI_TEST_DOWNLOAD_LOG"
case "$source_url" in
    https://claude.ai/install.sh)
        cat > "$destination" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s (Claude Code)"\n' "$1" > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
INSTALLER
        ;;
    https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_*.json)
        [[ ${TERMUX_AI_TEST_AGY_OFFLINE:-0} == 0 ]] || exit 6
        node - "$destination" <<'NODE'
const { writeFileSync } = require('node:fs');
const manifest = {
    version: process.env.TERMUX_AI_TEST_AGY_VERSION || '1.2.1',
    url: 'https://storage.googleapis.com/antigravity-public/antigravity-cli/test/agy.tar.gz',
    sha512: process.env.TERMUX_AI_TEST_AGY_SHA512,
};
if (process.env.TERMUX_AI_TEST_BAD_AGY_MANIFEST === 'url') manifest.url = 'https://example.invalid/agy.tar.gz';
if (process.env.TERMUX_AI_TEST_BAD_AGY_MANIFEST === 'missing-hash') delete manifest.sha512;
if (process.env.TERMUX_AI_TEST_BAD_AGY_MANIFEST === 'checksum') manifest.sha512 = '0'.repeat(128);
writeFileSync(process.argv[2], JSON.stringify(manifest));
NODE
        ;;
    https://storage.googleapis.com/antigravity-public/antigravity-cli/test/agy.tar.gz)
        cp "$TERMUX_AI_TEST_AGY_PAYLOAD" "$destination"
        ;;
    *) printf 'Unexpected download: %s\n' "$source_url" >&2; exit 2 ;;
esac
MOCK
chmod +x "$test_root/bin/"*

printf 'alias antigravity=existing-editor\n' > "$HOME/.bashrc"
cp "$HOME/.bashrc" "$test_root/guest-bashrc.before"
make_agy_payload 1.2.1 0
: > "$TERMUX_AI_TEST_NPM_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
bash "$setup_script" agents > "$test_root/guest-setup.log"
expected_npm="$(printf 'install -g --prefix %s %s\n' \
    "$HOME/.local" "@openai/codex@$codex_pin" \
    "$HOME/.local" "@github/copilot@$copilot_pin" \
    "$HOME/.local" "--ignore-scripts opencode-ai@$opencode_pin")"
assert_equal "$(< "$TERMUX_AI_TEST_NPM_LOG")" "$expected_npm" 'installs npm agents at the validated versions'
grep -Fqx 'https://claude.ai/install.sh' "$TERMUX_AI_TEST_DOWNLOAD_LOG"
grep -Fqx 'https://storage.googleapis.com/antigravity-public/antigravity-cli/test/agy.tar.gz' "$TERMUX_AI_TEST_DOWNLOAD_LOG"
grep -q 'OpenCode postinstall executed' "$test_root/guest-setup.log"
for expected_line in "Verificado: GitHub Copilot $copilot_pin" "Verificado: Claude Code $claude_pin" \
    "Verificado: Codex $codex_pin" 'Verificado: Antigravity CLI 1.2.1' "Verificado: OpenCode $opencode_pin"; do
    grep -Fqx "$expected_line" "$test_root/guest-setup.log" || fail_test "missing <$expected_line>"
done
test -x "$HOME/.local/bin/agy"
cmp "$HOME/.bashrc" "$test_root/guest-bashrc.before"
# shellcheck disable=SC2016
profile_entry='export PATH="$HOME/.local/bin:$PATH"'
assert_equal "$(grep -Fxc "$profile_entry" "$HOME/.profile")" 1 'adds the local PATH to the profile'
printf '%s\n' 'PASS fresh guest installs every agent at the validated version'

: > "$TERMUX_AI_TEST_NPM_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
bash "$setup_script" agents > "$test_root/guest-rerun.log"
test ! -s "$TERMUX_AI_TEST_NPM_LOG"
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
assert_equal "$(grep -c 'ja instalado; mantido\.$' "$test_root/guest-rerun.log")" 5 'keeps every installed agent'
assert_equal "$(grep -Fxc "$profile_entry" "$HOME/.profile")" 1 'keeps a single PATH entry'
expect_failure 'agents stage ran as root without confirmation' env TERMUX_AI_TEST_UID=0 bash "$setup_script" agents
grep -q 'usuario comum' "$test_root/expected-failure.log"
TERMUX_AI_TEST_UID=0 bash "$setup_script" agents --root > "$test_root/guest-root.log"
assert_equal "$(grep -c 'ja instalado; mantido\.$' "$test_root/guest-root.log")" 5 'root stage keeps installed agents'
test ! -s "$TERMUX_AI_TEST_NPM_LOG"
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
printf '%s\n' 'PASS guest rerun keeps agents and root needs explicit confirmation'

npm install -g --prefix "$HOME/.local" @openai/codex@9.9.9 > /dev/null
: > "$TERMUX_AI_TEST_NPM_LOG"
bash "$setup_script" agents > "$test_root/guest-newer.log"
grep -Fqx 'Codex 9.9.9 ja instalado; mantido.' "$test_root/guest-newer.log"
grep -Fqx 'Verificado: Codex 9.9.9' "$test_root/guest-newer.log"
test ! -s "$TERMUX_AI_TEST_NPM_LOG"
npm install -g --prefix "$HOME/.local" "@openai/codex@$codex_pin-alpha.1" > /dev/null
: > "$TERMUX_AI_TEST_NPM_LOG"
bash "$setup_script" agents > "$test_root/guest-prerelease.log"
grep -Fqx "Codex $codex_pin-alpha.1 esta abaixo da versao validada $codex_pin." "$test_root/guest-prerelease.log"
assert_equal "$(< "$TERMUX_AI_TEST_NPM_LOG")" "install -g --prefix $HOME/.local @openai/codex@$codex_pin" 'upgrades a prerelease below the validated version'
grep -Fqx "Verificado: Codex $codex_pin" "$test_root/guest-prerelease.log"
printf '%s\n' 'PASS newer agents are never downgraded'

system_prefix="$test_root/system prefix"
npm install -g --prefix "$system_prefix" @openai/codex@0.100.0 > /dev/null
npm install -g --prefix "$system_prefix" @anthropic-ai/claude-code@2.0.0 > /dev/null
mv "$HOME/.local/bin/codex" "$test_root/codex.local"
mv "$HOME/.local/bin/claude" "$test_root/claude.local"
: > "$TERMUX_AI_TEST_NPM_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
PATH="$system_prefix/bin:$PATH" bash "$setup_script" agents > "$test_root/guest-system-prefix.log"
expected_npm="$(printf 'install -g --prefix %s %s\n' \
    "$system_prefix" "@openai/codex@$codex_pin" \
    "$system_prefix" "@anthropic-ai/claude-code@$claude_pin")"
assert_equal "$(< "$TERMUX_AI_TEST_NPM_LOG")" "$expected_npm" 'upgrades agents inside their existing npm prefix'
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
test ! -e "$HOME/.local/bin/codex"
test ! -e "$HOME/.local/bin/claude"
grep -Fqx "Verificado: Codex $codex_pin" "$test_root/guest-system-prefix.log"
grep -Fqx "Verificado: Claude Code $claude_pin" "$test_root/guest-system-prefix.log"
mv "$test_root/codex.local" "$HOME/.local/bin/codex"
mv "$test_root/claude.local" "$HOME/.local/bin/claude"
printf '%s\n' 'PASS existing npm prefixes are reused'

expected_versions="$(printf '@version\t%s\t%s\t%s\t%s\n' \
    copilot "$copilot_pin" - unknown \
    claude "$claude_pin" 9.0.0 outdated \
    codex "$codex_pin" "$codex_pin" current \
    agy 1.2.1 1.2.16 outdated \
    opencode "$opencode_pin" "$opencode_pin-beta.1" current)"
TERMUX_AI_TEST_LATEST_COPILOT=fail TERMUX_AI_TEST_LATEST_CLAUDE=9.0.0 TERMUX_AI_TEST_LATEST_CODEX="$codex_pin" \
    TERMUX_AI_TEST_LATEST_OPENCODE="$opencode_pin-beta.1" TERMUX_AI_TEST_AGY_VERSION=1.2.16 \
    bash "$setup_script" versions > "$test_root/guest-versions.log"
assert_equal "$(< "$test_root/guest-versions.log")" "$expected_versions" 'reports installed and available versions'
mv "$HOME/.local/bin/agy" "$test_root/agy.saved"
TERMUX_AI_TEST_AGY_OFFLINE=1 bash "$setup_script" versions > "$test_root/guest-versions-missing.log"
grep -Fqx $'@version\tagy\t-\t-\tmissing' "$test_root/guest-versions-missing.log"
mv "$test_root/agy.saved" "$HOME/.local/bin/agy"
npm install -g --prefix "$HOME/.local" @openai/codex@1.0.0-beta.2 > /dev/null
TERMUX_AI_TEST_LATEST_CODEX=1.0.0-beta.10 bash "$setup_script" versions > "$test_root/guest-versions-prerelease.log"
grep -Fqx $'@version\tcodex\t1.0.0-beta.2\t1.0.0-beta.10\toutdated' "$test_root/guest-versions-prerelease.log"
TERMUX_AI_TEST_LATEST_CODEX=1.0.0-beta.1 bash "$setup_script" versions > "$test_root/guest-versions-prerelease.log"
grep -Fqx $'@version\tcodex\t1.0.0-beta.2\t1.0.0-beta.1\tcurrent' "$test_root/guest-versions-prerelease.log"
npm install -g --prefix "$HOME/.local" "@openai/codex@$codex_pin" > /dev/null
printf '%s\n' 'PASS version stage compares installed and published versions'

: > "$TERMUX_AI_TEST_NPM_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
bash "$setup_script" update codex 0.999.0 > "$test_root/guest-update.log"
assert_equal "$(< "$TERMUX_AI_TEST_NPM_LOG")" "install -g --prefix $HOME/.local @openai/codex@0.999.0" 'updates Codex in its npm prefix'
grep -Fqx 'Atualizado: Codex 0.999.0' "$test_root/guest-update.log"
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
bash "$setup_script" update claude 9.0.0 > "$test_root/guest-update-claude.log"
grep -Fqx 'Atualizado: Claude Code 9.0.0' "$test_root/guest-update-claude.log"
assert_equal "$(< "$TERMUX_AI_TEST_DOWNLOAD_LOG")" 'https://claude.ai/install.sh' 'updates Claude with the official installer'
make_agy_payload 1.2.16 0
TERMUX_AI_TEST_AGY_VERSION=1.2.16 bash "$setup_script" update agy 1.2.16 > "$test_root/guest-update-agy.log"
grep -Fqx 'Atualizado: Antigravity CLI 1.2.16' "$test_root/guest-update-agy.log"
cp "$HOME/.local/bin/agy" "$test_root/agy.before"
expect_failure 'update accepted a different installed version' \
    env TERMUX_AI_TEST_NPM_REPORTED_VERSION=0.998.0 bash "$setup_script" update codex 0.999.1
grep -q 'esperado 0\.999\.1' "$test_root/expected-failure.log"
printf '%s\n' 'PASS update stage installs and verifies the confirmed version'

: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
expect_failure 'Antigravity installed a version other than the confirmed one' \
    env TERMUX_AI_TEST_AGY_VERSION=1.2.16 bash "$setup_script" update agy 1.2.17
grep -q 'agora indica 1\.2\.16' "$test_root/expected-failure.log"
if grep -q 'storage.googleapis.com' "$TERMUX_AI_TEST_DOWNLOAD_LOG"; then
    fail_test 'Antigravity package was downloaded for an unconfirmed version'
fi
cmp "$HOME/.local/bin/agy" "$test_root/agy.before"
for failure_mode in url missing-hash checksum; do
    : > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
    expect_failure "bad Antigravity manifest accepted: $failure_mode" \
        env TERMUX_AI_TEST_BAD_AGY_MANIFEST="$failure_mode" TERMUX_AI_TEST_AGY_VERSION=1.2.16 bash "$setup_script" update agy 1.2.16
    cmp "$HOME/.local/bin/agy" "$test_root/agy.before"
    if [[ $failure_mode != checksum ]] && grep -q 'storage.googleapis.com' "$TERMUX_AI_TEST_DOWNLOAD_LOG"; then
        fail_test 'package download happened before manifest validation'
    fi
done
printf '%s\n' 'PASS Antigravity rejects invalid sources, missing hashes and corrupted downloads'

make_agy_payload 1.2.16 3
expect_failure 'broken Antigravity executable was installed' \
    env TERMUX_AI_TEST_AGY_VERSION=1.2.16 bash "$setup_script" update agy 1.2.16
cmp "$HOME/.local/bin/agy" "$test_root/agy.before"
make_agy_payload 1.2.16 0
printf '%s\n' 'PASS Antigravity startup failure preserves the installed binary'

for failure_flag in TERMUX_AI_TEST_OPENCODE_NPM_FAILURE=1 TERMUX_AI_TEST_OPENCODE_POSTINSTALL_FAILURE=1 TERMUX_AI_TEST_OPENCODE_VERSION_FAILURE=5; do
    : > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
    expect_failure "OpenCode failure ignored: $failure_flag" env "$failure_flag" bash "$setup_script" update opencode "$opencode_pin"
    test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
done
export HOME="$test_root/failed-guest-home"
mkdir -p "$HOME"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
expect_failure 'OpenCode installation failure was ignored' env TERMUX_AI_TEST_OPENCODE_NPM_FAILURE=1 bash "$setup_script" agents
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
test ! -e "$HOME/.local/bin/claude"
export HOME="$test_root/guest-home"
printf '%s\n' 'PASS OpenCode install and startup failures stop the setup'

: > "$TERMUX_AI_TEST_NPM_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
for invalid_stage in update 'update codex' 'update gemini 1.0.0' 'update codex 1.0' 'update codex 1.0.0;id' 'update codex 1.0.0 extra' unknown; do
    read -r -a stage_args <<< "$invalid_stage"
    expect_failure "invalid stage accepted: $invalid_stage" bash "$setup_script" "${stage_args[@]}"
done
test ! -s "$TERMUX_AI_TEST_NPM_LOG"
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
printf '%s\n' 'PASS invalid internal stages change nothing'

rm "$HOME/.local/bin/opencode"
for tool_name in codex copilot claude agy; do
    cp "$HOME/.local/bin/$tool_name" "$test_root/$tool_name.before-opencode"
done
bash "$setup_script" opencode > "$test_root/opencode-only.log"
assert_equal "$(< "$TERMUX_AI_TEST_NPM_LOG")" "install -g --prefix $HOME/.local --ignore-scripts opencode-ai@$opencode_pin" 'installs only OpenCode'
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
grep -Fqx "$opencode_pin" "$test_root/opencode-only.log"
for tool_name in codex copilot claude agy; do
    cmp "$HOME/.local/bin/$tool_name" "$test_root/$tool_name.before-opencode"
done
bash "$setup_script" opencode > "$test_root/opencode-only-rerun.log"
grep -Fqx "OpenCode $opencode_pin ja instalado; mantido." "$test_root/opencode-only-rerun.log"
printf '%s\n' 'PASS OpenCode-only setup preserves the other agents'

export HOME="$test_root/ubuntu-home"
export PREFIX="$test_root/ubuntu-prefix"
export TERMUX__PREFIX="$PREFIX"
mkdir -p "$HOME" "$PREFIX/bin"
cp "$test_root/prefix/bin/pkg" "$PREFIX/bin/pkg"
cat > "$PREFIX/bin/ia" <<'LEGACY'
#!/usr/bin/env bash
set -euo pipefail
launcher_name="${0##*/}"
if [[ "$launcher_name" == ia ]]; then
    if [[ $# -eq 0 ]]; then
        printf '\nIA no Android\n\n1. Codex\n2. GitHub Copilot\n3. Claude Code\n4. Terminal Ubuntu\n5. Google Antigravity CLI (experimental)\n0. Sair\n\n'
        read -r -p 'Escolha: ' selection
        case "$selection" in
            1) tool_name=codex ;;
            2) tool_name=copilot ;;
            3) tool_name=claude ;;
            4) tool_name=ubuntu ;;
            5) tool_name=agy ;;
            0) exit 0 ;;
            *) exit 2 ;;
        esac
    elif [[ "$1" == --help ]]; then
        printf '%s\n' 'Uso: ia {codex|copilot|claude|antigravity|agy|ubuntu} [argumentos]'
        exit 0
    else
        tool_name="$1"
        shift
    fi
else
    tool_name="$launcher_name"
fi
case "$tool_name" in
    codex|copilot|claude) ;;
    antigravity|agy) tool_name=agy ;;
    ubuntu|terminal) tool_name=bash; set -- -l "$@" ;;
    *) exit 2 ;;
esac
if [[ ${TERMUX_AI_GUEST:-} == 1 ]]; then exit 1; fi
exec proot-distro login ubuntu --work-dir "$PWD" -- /bin/bash -lc 'export TERMUX_AI_GUEST=1; exec "$@"' termux-ai "$tool_name" "$@"
LEGACY
cp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.before"
printf 'original opencode command\n' > "$PREFIX/bin/opencode"
if bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/ubuntu-conflict.log" 2>&1; then
    printf '%s\n' 'FAIL Ubuntu addition overwrote an existing OpenCode command' >&2
    exit 1
fi
assert_equal "$(< "$PREFIX/bin/opencode")" 'original opencode command' 'preserves existing OpenCode command'
cmp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.before"
rm "$PREFIX/bin/opencode"
printf '%s\n' 'PASS Ubuntu addition preserves conflicting commands'

if TERMUX_AI_TEST_GUEST_FAILURE=3 bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/ubuntu-install-failure.log" 2>&1; then
    printf '%s\n' 'FAIL Ubuntu addition ignored installation failure' >&2
    exit 1
fi
cmp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.before"
test ! -e "$PREFIX/bin/opencode"
printf '%s\n' 'PASS Ubuntu installation failure leaves the menu unchanged'

bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/ubuntu-opencode.log"
test -x "$PREFIX/bin/opencode"
cmp "$PREFIX/bin/opencode" "$PREFIX/bin/ia"
cmp "$HOME"/.cache/termux-ai-opencode.*/ia "$test_root/ubuntu-launcher.before"
grep -Fq '\n6. OpenCode (experimental)\n0. Sair' "$PREFIX/bin/ia"
grep -Fq '1) tool_name=codex ;;' "$PREFIX/bin/ia"
grep -Fq '2) tool_name=copilot ;;' "$PREFIX/bin/ia"
grep -Fq '5) tool_name=agy ;;' "$PREFIX/bin/ia"
grep -Fq '6) tool_name=opencode ;;' "$PREFIX/bin/ia"
printf '6\n' | bash "$PREFIX/bin/ia" > "$test_root/ubuntu-menu.log"
grep -Fq '6. OpenCode (experimental)' "$test_root/ubuntu-menu.log"
grep -q 'proot login ubuntu .*termux-ai opencode$' "$TERMUX_AI_TEST_INSTALL_LOG"
cp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.after"
bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/ubuntu-opencode-rerun.log"
grep -q 'ja esta integrado' "$test_root/ubuntu-opencode-rerun.log"
cmp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.after"
printf '%s\n' 'PASS Ubuntu menu option 6, backup and repeat installation'

rm "$PREFIX/bin/opencode"
sed 's/Google Antigravity CLI (experimental)/Google Antigravity CLI/g' "$test_root/ubuntu-launcher.before" > "$PREFIX/bin/ia"
bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/ubuntu-no-label.log"
grep -Fq '\n5. Google Antigravity CLI\n6. OpenCode (experimental)' "$PREFIX/bin/ia"
grep -Fq '6) tool_name=opencode ;;' "$PREFIX/bin/ia"
cmp "$PREFIX/bin/ia" "$PREFIX/bin/opencode"
if grep -q 'Antigravity.*experimental' "$test_root/help.log"; then
    printf '%s\n' 'FAIL Antigravity still has the experimental label in help' >&2
    exit 1
fi
printf '%s\n' 'PASS Ubuntu update accepts Antigravity without the old label'

rm "$PREFIX/bin/opencode"
printf 'unknown_menu_format=true\n' > "$PREFIX/bin/ia"
cp "$PREFIX/bin/ia" "$test_root/unknown-launcher.before"
if bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/unknown-menu.log" 2>&1; then
    printf '%s\n' 'FAIL unknown Ubuntu menu was changed' >&2
    exit 1
fi
cmp "$PREFIX/bin/ia" "$test_root/unknown-launcher.before"
test ! -e "$PREFIX/bin/opencode"
sed 's/5) tool_name=agy/5) tool_name=custom/' "$test_root/ubuntu-launcher.before" > "$PREFIX/bin/ia"
cp "$PREFIX/bin/ia" "$test_root/custom-menu.before"
if bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes > "$test_root/custom-menu.log" 2>&1; then
    printf '%s\n' 'FAIL customized Ubuntu menu was changed' >&2
    exit 1
fi
grep -q 'Formato de menu nao reconhecido' "$test_root/custom-menu.log"
cmp "$PREFIX/bin/ia" "$test_root/custom-menu.before"
test ! -e "$PREFIX/bin/opencode"
printf '%s\n' 'PASS unrecognized Ubuntu menu is preserved'

export HOME="$test_root/adopt-home"
export PREFIX="$test_root/adopt-prefix"
export TERMUX__PREFIX="$PREFIX"
export TERMUX_AI_TEST_INSTALL_LOG="$test_root/adopt-install.log"
mkdir -p "$HOME" "$PREFIX/bin"
cp "$test_root/prefix/bin/pkg" "$PREFIX/bin/pkg"
cp "$test_root/ubuntu-launcher.before" "$PREFIX/bin/ia"
cp "$test_root/ubuntu-launcher.before" "$PREFIX/bin/opencode"
for tool_name in codex copilot claude antigravity agy; do
    ln -s ia "$PREFIX/bin/$tool_name"
done
# shellcheck disable=SC2016
printf '%s\n' \
    'export KEEP_BEFORE=1' \
    'if [[ $- == *i* && -z ${SSH_CONNECTION:-} && -t 0 && -t 1 ]]; then' \
    '    if command -v ia >/dev/null 2>&1; then' \
    '        ia' \
    '    fi' > "$HOME/.bashrc"
printf 'fi' >> "$HOME/.bashrc"
cp "$HOME/.bashrc" "$test_root/adopt-bashrc.before"
expect_failure 'adoption accepted a missing Ubuntu' bash "$project_root/install.sh" --adopt-ubuntu --check
grep -q 'Nenhum Ubuntu' "$test_root/expected-failure.log"
ubuntu_rootfs="$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs"
mkdir -p "$ubuntu_rootfs/root/project"
printf 'keep this project\n' > "$ubuntu_rootfs/root/project/notes.txt"
bash "$project_root/install.sh" --adopt-ubuntu --check > "$test_root/adopt-check.log"
grep -q 'Ubuntu existente' "$test_root/adopt-check.log"
printf 'export KEEP_BEFORE=1\nia\n' > "$HOME/.bashrc"
expect_failure 'adoption kept a second menu call' bash "$project_root/install.sh" --adopt-ubuntu --check
grep -q 'ja abre o menu ia' "$test_root/expected-failure.log"
bash "$project_root/install.sh" --adopt-ubuntu --check --no-menu > /dev/null
cp "$test_root/adopt-bashrc.before" "$HOME/.bashrc"
rm "$PREFIX/bin/copilot"
printf 'custom copilot\n' > "$PREFIX/bin/copilot"
expect_failure 'adoption accepted an unknown command' bash "$project_root/install.sh" --adopt-ubuntu --check
grep -q 'O comando copilot ja existe' "$test_root/expected-failure.log"
rm "$PREFIX/bin/copilot"
ln -s /bin/true "$PREFIX/bin/copilot"
expect_failure 'adoption accepted a foreign link' bash "$project_root/install.sh" --adopt-ubuntu --check
grep -q 'O comando copilot ja existe' "$test_root/expected-failure.log"
rm "$PREFIX/bin/copilot"
ln -s ia "$PREFIX/bin/copilot"
test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
test ! -e "$HOME/.local"
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.before"
printf '%s\n' 'PASS Ubuntu adoption preflight is read-only and preserves unknown commands'

expect_failure 'adoption ignored a guest failure' env TERMUX_AI_TEST_GUEST_FAILURE=3 bash "$project_root/install.sh" --yes --adopt-ubuntu
state_dir="$HOME/.local/share/termux-ai"
test ! -e "$state_dir/adopted"
test ! -e "$state_dir/install.lock"
cmp "$PREFIX/bin/ia" "$test_root/ubuntu-launcher.before"
cmp "$PREFIX/bin/opencode" "$test_root/ubuntu-launcher.before"
for tool_name in codex copilot claude antigravity agy; do
    assert_equal "$(readlink "$PREFIX/bin/$tool_name")" ia "keeps the $tool_name link after a failure"
done
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.before"
rm "$TERMUX_AI_TEST_INSTALL_LOG"
cp -a "$HOME" "$test_root/undo-failed-home"
cp -a "$PREFIX" "$test_root/undo-failed-prefix"
printf '%s\n' 'PASS Ubuntu adoption failure keeps the manual setup'

bash "$project_root/install.sh" --yes --adopt-ubuntu > "$test_root/adopt.log"
grep -q 'Ubuntu existente integrado' "$test_root/adopt.log"
if grep -Eq '^proot install|--user' "$TERMUX_AI_TEST_INSTALL_LOG"; then
    fail_test 'adoption created a Linux or changed the Linux user'
fi
grep -Fqx 'proot login ubuntu -- /bin/bash -se -- system' "$TERMUX_AI_TEST_INSTALL_LOG"
grep -Fqx 'proot login ubuntu -- /bin/bash -se -- agents --root' "$TERMUX_AI_TEST_INSTALL_LOG"
assert_equal "$(< "$state_dir/linux.conf")" $'name=ubuntu\nuser=root' 'records the adopted Ubuntu'
cmp "$state_dir/setup-linux.sh" "$setup_script"
for tool_name in ia codex copilot claude antigravity agy opencode; do
    [[ -f "$PREFIX/bin/$tool_name" && ! -L "$PREFIX/bin/$tool_name" ]] || fail_test "$tool_name is not a managed command"
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
cmp "$state_dir/adopted/bin/ia" "$test_root/ubuntu-launcher.before"
cmp "$state_dir/adopted/bin/opencode" "$test_root/ubuntu-launcher.before"
for tool_name in codex copilot claude antigravity agy; do
    assert_equal "$(readlink "$state_dir/adopted/bin/$tool_name")" ia "keeps a backup of the $tool_name link"
done
cmp "$state_dir/bashrc.before" "$test_root/adopt-bashrc.before"
# shellcheck disable=SC2016
menu_hook='if [ -f "$HOME/.local/share/termux-ai/menu.bash" ]; then . "$HOME/.local/share/termux-ai/menu.bash"; fi'
printf 'export KEEP_BEFORE=1\n\n%s\n' "$menu_hook" > "$test_root/adopt-bashrc.expected"
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.expected"
assert_equal "$(< "$ubuntu_rootfs/root/project/notes.txt")" 'keep this project' 'preserves the adopted Ubuntu projects'
(cd "$test_root/project with spaces" && bash "$PREFIX/bin/copilot" --help)
last_line="$(tail -n 1 "$TERMUX_AI_TEST_INSTALL_LOG")"
[[ $last_line == "proot login ubuntu --work-dir $test_root/project with spaces -- /bin/bash -lc "*" termux-ai copilot --help" ]] \
    || fail_test "adopted launcher used <$last_line>"
printf '%s\n' 'PASS Ubuntu adoption keeps accounts, projects and command backups'

cp "$HOME/.bashrc" "$test_root/adopt-bashrc.installed"
bash "$project_root/install.sh" --yes > "$test_root/adopt-rerun.log"
grep -q 'Ubuntu existente integrado' "$test_root/adopt-rerun.log"
assert_equal "$(grep -c -e '-- agents --root$' "$TERMUX_AI_TEST_INSTALL_LOG")" 2 'reruns the adopted agent stage as root'
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.installed"
assert_equal "$(< "$state_dir/linux.conf")" $'name=ubuntu\nuser=root' 'keeps the adopted Ubuntu selected'
cmp "$state_dir/adopted/bin/ia" "$test_root/ubuntu-launcher.before"
cmp "$state_dir/adopted/bin/opencode" "$test_root/ubuntu-launcher.before"
for tool_name in ia codex copilot claude antigravity agy opencode; do
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
expect_failure 'OpenCode menu patch changed an adopted installation' bash "$project_root/scripts/add-opencode-ubuntu.sh" --yes
grep -q 'Instalacao gerenciada' "$test_root/expected-failure.log"
printf '%s\n' 'PASS adopted installation reruns without duplicating changes'

undo_script="$test_root/undo-adoption.sh"
awk '
    /^<summary>Desfazer a adocao<\/summary>$/ { inside = 1 }
    inside && /^```sh$/ { grab = 1; next }
    grab && /^```$/ { exit }
    grab { print }
' "$project_root/README.md" > "$undo_script"
grep -q 'adopted/bin' "$undo_script" || fail_test 'README has no commands to undo the adoption'
bash -n "$undo_script"

assert_manual_setup() {
    local prefix="$1" tool_name
    cmp "$prefix/bin/ia" "$test_root/ubuntu-launcher.before"
    cmp "$prefix/bin/opencode" "$test_root/ubuntu-launcher.before"
    shift
    for tool_name in "$@"; do
        assert_equal "$(readlink "$prefix/bin/$tool_name")" ia "restores the $tool_name link"
    done
}

HOME="$test_root/undo-failed-home" PREFIX="$test_root/undo-failed-prefix" \
    bash "$undo_script" > "$test_root/undo-failed.log"
grep -q 'Adocao desfeita' "$test_root/undo-failed.log"
test ! -e "$test_root/undo-failed-home/.local/share/termux-ai"
assert_manual_setup "$test_root/undo-failed-prefix" codex copilot claude antigravity agy
cmp "$test_root/undo-failed-home/.bashrc" "$test_root/adopt-bashrc.before"
test ! -e "$test_root/undo-failed-home/.bashrc.termux-ai-undo"

printf 'export AFTER_ADOPTION=1\n' >> "$HOME/.bashrc"
cp "$HOME/.bashrc" "$test_root/adopt-bashrc.edited"
printf 'user customization\n' >> "$PREFIX/bin/claude"
cp "$PREFIX/bin/claude" "$test_root/adopt-claude.custom"
rm "$PREFIX/bin/agy"
bash "$undo_script" > "$test_root/undo.log"
grep -q 'Adocao desfeita' "$test_root/undo.log"
test ! -e "$state_dir"
assert_manual_setup "$PREFIX" codex copilot antigravity agy
cmp "$PREFIX/bin/claude" "$test_root/adopt-claude.custom"
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.before"
cmp "$HOME/.bashrc.termux-ai-undo" "$test_root/adopt-bashrc.edited"
assert_equal "$(< "$ubuntu_rootfs/root/project/notes.txt")" 'keep this project' 'undo preserves the Ubuntu projects'

bash "$undo_script" > "$test_root/undo-again.log"
grep -q 'Nenhuma adocao' "$test_root/undo-again.log"
assert_manual_setup "$PREFIX" codex copilot antigravity agy
cmp "$HOME/.bashrc" "$test_root/adopt-bashrc.before"

HOME="$test_root/home" PREFIX="$test_root/prefix" bash "$undo_script" > "$test_root/undo-managed.log"
grep -q 'Nenhuma adocao' "$test_root/undo-managed.log"
test -f "$test_root/home/.local/share/termux-ai/container.managed"
cmp "$test_root/prefix/bin/ia" "$test_root/home/.local/share/termux-ai/bin/ia"
printf '%s\n' 'PASS adoption undo from the README restores the manual setup and repeats safely'

for relative_path in install.sh bin/ia scripts/setup-linux.sh scripts/menu.bash scripts/add-opencode-ubuntu.sh tests/run.sh; do
    bash -n "$project_root/$relative_path"
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        printf 'FAIL: CRLF in %s\n' "$relative_path" >&2
        exit 1
    fi
done
printf '%s\n' 'PASS shell syntax and Linux line endings'