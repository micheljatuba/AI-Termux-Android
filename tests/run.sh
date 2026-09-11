#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/project with spaces"
export TERMUX_AI_TEST_ARGS="$test_root/arguments"
export PATH="$test_root/bin:$PATH"
unset TERMUX_AI_GUEST

cat > "$test_root/bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$TERMUX_AI_TEST_ARGS"
exit "${TERMUX_AI_TEST_EXIT:-0}"
MOCK
chmod +x "$test_root/bin/proot-distro"

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s\nExpected: <%s>\nActual: <%s>\n' "$3" "$2" "$1" >&2
        exit 1
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

for tool_name in codex copilot claude antigravity agy; do
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

bash "$project_root/bin/ia" terminal -c 'printf terminal-ok'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" /bin/bash 'opens the Linux terminal'
assert_equal "${actual_args[12]}" -l 'loads the terminal profile'
assert_equal "${actual_args[14]}" 'printf terminal-ok' 'preserves terminal command'
printf '%s\n' 'PASS terminal dispatch'

for tool_name in claude antigravity agy; do
    if TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" "$tool_name" > "$test_root/nested.log" 2>&1; then
        printf '%s\n' 'FAIL nested launcher was accepted' >&2
        exit 1
    fi
    grep -q 'nao foi encontrado' "$test_root/nested.log"
done
printf '%s\n' 'PASS recursion guard'

rm "$TERMUX_AI_TEST_ARGS"
bash "$project_root/bin/ia" --help > "$test_root/help.log"
bash "$project_root/bin/ia" < /dev/null >> "$test_root/help.log"
test ! -e "$TERMUX_AI_TEST_ARGS"
grep -q 'Uso:' "$test_root/help.log"
if bash "$project_root/bin/ia" unknown > /dev/null 2>&1; then
    printf '%s\n' 'FAIL unknown command was accepted' >&2
    exit 1
fi
printf '%s\n' 'PASS help and invalid commands'

actual_status=0
TERMUX_AI_TEST_EXIT=17 bash "$project_root/bin/ia" copilot || actual_status=$?
assert_equal "$actual_status" 17 'preserves agent exit status'
printf '%s\n' 'PASS exit status'

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
printf '10001\n'
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

for tool_name in copilot antigravity agy; do
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
cmp "$state_dir/bashrc.before" <(printf 'export ORIGINAL_SETTING=kept\n')
bash "$project_root/install.sh" --yes > "$test_root/reinstall.log"
assert_equal "$(grep -c '^proot install ' "$TERMUX_AI_TEST_INSTALL_LOG")" 1 'does not reinstall the Linux image'
assert_equal "$(grep -c 'menu.bash' "$HOME/.bashrc")" 1 'does not duplicate the startup hook'
assert_equal "$(< "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs/project")" 'keep this project' 'preserves other Linux data'
for tool_name in ia codex copilot claude antigravity agy; do
    test -x "$PREFIX/bin/$tool_name"
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
assert_equal "$(head -n 1 "$PREFIX/bin/ia")" "#!$PREFIX/bin/bash" 'uses the actual Termux prefix'
printf '%s\n' 'PASS mock installation, managed rerun and preserved configuration'

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
export USER=node
export TERMUX_AI_TEST_DOWNLOAD_LOG="$test_root/download.log"
export TERMUX_AI_TEST_AGY_PAYLOAD="$test_root/antigravity.tar.gz"
mkdir -p "$HOME/.local/bin" "$test_root/payload"
cat > "$test_root/payload/antigravity" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --version ]] || exit 2
printf 'agy mock 1.2.1\n'
exit "${TERMUX_AI_TEST_AGY_VERSION_FAILURE:-0}"
MOCK
tar -czf "$TERMUX_AI_TEST_AGY_PAYLOAD" -C "$test_root/payload" antigravity
TERMUX_AI_TEST_AGY_SHA512="$(sha512sum "$TERMUX_AI_TEST_AGY_PAYLOAD" | awk '{ print $1 }')"
export TERMUX_AI_TEST_AGY_SHA512
cat > "$test_root/bin/npm" <<'MOCK'
#!/usr/bin/env bash
for tool_name in codex copilot; do
    printf '#!/usr/bin/env bash\nprintf "%s mock\\n"\n' "$tool_name" > "$HOME/.local/bin/$tool_name"
    chmod +x "$HOME/.local/bin/$tool_name"
done
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
        printf '#!/usr/bin/env bash\nprintf '\''#!/usr/bin/env bash\\nprintf "claude mock\\\\n"\\n'\'' > "$HOME/.local/bin/claude"\nchmod +x "$HOME/.local/bin/claude"\n' > "$destination"
        ;;
    https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_*.json)
        node - "$destination" <<'NODE'
const { writeFileSync } = require('node:fs');
const manifest = {
    version: '1.2.1',
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
chmod +x "$test_root/bin/npm" "$test_root/bin/curl"
printf 'alias antigravity=existing-editor\n' > "$HOME/.bashrc"
cp "$HOME/.bashrc" "$test_root/guest-bashrc.before"
bash "$project_root/scripts/setup-linux.sh" agents > "$test_root/guest-setup.log"
test -x "$HOME/.local/bin/agy"
grep -q 'agy mock 1.2.1' "$test_root/guest-setup.log"
cmp "$HOME/.bashrc" "$test_root/guest-bashrc.before"
cp "$HOME/.local/bin/agy" "$test_root/agy.before"
printf '%s\n' 'PASS Antigravity manifest, checksum, install and preserved aliases'

for failure_mode in url missing-hash checksum; do
    : > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
    if TERMUX_AI_TEST_BAD_AGY_MANIFEST="$failure_mode" bash "$project_root/scripts/setup-linux.sh" agents > "$test_root/agy-failure.log" 2>&1; then
        printf 'FAIL bad Antigravity manifest accepted: %s\n' "$failure_mode" >&2
        exit 1
    fi
    cmp "$HOME/.local/bin/agy" "$test_root/agy.before"
    if [[ "$failure_mode" != checksum ]] && grep -q 'storage.googleapis.com' "$TERMUX_AI_TEST_DOWNLOAD_LOG"; then
        printf '%s\n' 'FAIL package download happened before manifest validation' >&2
        exit 1
    fi
done
printf '%s\n' 'PASS Antigravity rejects invalid sources, missing hashes and corrupted downloads'

cat > "$test_root/payload/antigravity" <<'MOCK'
#!/usr/bin/env bash
printf 'agy broken candidate\n'
exit 3
MOCK
tar -czf "$TERMUX_AI_TEST_AGY_PAYLOAD" -C "$test_root/payload" antigravity
TERMUX_AI_TEST_AGY_SHA512="$(sha512sum "$TERMUX_AI_TEST_AGY_PAYLOAD" | awk '{ print $1 }')"
if bash "$project_root/scripts/setup-linux.sh" agents > "$test_root/agy-version-failure.log" 2>&1; then
    printf '%s\n' 'FAIL broken Antigravity executable was installed' >&2
    exit 1
fi
cmp "$HOME/.local/bin/agy" "$test_root/agy.before"
printf '%s\n' 'PASS Antigravity startup failure preserves the installed binary'

for relative_path in install.sh bin/ia scripts/setup-linux.sh scripts/menu.bash tests/run.sh; do
    bash -n "$project_root/$relative_path"
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        printf 'FAIL: CRLF in %s\n' "$relative_path" >&2
        exit 1
    fi
done
printf '%s\n' 'PASS shell syntax and Linux line endings'