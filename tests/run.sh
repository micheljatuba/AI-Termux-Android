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

for tool_name in codex copilot claude; do
    cp "$project_root/bin/ia" "$test_root/bin/$tool_name"
    bash "$test_root/bin/$tool_name" --version
    mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
    assert_equal "${actual_args[11]}" "$tool_name" "dispatches $tool_name shortcut"
    assert_equal "${actual_args[12]}" --version 'preserves shortcut arguments'
done
printf '%s\n' 'PASS all three shortcuts'

bash "$project_root/bin/ia" terminal -c 'printf terminal-ok'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" /bin/bash 'opens the Linux terminal'
assert_equal "${actual_args[12]}" -l 'loads the terminal profile'
assert_equal "${actual_args[14]}" 'printf terminal-ok' 'preserves terminal command'
printf '%s\n' 'PASS terminal dispatch'

if TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" claude > "$test_root/nested.log" 2>&1; then
    printf '%s\n' 'FAIL nested launcher was accepted' >&2
    exit 1
fi
grep -q 'nao foi encontrado' "$test_root/nested.log"
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

printf 'existing launcher\n' > "$PREFIX/bin/copilot"
if bash "$project_root/install.sh" --yes > "$test_root/conflict.log" 2>&1; then
    printf '%s\n' 'FAIL existing command was overwritten' >&2
    exit 1
fi
assert_equal "$(< "$PREFIX/bin/copilot")" 'existing launcher' 'preserves existing commands'
test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
rm "$PREFIX/bin/copilot"
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
for tool_name in ia codex copilot claude; do
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

for relative_path in install.sh bin/ia scripts/setup-linux.sh scripts/menu.bash tests/run.sh; do
    bash -n "$project_root/$relative_path"
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        printf 'FAIL: CRLF in %s\n' "$relative_path" >&2
        exit 1
    fi
done
printf '%s\n' 'PASS shell syntax and Linux line endings'