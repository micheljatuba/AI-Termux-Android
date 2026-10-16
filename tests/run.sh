#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
setup_script="$project_root/scripts/setup-linux.sh"
test_root="$(mktemp -d)"
cleanup_tests() {
    if [[ -n ${port_blocker:-} ]]; then
        kill "$port_blocker" 2> /dev/null || true
    fi
    if [[ -f ${panel_state:-/nonexistent}/webui.sh ]]; then
        run_panel_webui stop todos > /dev/null 2>&1 || true
    fi
    if [[ -f ${TERMUX_AI_TEST_HANG_PID:-/nonexistent} ]]; then
        kill "$(< "$TERMUX_AI_TEST_HANG_PID")" 2> /dev/null || true
    fi
    rm -rf -- "$test_root"
}
trap cleanup_tests EXIT
mkdir -p "$test_root/bin" "$test_root/project with spaces" "$test_root/launcher-home"
export HOME="$test_root/launcher-home"
export TERMUX_AI_TEST_ARGS="$test_root/arguments"
export TERMUX_AI_TEST_STAGE_INPUT="$test_root/stage-input"
export TERMUX_AI_TEST_STAGE_VERBOSE="$test_root/stage-verbose"
export TERMUX_AI_TEST_CALLS="$test_root/proot-calls"
export TERMUX_AI_TEST_VERSIONS="$test_root/versions.txt"
export TERMUX_AI_TEST_DIAG="$test_root/diagnostics.txt"
export TERMUX_AI_TEST_UPDATES="$test_root/updates.log"
export TERMUX_AI_TEST_HANG_PID="$test_root/hung-proot.pid"
export PATH="$test_root/bin:$PATH"
unset TERMUX_AI_GUEST PROOT_VERBOSE

cat > "$test_root/bin/proot-distro" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$TERMUX_AI_TEST_CALLS"
printf '\n' >> "$TERMUX_AI_TEST_CALLS"
printf '%s\0' "$@" > "$TERMUX_AI_TEST_ARGS"
arguments=("$@")
for index in "${!arguments[@]}"; do
    if [[ ${arguments[index]} == -se && ${arguments[index + 1]:-} == -- ]]; then
        cat > "$TERMUX_AI_TEST_STAGE_INPUT"
        printf '%s\n' "${PROOT_VERBOSE-unset}" > "$TERMUX_AI_TEST_STAGE_VERBOSE"
        case "${arguments[index + 2]:-}" in
            versions) cat "$TERMUX_AI_TEST_VERSIONS" ;;
            diagnose) cat "$TERMUX_AI_TEST_DIAG" ;;
            update)
                printf '%s %s\n' "${arguments[index + 3]:-}" "${arguments[index + 4]:-}" >> "$TERMUX_AI_TEST_UPDATES"
                if [[ " ${TERMUX_AI_TEST_UPDATE_FAILURES:-} " == *" ${arguments[index + 3]:-} "* ]]; then
                    exit 1
                fi
                ;;
            start)
                printf "Warning: option '--no-kill-on-exit' is enabled, after logout your session will be blocked until all processes are terminated.\n" >&2
                # Como o PRoot real: o script termina, mas o processo segue vivo enquanto houver servicos no Linux.
                if [[ -n ${TERMUX_AI_TEST_WEB_REAL:-} ]]; then
                    printf '%s\n' "$$" > "$TERMUX_AI_TEST_HANG_PID"
                    bash "$TERMUX_AI_TEST_WEB_REAL" "${arguments[@]:index + 2}" || true
                    exec sleep 60
                fi
                web_target="${arguments[index + 3]:-}"
                case "$web_target" in
                    padrao) web_started=painel ;;
                    todos) web_started='painel terminal embedding' ;;
                    *) web_started="$web_target" ;;
                esac
                for web_name in ${TERMUX_AI_TEST_WEB_STARTED-$web_started}; do
                    case "$web_name" in
                        painel)
                            printf 'painel-ttyd iniciado em 127.0.0.1:7681 (PID 11).\n'
                            printf 'painel iniciado em 127.0.0.1:7690 (PID 12).\n'
                            printf 'Painel: http://127.0.0.1:7690/00112233445566778899aabbccddeeff/\n'
                            ;;
                        painel-morto)
                            printf 'painel-ttyd iniciado em 127.0.0.1:7681 (PID 11).\n'
                            printf 'painel iniciado em 127.0.0.1:7690 (PID 12).\n'
                            ;;
                        terminal) printf 'terminal iniciado em 127.0.0.1:7680 (PID 13).\n' ;;
                        embedding) printf 'embedding iniciado em 127.0.0.1:8085 (PID 14).\n' ;;
                    esac
                done
                if [[ -n ${TERMUX_AI_TEST_WEB_HANG:-} ]]; then
                    printf '%s\n' "$$" > "$TERMUX_AI_TEST_HANG_PID"
                    [[ ${TERMUX_AI_TEST_WEB_NO_MARKER:-} == 1 ]] || printf '__WEBUI_FIM__ %s\n' "${TERMUX_AI_TEST_WEB_EXIT:-0}"
                    exec sleep "$TERMUX_AI_TEST_WEB_HANG"
                fi
                exit "${TERMUX_AI_TEST_WEB_EXIT:-0}"
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

stop_hung_proot() {
    kill "$(< "$TERMUX_AI_TEST_HANG_PID")" 2> /dev/null || true
    rm -f "$TERMUX_AI_TEST_HANG_PID"
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

for tool_name in codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
    cp "$project_root/bin/ia" "$test_root/bin/$tool_name"
    bash "$test_root/bin/$tool_name" --version
    mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
    expected_tool="$tool_name"
    if [[ "$tool_name" == antigravity ]]; then
        expected_tool=agy
    elif [[ "$tool_name" == embedding ]]; then
        expected_tool=embeddinggemma
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
mkdir -p "$launcher_state/web" "$launcher_state/tools"
touch "$launcher_state/webui.sh" "$launcher_state/web/menu.sh" "$launcher_state/tools/embeddinggemma_web.py"
cp "$setup_script" "$launcher_state/setup-linux.sh"
printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" claude 'two words'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[1]}" ubuntu 'uses the adopted Ubuntu'
assert_equal "${actual_args[2]}" --work-dir 'keeps the default root user of the adopted Ubuntu'
assert_equal "${actual_args[3]}" "$PWD" 'preserves the working directory in the adopted Ubuntu'
assert_equal "${actual_args[9]}" claude 'selects the agent in the adopted Ubuntu'
assert_equal "${actual_args[10]}" 'two words' 'preserves arguments in the adopted Ubuntu'
printf 'name=ubuntu\nuser=dev' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" codex 2> /dev/null
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

fake_guest="$test_root/fake-guest"
mkdir -p "$fake_guest/.local/bin" "$fake_guest/.local/share/termux-ai/hub"
run_in_fake_guest() {
    local guest_script="$1"
    shift
    env -i HOME="$fake_guest" PATH=/usr/bin:/bin bash -c "$guest_script" termux-ai "$@"
}
bash "$project_root/bin/ia" hermes chat -q 'two words'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" hermes 'selects the optional Hermes Agent'
assert_equal "${actual_args[12]}" chat 'preserves the Hermes subcommand'
assert_equal "${actual_args[14]}" 'two words' 'preserves the Hermes prompt'
launch_script="${actual_args[9]}"
launch_status=0
run_in_fake_guest "$launch_script" hermes --version > "$test_root/hermes-missing.log" 2>&1 || launch_status=$?
assert_equal "$launch_status" 127 'a missing Hermes ends with the command-not-found status'
grep -Fq 'ia atualizar hermes' "$test_root/hermes-missing.log"
printf '#!/usr/bin/env bash\nprintf "guest=%%s args=%%s\\n" "$TERMUX_AI_GUEST" "$*"\n' > "$fake_guest/.local/bin/hermes"
chmod 755 "$fake_guest/.local/bin/hermes"
assert_equal "$(run_in_fake_guest "$launch_script" hermes chat -q 'two words')" 'guest=1 args=chat -q two words' \
    'runs an installed Hermes inside the Linux guest'

bash "$project_root/bin/ia" orquestrar comparar --agentes claude,copilot 'two words'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[2]}" --user 'runs the orchestrator as the dedicated user'
assert_equal "${actual_args[3]}" node 'uses the image non-root user for the orchestrator'
assert_equal "${actual_args[4]}" --work-dir 'preserves the directory for the orchestrator'
assert_equal "${actual_args[5]}" "$PWD" 'uses the current directory for the orchestrator'
assert_equal "${actual_args[7]}" /bin/bash 'runs the orchestrator through the Linux shell'
assert_equal "${actual_args[8]}" -lc 'loads the Linux login profile for the orchestrator'
assert_equal "${actual_args[11]}" comparar 'passes the orchestration mode'
assert_equal "${actual_args[12]}" --agentes 'passes the orchestration options'
assert_equal "${actual_args[13]}" claude,copilot 'passes the orchestration agents'
assert_equal "${actual_args[14]}" 'two words' 'keeps the orchestration task as one argument'
launch_script="${actual_args[9]}"
launch_status=0
run_in_fake_guest "$launch_script" comparar > "$test_root/orchestrate-missing.log" 2>&1 || launch_status=$?
assert_equal "$launch_status" 1 'stops when the panel components are missing'
grep -Fq 'Componentes do painel ausentes' "$test_root/orchestrate-missing.log"
: > "$fake_guest/.local/share/termux-ai/hub/cli.mjs"
printf '#!/usr/bin/env bash\nprintf "guest=%%s node %%s\\n" "$TERMUX_AI_GUEST" "$*"\n' > "$fake_guest/.local/bin/node"
chmod 755 "$fake_guest/.local/bin/node"
assert_equal "$(run_in_fake_guest "$launch_script" comparar --agentes claude,copilot 'two words')" \
    "guest=1 node $fake_guest/.local/share/termux-ai/hub/cli.mjs comparar --agentes claude,copilot two words" \
    'runs the orchestrator command inside the Linux guest'
rm -f "$TERMUX_AI_TEST_ARGS"
expect_failure 'ia orquestrar ran inside the Linux guest' env TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" orquestrar comparar
grep -Fq 'Use ia orquestrar no Termux, fora do Linux.' "$test_root/expected-failure.log"
test ! -e "$TERMUX_AI_TEST_ARGS" || fail_test 'ia orquestrar called PRoot from inside the Linux guest'
printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
bash "$project_root/bin/ia" orquestrar historico
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[1]}" ubuntu 'uses the adopted Ubuntu for the orchestrator'
assert_equal "${actual_args[2]}" --work-dir 'keeps the default root user of the adopted Ubuntu for the orchestrator'
assert_equal "${actual_args[9]}" historico 'passes the orchestrator subcommand in the adopted Ubuntu'
rm "$launcher_state/linux.conf"
printf '%s\n' 'PASS Hermes and the orchestrator run inside the Linux guest only'

printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
export TERMUX_AI_TEST_WAKELOCK_LOG="$test_root/wakelock.log"
cat > "$test_root/bin/termux-wake-lock" <<'MOCK'
#!/usr/bin/env bash
printf 'lock\n' >> "$TERMUX_AI_TEST_WAKELOCK_LOG"
MOCK
cat > "$test_root/bin/termux-wake-unlock" <<'MOCK'
#!/usr/bin/env bash
printf 'unlock\n' >> "$TERMUX_AI_TEST_WAKELOCK_LOG"
MOCK
chmod +x "$test_root/bin/termux-wake-lock" "$test_root/bin/termux-wake-unlock"
: > "$TERMUX_AI_TEST_WAKELOCK_LOG"
bash "$project_root/bin/ia" web status embedding
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[2]}" --work-dir 'preserves the current directory for the WebUI'
assert_equal "${actual_args[4]}" --no-kill-on-exit 'keeps web services alive when the PRoot session ends'
assert_equal "${actual_args[6]}" /bin/bash 'runs the web service controller inside Linux'
assert_equal "${actual_args[9]}" status 'requests WebUI status'
assert_equal "${actual_args[10]}" embedding 'limits status to EmbeddingGemma'
assert_equal "$(< "$TERMUX_AI_TEST_STAGE_VERBOSE")" '-1' 'keeps PRoot startup quiet for WebUI'
test ! -s "$TERMUX_AI_TEST_WAKELOCK_LOG"
bash "$project_root/bin/ia" web status > /dev/null
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[10]}" todos 'reports every WebUI service by default'

mkdir -p "$test_root/web-tmp" "$test_root/open-log"
export TERMUX_AI_TEST_OPEN_LOG="$test_root/open-log/urls"
cat > "$test_root/bin/termux-open-url" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TERMUX_AI_TEST_OPEN_LOG"
MOCK
chmod +x "$test_root/bin/termux-open-url"
panel_link='http://127.0.0.1:7690/00112233445566778899aabbccddeeff/'
TMPDIR="$test_root/web-tmp" bash "$project_root/bin/ia" web > "$test_root/web-start.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[9]}" start 'starts the default WebUI services'
assert_equal "${actual_args[10]}" padrao 'starts the panel by default'
grep -Fxq "Painel: $panel_link" "$test_root/web-start.log"
grep -Fq 'token de acesso' "$test_root/web-start.log"
if grep -Fq '7680' "$test_root/web-start.log" || grep -Fq '8085' "$test_root/web-start.log"; then
    fail_test 'the default start reported services that were not started'
fi
test ! -e "$TERMUX_AI_TEST_OPEN_LOG" || fail_test 'opened the browser without a terminal'
assert_equal "$(ls -A "$test_root/web-tmp")" '' 'removes the start log that holds the panel token link'
assert_equal "$(< "$TERMUX_AI_TEST_WAKELOCK_LOG")" 'lock' 'acquires termux-wake-lock when starting the panel'
TERMUX_AI_TEST_WEB_STARTED='painel embedding' bash "$project_root/bin/ia" web start todos > "$test_root/web-all.log"
grep -Fq 'EmbeddingGemma: http://127.0.0.1:8085' "$test_root/web-all.log"
grep -Fq 'Painel: ' "$test_root/web-all.log"
bash "$project_root/bin/ia" web start terminal > "$test_root/web-terminal.log"
grep -Fxq 'Terminal: http://127.0.0.1:7680' "$test_root/web-terminal.log"
if grep -Fq 'Painel:' "$test_root/web-terminal.log" || grep -Fq 'token' "$test_root/web-terminal.log"; then
    fail_test 'terminal start mentioned the panel link'
fi
assert_equal "$(grep -c '^lock$' "$TERMUX_AI_TEST_WAKELOCK_LOG")" 3 'refreshes the wake-lock on every start'
bash "$project_root/bin/ia" web stop embedding
bash "$project_root/bin/ia" web stop terminal
assert_equal "$(grep -c '^unlock$' "$TERMUX_AI_TEST_WAKELOCK_LOG" || true)" 0 'keeps wake-lock while the panel remains active'
bash "$project_root/bin/ia" web stop painel
assert_equal "$(tail -n 1 "$TERMUX_AI_TEST_WAKELOCK_LOG")" unlock 'releases wake-lock when the last WebUI service stops'
if compgen -G "$launcher_state/web/active.*" > /dev/null; then
    fail_test 'left an active marker after every service stopped'
fi

bash "$project_root/bin/ia" web abrir > "$test_root/web-open.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[9]}" start 'opens the panel by starting it'
assert_equal "${actual_args[10]}" painel 'opens only the panel'
assert_equal "$(< "$TERMUX_AI_TEST_OPEN_LOG")" "$panel_link" 'opens the panel link in the browser'
grep -Fq 'Abrindo o painel no navegador' "$test_root/web-open.log"
rm -f "$TERMUX_AI_TEST_OPEN_LOG"
rm "$test_root/bin/termux-open-url"
bash "$project_root/bin/ia" web abrir > "$test_root/web-open.log"
grep -Fq 'Abra o link do painel' "$test_root/web-open.log"
bash "$project_root/bin/ia" web stop

: > "$TERMUX_AI_TEST_WAKELOCK_LOG"
partial_status=0
TERMUX_AI_TEST_WEB_STARTED=painel TERMUX_AI_TEST_WEB_EXIT=7 TMPDIR="$test_root/web-tmp" bash "$project_root/bin/ia" web start todos > "$test_root/web-partial.log" 2>&1 || partial_status=$?
assert_equal "$partial_status" 7 'preserves the service controller exit status'
assert_equal "$(< "$TERMUX_AI_TEST_WAKELOCK_LOG")" 'lock' 'keeps wake-lock for services that started before a failure'
if grep -Fq 'Acesso restrito' "$test_root/web-partial.log"; then
    fail_test 'a failed start was reported as ready'
fi
assert_equal "$(ls -A "$test_root/web-tmp")" '' 'removes the start log after a failure'
bash "$project_root/bin/ia" web stop
assert_equal "$(tail -n 1 "$TERMUX_AI_TEST_WAKELOCK_LOG")" unlock 'releases wake-lock after stopping everything'

# "iniciado em" sai antes de o servidor abrir a porta: sem a linha do link o painel morreu e nao pode prender o wake-lock.
: > "$TERMUX_AI_TEST_WAKELOCK_LOG"
dead_status=0
TERMUX_AI_TEST_WEB_STARTED=painel-morto TERMUX_AI_TEST_WEB_EXIT=1 bash "$project_root/bin/ia" web start > "$test_root/web-dead.log" 2>&1 || dead_status=$?
assert_equal "$dead_status" 1 'reports a panel that died while starting'
test ! -s "$TERMUX_AI_TEST_WAKELOCK_LOG" || fail_test 'took the wake-lock for a panel that never answered'
if compgen -G "$launcher_state/web/active.*" > /dev/null; then
    fail_test 'marked a panel that never answered as active'
fi

# O PRoot real so volta quando o ultimo processo do Linux termina: o launcher nao espera por ele nem o encerra.
: > "$TERMUX_AI_TEST_WAKELOCK_LOG"
hang_status=0
TERMUX_AI_TEST_WEB_HANG=60 TMPDIR="$test_root/web-tmp" timeout 30 bash "$project_root/bin/ia" web start > "$test_root/web-hang.log" 2>&1 || hang_status=$?
assert_equal "$hang_status" 0 'returns while PRoot keeps the web services alive'
kill -0 "$(< "$TERMUX_AI_TEST_HANG_PID")" 2> /dev/null || fail_test 'ended the PRoot session that keeps the web services alive'
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[11]}" --marcador 'asks the controller to report when it ends'
grep -Fxq "Painel: $panel_link" "$test_root/web-hang.log" || fail_test 'lost the panel link while PRoot kept running'
if grep -Fq -e __WEBUI_FIM__ -e no-kill-on-exit "$test_root/web-hang.log"; then
    fail_test 'showed the internal end marker or the PRoot warning'
fi
assert_equal "$(< "$TERMUX_AI_TEST_WAKELOCK_LOG")" lock 'holds the wake-lock once the panel is up'
assert_equal "$(ls -A "$test_root/web-tmp")" '' 'removes the start logs while PRoot is still running'
stop_hung_proot
hang_status=0
TERMUX_AI_TEST_WEB_HANG=60 TERMUX_AI_TEST_WEB_STARTED=painel TERMUX_AI_TEST_WEB_EXIT=7 timeout 30 bash "$project_root/bin/ia" web start todos > "$test_root/web-hang.log" 2>&1 || hang_status=$?
assert_equal "$hang_status" 7 'reports the status that the controller wrote in its marker'
if grep -Fq 'Acesso restrito' "$test_root/web-hang.log"; then
    fail_test 'a failed start was reported as ready while PRoot kept running'
fi
stop_hung_proot
hang_status=0
TERMUX_AI_TEST_WEB_HANG=60 TERMUX_AI_TEST_WEB_NO_MARKER=1 TERMUX_AI_WEB_START_TIMEOUT=2 timeout 30 bash "$project_root/bin/ia" web start > "$test_root/web-hang.log" 2>&1 || hang_status=$?
assert_equal "$hang_status" 1 'gives up on a controller that never reports its end'
grep -Fq 'nao terminou de iniciar em 2 s' "$test_root/web-hang.log" || fail_test 'did not explain the start timeout'
stop_hung_proot
bash "$project_root/bin/ia" web stop
if compgen -G "$launcher_state/web/active.*" > /dev/null; then
    fail_test 'left an active marker after stopping the services that PRoot kept alive'
fi

expect_failure 'WebUI ran inside the Linux guest' env TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" web status
grep -q 'Use ia web no Termux' "$test_root/expected-failure.log"
for invalid_web in 'start network' 'start padrao' 'abrir terminal' 'bogus' 'start painel extra'; do
    expect_failure "invalid WebUI arguments were accepted: $invalid_web" bash "$project_root/bin/ia" web $invalid_web
    grep -q 'Uso: ia web' "$test_root/expected-failure.log"
done
rm "$launcher_state/linux.conf" "$test_root/bin/termux-wake-lock" "$test_root/bin/termux-wake-unlock"
printf '%s\n' 'PASS local WebUI dispatch, panel link, service management, wake-lock and loopback links'

printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
: > "$TERMUX_AI_TEST_CALLS"
bash "$project_root/bin/ia" embeddinggemma install > "$test_root/embedding-install.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]}" 'login ubuntu -- /bin/bash -se -- embeddinggemma-install' 'installs optional dependencies as the Linux user'
grep -Fq 'login ubuntu -- /bin/bash -se -- embeddinggemma-system' "$TERMUX_AI_TEST_CALLS"
grep -Fq 'login ubuntu -- /bin/bash -se -- embeddinggemma-install' "$TERMUX_AI_TEST_CALLS"
grep -q 'dependencias opcionais' "$test_root/embedding-install.log"
expect_failure 'EmbeddingGemma installation ran inside Linux' env TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" embeddinggemma install
grep -q 'fora do Linux' "$test_root/expected-failure.log"
expect_failure 'EmbeddingGemma installation accepted extra arguments' bash "$project_root/bin/ia" embeddinggemma install extra
grep -q 'Uso: ia embeddinggemma install' "$test_root/expected-failure.log"
rm "$launcher_state/linux.conf"
printf '%s\n' 'PASS optional EmbeddingGemma install stages and argument guards'

assets_home="$test_root/assets-home"
mkdir -p "$assets_home"
HOME="$assets_home" bash "$setup_script" install-assets "$project_root"
cmp "$assets_home/.local/share/termux-ai/web/menu.sh" "$project_root/scripts/web-menu.sh"
cmp "$assets_home/.local/share/termux-ai/tools/embeddinggemma_cli.py" "$project_root/scripts/embeddinggemma_cli.py"
cmp "$assets_home/.local/share/termux-ai/tools/embeddinggemma_web.py" "$project_root/scripts/embeddinggemma_web.py"
cmp "$assets_home/.local/bin/embeddinggemma" "$project_root/scripts/embeddinggemma-launcher.sh"
assert_equal "$(readlink "$assets_home/.local/bin/embedding")" embeddinggemma 'installs the guest compatibility link'
for hub_file in util.mjs agents.mjs orchestrator.mjs sessions.mjs server.mjs cli.mjs index.html attach.sh tmux.conf; do
    cmp "$assets_home/.local/share/termux-ai/hub/$hub_file" "$project_root/scripts/hub/$hub_file"
done
printf '%s\n' 'PASS Linux guest assets and optional command installation'

# Painel real: Node e curl de verdade (fora do mock do teste) e um ttyd de mentira que so guarda os argumentos.
real_path="${PATH#"$test_root/bin:"}"
panel_home="$test_root/panel-home"
panel_state="$panel_home/.local/share/termux-ai"
panel_work="$test_root/panel-work"
mkdir -p "$panel_home" "$panel_work"
HOME="$panel_home" bash "$setup_script" install-assets "$project_root"
export TERMUX_AI_TEST_TTYD_ARGS="$test_root/ttyd-args"
cat > "$panel_home/.local/bin/ttyd" <<'MOCK'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf '%s\n' "$*" > "$TERMUX_AI_TEST_TTYD_ARGS"
while :; do
    sleep 1 &
    wait $!
done
MOCK
chmod 755 "$panel_home/.local/bin/ttyd"
free_port() {
    env PATH="$real_path" node -e 'const server = require("node:net").createServer().listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });'
}
panel_port="$(free_port)"
panel_ttyd_port="$(free_port)"
while [[ $panel_ttyd_port == "$panel_port" ]]; do
    panel_ttyd_port="$(free_port)"
done
run_panel_webui() {
    (cd "$panel_work" && env HOME="$panel_home" PATH="$real_path" TERMUX_AI_PANEL_PORT="$panel_port" \
        TERMUX_AI_PANEL_TTYD_PORT="$panel_ttyd_port" bash "$panel_state/webui.sh" "$@")
}
panel_curl() {
    env PATH="$real_path" curl --silent --max-time 5 "$@"
}
panel_status_code() {
    panel_curl --output /dev/null --write-out '%{http_code}' "$1" || true
}

assert_equal "$(run_panel_webui status | tr '\n' ' ')" 'painel parado terminal parado embedding parado ' 'reports every WebUI service as stopped'
if ! panel_out="$(run_panel_webui start painel 2>&1)"; then
    printf '%s\n' "$panel_out" >&2
    fail_test 'the panel did not start'
fi
panel_token="$(< "$panel_state/web/token")"
[[ $panel_token =~ ^[0-9a-f]{32}$ ]] || fail_test 'the panel token is not 32 hexadecimal characters'
panel_url="http://127.0.0.1:$panel_port/$panel_token/"
grep -Fxq "Painel: $panel_url" <<< "$panel_out" || fail_test "the panel link is missing: $panel_out"
grep -Fq "painel-ttyd iniciado em 127.0.0.1:$panel_ttyd_port" <<< "$panel_out"
grep -Fq "painel iniciado em 127.0.0.1:$panel_port" <<< "$panel_out"
assert_equal "$(stat -c %a "$panel_state/web/token")" 600 'keeps the panel token private'
assert_equal "$(stat -c %a "$panel_state/web")" 700 'keeps the web state folder private'
grep -Fq -- "-i 127.0.0.1 -p $panel_ttyd_port -W -a -b /$panel_token/t -m 0 -O " "$TERMUX_AI_TEST_TTYD_ARGS" \
    || fail_test "the terminal bridge is not bound to loopback behind the token: $(< "$TERMUX_AI_TEST_TTYD_ARGS")"
grep -Fq -- " bash $panel_state/hub/attach.sh" "$TERMUX_AI_TEST_TTYD_ARGS" || fail_test 'the terminal bridge does not attach to tmux sessions'
assert_equal "$(panel_status_code "$panel_url")" 200 'serves the panel page behind the token'
assert_equal "$(panel_status_code "http://127.0.0.1:$panel_port/${panel_token}x/api/state")" 404 'hides the panel behind a wrong token'
assert_equal "$(panel_status_code "http://127.0.0.1:$panel_port/")" 404 'hides the panel without a token'
panel_agents="$(panel_curl "${panel_url}api/state" | env PATH="$real_path" node -e 'let text = ""; process.stdin.on("data", (chunk) => { text += chunk; }).on("end", () => { console.log(JSON.parse(text).agents.map((agent) => agent.id).join(",")); });')"
assert_equal "$panel_agents" 'copilot,claude,codex,agy,opencode,hermes,shell' 'offers every agent, Hermes included'

panel_again="$(run_panel_webui start painel)"
grep -Fq 'painel ja esta ativo' <<< "$panel_again"
grep -Fxq "Painel: $panel_url" <<< "$panel_again" || fail_test 'a second start changed the panel link'
grep -Fq "painel ativo: $panel_url" <<< "$(run_panel_webui status painel)" || fail_test 'the status does not show the panel link'
panel_overview="$(run_panel_webui status)"
grep -Fq 'painel ativo (PID' <<< "$panel_overview" || fail_test "the overview does not report the active panel: $panel_overview"
if grep -Fq "$panel_token" <<< "$panel_overview"; then
    fail_test 'the status overview leaked the panel token'
fi
panel_stopped="$(run_panel_webui stop painel)"
grep -Fxq 'painel encerrado.' <<< "$panel_stopped"
grep -Fxq 'painel-ttyd encerrado.' <<< "$panel_stopped"
assert_equal "$(run_panel_webui status painel)" 'painel parado' 'reports the stopped panel'
assert_equal "$(panel_status_code "$panel_url")" 000 'stops answering after the panel stops'

env PATH="$real_path" node -e 'require("node:net").createServer().listen(Number(process.argv[1]), "127.0.0.1");' "$panel_port" &
port_blocker=$!
for _ in {1..40}; do
    if (exec 3<> "/dev/tcp/127.0.0.1/$panel_port") 2> /dev/null; then
        break
    fi
    sleep 0.25
done
expect_failure 'a busy panel port was ignored' run_panel_webui start painel
grep -Eq 'Falha ao iniciar painel|O painel encerrou ao iniciar' "$test_root/expected-failure.log"
[[ ! -e "$panel_state/web/painel-ttyd.pid" ]] || fail_test 'left the terminal bridge running after the panel failed to start'
assert_equal "$(run_panel_webui status painel)" 'painel parado' 'reports the panel that never started as stopped'
kill "$port_blocker"
wait "$port_blocker" 2> /dev/null || true
unset port_blocker
run_panel_webui stop todos > /dev/null

mv "$panel_state/hub/index.html" "$panel_state/hub/index.html.bak"
expect_failure 'the panel started without its page' run_panel_webui start painel
grep -Fq 'Componentes do painel ausentes' "$test_root/expected-failure.log"
mv "$panel_state/hub/index.html.bak" "$panel_state/hub/index.html"
expect_failure 'an unknown WebUI target was accepted' run_panel_webui start bogus
grep -Fq 'Alvo invalido para start: bogus' "$test_root/expected-failure.log"
expect_failure 'an unknown WebUI action was accepted' run_panel_webui frobnicate
grep -Fq 'Uso interno' "$test_root/expected-failure.log"

old_panel_token="$panel_token"
run_panel_webui start painel > /dev/null
rm "$panel_state/web/token"
expect_failure 'the running panel accepted a rotated token' run_panel_webui start painel
grep -Fq 'nao respondeu com o token atual' "$test_root/expected-failure.log"
run_panel_webui stop painel > /dev/null
panel_out="$(run_panel_webui start painel)"
panel_token="$(< "$panel_state/web/token")"
[[ $panel_token != "$old_panel_token" ]] || fail_test 'the panel token was not rotated'
grep -Fxq "Painel: http://127.0.0.1:$panel_port/$panel_token/" <<< "$panel_out" || fail_test 'the rotated panel link is missing'
run_panel_webui stop todos > /dev/null
if compgen -G "$panel_state/web/*.pid" > /dev/null; then
    fail_test 'left a service marker after stopping everything'
fi
printf '%s\n' 'PASS real panel service: private token, loopback terminal bridge, restarts, port conflicts and token rotation'

# Com --marcador o controlador sempre termina com "__WEBUI_FIM__ <status>": o launcher le o fim do script por essa linha.
assert_equal "$(run_panel_webui status painel | tail -n 1)" 'painel parado' 'keeps the end marker off unless it is requested'
assert_equal "$(run_panel_webui status painel --marcador | tail -n 1)" '__WEBUI_FIM__ 0' 'reports the end of a successful run'
marker_status=0
marker_out="$(run_panel_webui start bogus --marcador 2>&1)" || marker_status=$?
assert_equal "$marker_status" 1 'keeps the exit status when the end marker is requested'
assert_equal "$(tail -n 1 <<< "$marker_out")" '__WEBUI_FIM__ 1' 'reports the end of a failed run'
grep -Fq 'Alvo invalido para start: bogus' <<< "$marker_out" || fail_test 'lost the failure message when the end marker is requested'

# Ponta a ponta: o launcher inicia o webui.sh de verdade e o PRoot de mentira segue vivo, como o real, com o painel ativo.
printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
cp "$project_root/scripts/webui.sh" "$launcher_state/webui.sh"
cat > "$test_root/web-real.sh" <<'REAL'
#!/usr/bin/env bash
cd "$TERMUX_AI_TEST_PANEL_WORK" || exit 1
exec env HOME="$TERMUX_AI_TEST_PANEL_HOME" PATH="$TERMUX_AI_TEST_REAL_PATH" bash "$TERMUX_AI_TEST_STAGE_INPUT" "$@"
REAL
chmod +x "$test_root/web-real.sh"
e2e_status=0
TERMUX_AI_TEST_WEB_REAL="$test_root/web-real.sh" TERMUX_AI_TEST_PANEL_WORK="$panel_work" TERMUX_AI_TEST_PANEL_HOME="$panel_home" \
    TERMUX_AI_TEST_REAL_PATH="$real_path" TERMUX_AI_PANEL_PORT="$panel_port" TERMUX_AI_PANEL_TTYD_PORT="$panel_ttyd_port" \
    timeout 90 bash "$project_root/bin/ia" web start painel > "$test_root/web-e2e.log" 2>&1 || e2e_status=$?
assert_equal "$e2e_status" 0 'starts the real controller while PRoot keeps running'
kill -0 "$(< "$TERMUX_AI_TEST_HANG_PID")" 2> /dev/null || fail_test 'the PRoot session ended while the panel was supposed to be active'
panel_token="$(< "$panel_state/web/token")"
grep -Fxq "Painel: http://127.0.0.1:$panel_port/$panel_token/" "$test_root/web-e2e.log" || fail_test "the launcher lost the real panel link: $(< "$test_root/web-e2e.log")"
if grep -Fq -e __WEBUI_FIM__ -e no-kill-on-exit "$test_root/web-e2e.log"; then
    fail_test 'the launcher showed the end marker or the PRoot warning for the real controller'
fi
assert_equal "$(panel_status_code "http://127.0.0.1:$panel_port/$panel_token/")" 200 'keeps answering after the launcher returned'
bash "$project_root/bin/ia" web stop > /dev/null
run_panel_webui stop todos > /dev/null
stop_hung_proot
: > "$launcher_state/webui.sh"
rm "$launcher_state/linux.conf" "$test_root/web-real.sh"
printf '%s\n' 'PASS WebUI start returns while PRoot keeps the services alive: end marker, timeout and real controller'

for tool_name in claude antigravity agy opencode hermes; do
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
grep -q 'ia diagnostico' "$test_root/help.log"
grep -q 'ia orquestrar' "$test_root/help.log"
grep -q 'ia web' "$test_root/help.log"
grep -q 'Hermes Agent: opcional' "$test_root/help.log"
grep -q 'Pedir aprovacao' "$test_root/help.log"
if bash "$project_root/bin/ia" unknown > /dev/null 2>&1; then
    printf '%s\n' 'FAIL unknown command was accepted' >&2
    exit 1
fi
printf '%s\n' 'PASS help and invalid commands'

actual_status=0
TERMUX_AI_TEST_EXIT=17 bash "$project_root/bin/ia" copilot || actual_status=$?
assert_equal "$actual_status" 17 'preserves agent exit status'
printf '%s\n' 'PASS exit status'

expect_codex_launch() {
    local expected="$1" notice="$2"
    shift 2
    rm -f "$TERMUX_AI_TEST_ARGS"
    "$@" 2> "$test_root/codex-notice.log"
    mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
    assert_equal "$(IFS='|'; printf '%s' "${actual_args[*]:11}")" "$expected" "Codex arguments for: ${*:2}"
    case "$notice" in
        ask) grep -q 'Modo Pedir aprovacao' "$test_root/codex-notice.log" || fail_test "missing approval notice: ${*:2}" ;;
        exec) grep -q 'falham em exec e review' "$test_root/codex-notice.log" || fail_test "missing exec notice: ${*:2}" ;;
        none) test ! -s "$test_root/codex-notice.log" || fail_test "unexpected Codex notice: ${*:2}" ;;
    esac
}

expect_codex_unchanged() {
    local notice="$1"
    shift
    expect_codex_launch "$(IFS='|'; printf 'codex|%s' "$*")" "$notice" bash "$project_root/bin/ia" codex "$@"
}

codex_policy='-s|workspace-write|-a|on-request'
expect_codex_launch "codex|$codex_policy" ask bash "$project_root/bin/ia" codex
expect_codex_launch "codex|$codex_policy" ask bash "$test_root/bin/codex"
expect_codex_launch "codex|$codex_policy|fix the tests" ask bash "$project_root/bin/ia" codex 'fix the tests'
expect_codex_launch "codex|-m|gpt-5|resume|$codex_policy|--last" ask bash "$project_root/bin/ia" codex -m gpt-5 resume --last
expect_codex_launch "codex|fork|$codex_policy|session-id" ask bash "$project_root/bin/ia" codex fork session-id
expect_codex_launch "codex|$codex_policy|-c|model=\"o3\"|explain" ask bash "$project_root/bin/ia" codex -c 'model="o3"' explain
expect_codex_launch "codex|$codex_policy|-i|resume|describe" ask bash "$project_root/bin/ia" codex -i resume describe
expect_codex_launch "codex|$codex_policy|--|-s literal" ask bash "$project_root/bin/ia" codex -- '-s literal'
expect_codex_unchanged none -s read-only
expect_codex_unchanged none --sandbox=danger-full-access 'fix the tests'
expect_codex_unchanged none -a never
expect_codex_unchanged none --ask-for-approval=untrusted
expect_codex_unchanged none -p work
expect_codex_unchanged none --profile=work
expect_codex_unchanged none --approve-for-me
expect_codex_unchanged none --dangerously-bypass-approvals-and-sandbox
expect_codex_unchanged none --full-auto
expect_codex_unchanged none -c approval_policy=never
expect_codex_unchanged none '--config=sandbox_mode="read-only"'
expect_codex_unchanged none -c 'permissions.network = true'
expect_codex_unchanged none -cprofile=work
expect_codex_unchanged none resume --last -s read-only
expect_codex_unchanged none login status
expect_codex_unchanged none --version
expect_codex_unchanged none resume --help
expect_codex_unchanged none mcp list
expect_codex_unchanged none sandbox -- /bin/true
expect_codex_unchanged exec exec 'run the tests'
expect_codex_unchanged exec e 'run the tests'
expect_codex_unchanged exec review
printf '%s\n' 'PASS Codex opens in approval mode unless the user picks a policy'

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

printf '%s\n' \
    $'@version\tcopilot\t1.0.91\t1.0.91\tcurrent' \
    $'@version\thermes\t-\t0.22.1\tmissing' \
    > "$TERMUX_AI_TEST_VERSIONS"
bash "$project_root/bin/ia" versoes > "$test_root/versions-hermes.log"
grep -Eq '^Hermes Agent +- +0\.22\.1 +nao instalado \(opcional\)$' "$test_root/versions-hermes.log"
grep -Fq 'Hermes Agent (opcional, cerca de 2 GB): ia atualizar hermes' "$test_root/versions-hermes.log"
if grep -Fq 'Para atualizar: ia atualizar' "$test_root/versions-hermes.log"; then
    fail_test 'a missing optional Hermes was offered as a general update'
fi
: > "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar --yes > "$test_root/update-hermes-none.log"
grep -q 'Nenhuma atualizacao disponivel' "$test_root/update-hermes-none.log"
test ! -s "$TERMUX_AI_TEST_UPDATES"
expect_failure 'Hermes installation ran without confirmation' bash "$project_root/bin/ia" atualizar hermes < /dev/null
grep -Fq 'cerca de 2 GB' "$test_root/expected-failure.log"
test ! -s "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar --yes hermes > "$test_root/update-hermes.log"
assert_equal "$(< "$TERMUX_AI_TEST_UPDATES")" 'hermes 0.22.1' 'installs Hermes only when it is requested'
grep -Fq 'Hermes Agent: o download tem cerca de 2 GB' "$test_root/update-hermes.log"
printf '%s\n' $'@version\thermes\t0.22.0\t0.22.1\toutdated' > "$TERMUX_AI_TEST_VERSIONS"
: > "$TERMUX_AI_TEST_UPDATES"
bash "$project_root/bin/ia" atualizar --yes > "$test_root/update-hermes-installed.log"
assert_equal "$(< "$TERMUX_AI_TEST_UPDATES")" 'hermes 0.22.1' 'updates an installed Hermes with the other agents'
if grep -Fq 'cerca de 2 GB' "$test_root/update-hermes-installed.log"; then
    fail_test 'warned about a large download for an installed Hermes'
fi
grep -Fq 'Para atualizar: ia atualizar' <(bash "$project_root/bin/ia" versoes)
printf '%s\n' 'PASS Hermes stays optional and is installed or updated only on request'

termux_diag_bin="$test_root/termux-diag-bin"
mkdir -p "$termux_diag_bin"
cat > "$termux_diag_bin/getprop" <<'MOCK'
#!/usr/bin/env bash
[[ $* == ro.build.version.release ]] || exit 2
printf '16\n'
MOCK
cat > "$termux_diag_bin/uname" <<'MOCK'
#!/usr/bin/env bash
[[ $* == -m ]] || exit 2
printf 'aarch64\n'
MOCK
cat > "$termux_diag_bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
[[ $* == '-W -f=${Version} proot-distro' ]] || exit 2
printf '5.3.0'
MOCK
cat > "$termux_diag_bin/df" <<'MOCK'
#!/usr/bin/env bash
[[ $# -eq 2 && $1 == -Pk && $2 == "$HOME" ]] || exit 2
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/block/dm-50 100000000 27435984 %s 28%% /data\n' "${TERMUX_AI_TEST_FREE_KIB:-72564016}"
MOCK
chmod +x "$termux_diag_bin/"*
run_termux_diagnostics() {
    env PATH="$termux_diag_bin:$PATH" TERMUX_VERSION=0.118.3 "$@" bash "$project_root/bin/ia" diagnostico
}

expect_lines() {
    local log_file="$1" pattern
    shift
    for pattern in "$@"; do
        grep -Eq -- "$pattern" "$log_file" || fail_test "missing line /$pattern/ in $log_file"
    done
}

printf '%s\n' \
    'proot warning: unrelated output' \
    $'@diag\tcheck\tdistro\tok\tUbuntu 26.04.1 LTS' \
    $'@diag\tcheck\tnode\tok\t22.23.3' \
    $'@diag\tcheck\tgit\tok\t2.53.0' \
    $'@diag\tcheck\tworkdir\tok\t-' \
    $'@diag\tagent\tcopilot\tyes\t1.0.91' \
    $'@diag\tagent\tclaude\tyes\t2.1.289' \
    $'@diag\tagent\tcodex\tyes\t0.160.0' \
    $'@diag\tagent\tagy\tyes\t1.2.16' \
    $'@diag\tagent\topencode\tno\t1.18.34' \
    $'@diag\tagent\thermes\tyes\t0.22.1' \
    $'@diag\tcheck\tnetwork\tok\t-' \
    $'@diag\tisolation\tcodex\tunavailable\t-' \
    $'@diag\tlocal\tembeddinggemma\tready\t2.0.0' \
    $'@diag\tweb\tpainel\tactive\t127.0.0.1:7690' \
    $'@diag\tweb\tterminal\tactive\t127.0.0.1:7680' \
    $'@diag\tweb\tembedding\tstopped\t-' \
    $'@diag\tagent\tgemini\tyes\t1.0.0' \
    $'@diag\tagent\tclaude\tno\t2.1;id' \
    $'@diag\tagent\thermes\tno\t0.22.1;id' \
    $'@diag\tweb\tpainel\tactive\t0.0.0.0:7690' \
    $'@diag\tweb\tpainel\tactive\t127.0.0.1:7690/token' \
    $'@diag\tcheck\tdistro\tok\tUbuntu;reboot' \
    $'@diag\tcheck\tnode\tok\t-' \
    $'@diag\tisolation\tclaude\tactive\t-' \
    $'@diag\tagent\tcodex\tyes\t0.160.0\textra' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics > "$test_root/diag.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]:0:9}" 'login termux-ai --user node -- /bin/bash -se -- diagnose' 'diagnoses inside the managed Linux'
assert_equal "${actual_args[9]}" "$PWD" 'sends the current folder to the diagnostic'
assert_equal "${#actual_args[@]}" 10 'sends only the folder to the diagnostic'
cmp "$TERMUX_AI_TEST_STAGE_INPUT" "$launcher_state/setup-linux.sh"
expect_lines "$test_root/diag.log" \
    '^  Android +16 \(aarch64\)$' \
    '^  Termux +0\.118\.3$' \
    '^  PRoot-Distro +5\.3\.0$' \
    '^  Espaco livre +69\.2 GiB$' \
    '^  Linux +termux-ai, usuario node$' \
    '^  Sistema +Ubuntu 26\.04\.1 LTS$' \
    '^  Node\.js +22\.23\.3$' \
    '^  Git +2\.53\.0$' \
    '^  Internet +ok$' \
    '^  Pasta atual +aceita gravacao$' \
    '^  GitHub Copilot +1\.0\.91 +login ok$' \
    '^  Claude Code +2\.1\.289 +login ok$' \
    '^  Codex +0\.160\.0 +login ok$' \
    '^  Antigravity CLI +1\.2\.16 +login ok$' \
    '^  OpenCode +1\.18\.34 +sem login$' \
    '^  Hermes Agent +0\.22\.1 +login ok$' \
    '^  EmbeddingGemma 2 +2\.0\.0 +pronto \(modelo em cache\)$' \
    '^  Painel web +ativo \(link com token: ia web status painel\)$' \
    '^  WebUI Terminal +ativo \(http://127\.0\.0\.1:7680\)$' \
    '^  WebUI Embedding +parado$' \
    '^  PRoot nao isola os agentes' \
    '^  Codex: o sandbox nao funciona aqui; ia codex abre no modo Pedir aprovacao\.$' \
    '^  - OpenCode: entre com ia opencode auth login; sem chave de API, use GitHub Copilot ou ChatGPT Plus/Pro\.$'
assert_equal "$(grep -c '^  - ' "$test_root/diag.log")" 1 'suggests only the missing login'
assert_equal "$(grep -Ec '^  (GitHub Copilot|Claude Code|Codex|Antigravity CLI|OpenCode) ' "$test_root/diag.log")" 5 'shows one row per agent'
if grep -Eq 'gemini|unrelated|;id|reboot|extra|0\.0\.0\.0|7690/' "$test_root/diag.log"; then
    fail_test 'unexpected Linux output reached the diagnostic'
fi
printf '%s\n' 'PASS diagnostic shows Termux, Linux, agents and protections'

printf '%s\n' \
    $'@diag\tcheck\tdistro\tok\t-' \
    $'@diag\tcheck\tnode\told\t20.11.1' \
    $'@diag\tcheck\tgit\tmissing\t-' \
    $'@diag\tcheck\tworkdir\tfail\t-' \
    $'@diag\tagent\tcopilot\tno\t1.0.91' \
    $'@diag\tagent\tclaude\tunknown\t2.1.289' \
    $'@diag\tagent\tcodex\tno\t0.160.0' \
    $'@diag\tagent\tagy\tmissing\t-' \
    $'@diag\tagent\topencode\tbroken\t-' \
    $'@diag\tagent\thermes\tmissing\t-' \
    $'@diag\tcheck\tnetwork\tfail\t-' \
    $'@diag\tisolation\tcodex\tineffective\t-' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics TERMUX_AI_TEST_FREE_KIB=1572864 > "$test_root/diag-problems.log"
expect_lines "$test_root/diag-problems.log" \
    '^  Espaco livre +1\.5 GiB$' \
    '^  Sistema +\?$' \
    '^  Node\.js +20\.11\.1 \(requer 22 ou superior\)$' \
    '^  Git +nao encontrado$' \
    '^  Internet +sem acesso$' \
    '^  Pasta atual +sem gravacao$' \
    '^  GitHub Copilot +1\.0\.91 +sem login$' \
    '^  Claude Code +2\.1\.289 +login nao verificado$' \
    '^  Codex +0\.160\.0 +sem login$' \
    '^  Antigravity CLI +- +nao instalado$' \
    '^  OpenCode +- +nao inicia$' \
    '^  Hermes Agent +- +opcional \(nao instalado\)$' \
    '^  Codex: o sandbox iniciou, mas nao bloqueou uma gravacao de teste\.$' \
    '^  - Pouco espaco livre' \
    '^  - Node\.js 22\+ e Git sao necessarios' \
    '^  - Sem internet no Linux' \
    '^  - A pasta atual nao aceita gravacao' \
    '^  - GitHub Copilot: entre com ia copilot login\.$' \
    '^  - Codex: entre com ia codex login\.$' \
    '^  - Antigravity CLI: instale com ia atualizar agy\.$' \
    '^  - OpenCode: reinstale com ia atualizar opencode\.$' \
    '^  - Codex: nao confie no sandbox'
assert_equal "$(grep -c '^  - ' "$test_root/diag-problems.log")" 9 'suggests one step per problem'
if grep -q 'ia claude auth login' "$test_root/diag-problems.log"; then
    fail_test 'unverified login was reported as missing'
fi
printf '%s\n' 'PASS diagnostic explains each problem with a next step'

printf '%s\n' \
    $'@diag\tcheck\tdistro\tok\tDebian GNU/Linux 12 (bookworm)' \
    $'@diag\tcheck\tnode\tok\t24.4.0' \
    $'@diag\tcheck\tgit\tok\t2.39.5' \
    $'@diag\tcheck\tworkdir\tskip\t-' \
    $'@diag\tagent\tcopilot\tyes\t1.0.91' \
    $'@diag\tagent\tclaude\tyes\t2.1.289' \
    $'@diag\tagent\tcodex\tyes\t0.160.0' \
    $'@diag\tagent\tagy\tyes\t1.2.16' \
    $'@diag\tagent\topencode\tyes\t1.18.34' \
    $'@diag\tcheck\tnetwork\tok\t-' \
    $'@diag\tisolation\tcodex\tactive\t-' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics > "$test_root/diag-ok.log"
expect_lines "$test_root/diag-ok.log" \
    '^  Sistema +Debian GNU/Linux 12 \(bookworm\)$' \
    '^  Pasta atual +nao verificada$' \
    '^  Codex: o sandbox bloqueou uma gravacao de teste\.$' \
    '^  Nenhuma acao necessaria\.$'
if grep -q 'Hermes' "$test_root/diag-ok.log"; then
    fail_test 'Hermes was listed without being reported by the Linux'
fi
printf '%s\n' \
    $'@diag\tagent\thermes\tno\t0.22.1' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics > "$test_root/diag-hermes-login.log"
expect_lines "$test_root/diag-hermes-login.log" \
    '^  Hermes Agent +0\.22\.1 +sem login$' \
    '^  - Hermes Agent: configure um provedor com ia hermes setup ou ia hermes model\.$'
printf '%s\n' \
    $'@diag\tagent\thermes\tbroken\t-' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics > "$test_root/diag-hermes-broken.log"
expect_lines "$test_root/diag-hermes-broken.log" \
    '^  Hermes Agent +- +nao inicia$' \
    '^  - Hermes Agent: reinstale com ia atualizar hermes\.$'
printf '%s\n' \
    $'@diag\tagent\tcodex\tmissing\t-' \
    $'@diag\tisolation\tcodex\tmissing\t-' \
    > "$TERMUX_AI_TEST_DIAG"
run_termux_diagnostics > "$test_root/diag-partial.log"
expect_lines "$test_root/diag-partial.log" \
    '^  Node\.js +nao verificado$' \
    '^  Internet +nao verificada$' \
    '^  Codex +- +nao instalado$' \
    '^  Claude Code +- +nao verificado$' \
    '^  - Codex: instale com ia atualizar codex\.$'
if grep -q '^  Codex:' "$test_root/diag-partial.log"; then
    fail_test 'sandbox status was shown without Codex'
fi
printf '%s\n' 'PASS diagnostic handles healthy and partial results'

printf 'name=ubuntu\nuser=root\n' > "$launcher_state/linux.conf"
run_termux_diagnostics > "$test_root/diag-ubuntu.log"
mapfile -d '' -t actual_args < "$TERMUX_AI_TEST_ARGS"
assert_equal "${actual_args[*]:0:7}" 'login ubuntu -- /bin/bash -se -- diagnose' 'diagnoses inside the adopted Ubuntu'
assert_equal "${actual_args[7]}" "$PWD" 'sends the folder to the adopted Ubuntu'
expect_lines "$test_root/diag-ubuntu.log" '^  Linux +ubuntu, usuario root$'
rm "$launcher_state/linux.conf"
expect_failure 'empty diagnostic was accepted' env TERMUX_AI_TEST_DIAG=/dev/null bash "$project_root/bin/ia" diagnostico
grep -q 'Nao foi possivel consultar o Linux' "$test_root/expected-failure.log"
rm -f "$TERMUX_AI_TEST_ARGS"
actual_status=0
bash "$project_root/bin/ia" diagnostico extra > /dev/null 2>&1 || actual_status=$?
assert_equal "$actual_status" 2 'rejects extra diagnostic arguments'
test ! -e "$TERMUX_AI_TEST_ARGS"
expect_failure 'diagnostic ran inside Linux' env TERMUX_AI_GUEST=1 bash "$project_root/bin/ia" diagnostico
grep -q 'fora do Linux' "$test_root/expected-failure.log"
test ! -e "$TERMUX_AI_TEST_ARGS"
grep -Fq '\n9. Diagnostico do ambiente\n10. Hermes Agent (opcional)\n11. Painel web (varios agentes)\n0. Sair' "$project_root/bin/ia"
grep -Fq '9) run_maintenance show_diagnostics || true; continue ;;' "$project_root/bin/ia"
grep -Fq '10) tool_name=hermes ;;' "$project_root/bin/ia"
grep -Fq '11) manage_web || true; continue ;;' "$project_root/bin/ia"
printf '%s\n' 'PASS diagnostic validates its environment and is in the menu'

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
grep -Fq 'Hermes Agent e opcional' "$test_root/preflight.log"

download_copy="$test_root/download-copy"
mkdir -p "$download_copy"
cp -a "$project_root/install.sh" "$project_root/bin" "$project_root/scripts" "$download_copy/"
bash "$download_copy/install.sh" --check > "$test_root/preflight.log"
expect_incomplete_download() {
    if bash "$download_copy/install.sh" --check > "$test_root/preflight.log" 2>&1; then
        fail_test "$1"
    fi
    grep -Fq -- "$2" "$test_root/preflight.log" || fail_test "missing preflight message: $2"
    test ! -e "$TERMUX_AI_TEST_INSTALL_LOG"
    test ! -e "$HOME/.local"
}
for hub_file in util.mjs agents.mjs orchestrator.mjs sessions.mjs server.mjs cli.mjs index.html attach.sh tmux.conf; do
    held_file="$test_root/held-hub-file"
    mv "$download_copy/scripts/hub/$hub_file" "$held_file"
    expect_incomplete_download "the installer accepted a download without scripts/hub/$hub_file" 'Baixe o repositorio completo'
    mv "$held_file" "$download_copy/scripts/hub/$hub_file"
    cp "$download_copy/scripts/hub/$hub_file" "$held_file"
    printf 'line\r\n' >> "$download_copy/scripts/hub/$hub_file"
    expect_incomplete_download "the installer accepted scripts/hub/$hub_file with CRLF line endings" "scripts/hub/$hub_file precisa de finais de linha LF"
    mv "$held_file" "$download_copy/scripts/hub/$hub_file"
done
bash "$download_copy/install.sh" --check > "$test_root/preflight.log"
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
printf 'foreign hermes\n' > "$PREFIX/bin/hermes"
bash "$project_root/install.sh" --yes > "$test_root/first-install.log"
state_dir="$HOME/.local/share/termux-ai"
printf 'export ORIGINAL_SETTING=kept\n' > "$test_root/bashrc.expected"
cmp "$state_dir/bashrc.before" "$test_root/bashrc.expected"
assert_equal "$(< "$state_dir/linux.conf")" $'name=termux-ai\nuser=node' 'records the managed Linux'
cmp "$state_dir/setup-linux.sh" "$setup_script"
cmp "$state_dir/webui.sh" "$project_root/scripts/webui.sh"
cmp "$state_dir/web/menu.sh" "$project_root/scripts/web-menu.sh"
cmp "$state_dir/tools/embeddinggemma_web.py" "$project_root/scripts/embeddinggemma_web.py"
cmp "$state_dir/tools/embeddinggemma_cli.py" "$project_root/scripts/embeddinggemma_cli.py"
grep -Fqx 'Codex sem sandbox no Android: ia codex abre no modo Pedir aprovacao.' "$test_root/first-install.log"
grep -Fq 'Use ia diagnostico para conferir logins e protecoes.' "$test_root/first-install.log"
grep -Fq 'ia atualizar hermes' "$test_root/first-install.log"
grep -Fq 'ia orquestrar' "$test_root/first-install.log"
assert_equal "$(< "$PREFIX/bin/hermes")" 'foreign hermes' 'keeps a hermes command that this installer does not own'
grep -Fq 'Ja existe um comando hermes' "$test_root/first-install.log"
rm "$PREFIX/bin/hermes"
grep -Fqx 'proot login termux-ai -- /bin/bash -se -- system' "$TERMUX_AI_TEST_INSTALL_LOG"
grep -Fqx 'proot login termux-ai --user node -- /bin/bash -se -- agents' "$TERMUX_AI_TEST_INSTALL_LOG"
grep -Fqx "proot login termux-ai --user node -- /bin/bash -se -- install-assets $project_root" "$TERMUX_AI_TEST_INSTALL_LOG"
bash "$project_root/install.sh" --yes > "$test_root/reinstall.log"
assert_equal "$(grep -c '^proot install ' "$TERMUX_AI_TEST_INSTALL_LOG")" 1 'does not reinstall the Linux image'
assert_equal "$(grep -c 'install-assets' "$TERMUX_AI_TEST_INSTALL_LOG")" 2 'refreshes guest assets on reinstall'
assert_equal "$(grep -c 'menu.bash' "$HOME/.bashrc")" 1 'does not duplicate the startup hook'
assert_equal "$(< "$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs/project")" 'keep this project' 'preserves other Linux data'
for tool_name in ia codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
    test -x "$PREFIX/bin/$tool_name"
    cmp "$PREFIX/bin/$tool_name" "$state_dir/bin/ia"
done
assert_equal "$(head -n 1 "$PREFIX/bin/ia")" "#!$PREFIX/bin/bash" 'uses the actual Termux prefix'
printf '%s\n' 'PASS mock installation, managed rerun and preserved configuration'

expect_failure 'adoption replaced the managed Linux' bash "$project_root/install.sh" --yes --adopt-ubuntu
grep -q 'usa o Linux termux-ai' "$test_root/expected-failure.log"
assert_equal "$(< "$state_dir/linux.conf")" $'name=termux-ai\nuser=node' 'keeps the managed Linux selected'
for tool_name in ia codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
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
export TERMUX_AI_TEST_CURL_ARGS="$test_root/curl-arguments.log"
export TERMUX_AI_TEST_NPM_LOG="$test_root/npm.log"
export TERMUX_AI_TEST_AGY_PAYLOAD="$test_root/antigravity.tar.gz"
export TERMUX_AI_TEST_HERMES_LOG="$test_root/hermes.log"
export TERMUX_AI_TEST_HERMES_STUB="$test_root/hermes-stub.sh"
export TERMUX_AI_TEST_HERMES_INSTALLER_SCRIPT="$test_root/hermes-installer.sh"
mkdir -p "$HOME" "$test_root/payload"
codex_pin="$(sed -n 's/^codex_version=//p' "$setup_script")"
copilot_pin="$(sed -n 's/^copilot_version=//p' "$setup_script")"
claude_pin="$(sed -n 's/^claude_version=//p' "$setup_script")"
opencode_pin="$(sed -n 's/^opencode_version=//p' "$setup_script")"
hermes_pin="$(sed -n 's/^hermes_version=//p' "$setup_script")"
for pinned_version in "$codex_pin" "$copilot_pin" "$claude_pin" "$opencode_pin" "$hermes_pin"; do
    [[ $pinned_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_test "invalid pinned version <$pinned_version>"
done

# Bloqueia agentes reais do ambiente de teste: nenhum deve ser consultado ou alterado.
for tool_name in codex copilot claude agy opencode antigravity hermes; do
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
printf '%s\n' "$*" >> "$TERMUX_AI_TEST_CURL_ARGS"
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
    https://registry.npmjs.org/) exit "${TERMUX_AI_TEST_NETWORK_FAILURE:-0}" ;;
    https://api.github.com/repos/NousResearch/hermes-agent/releases/latest)
        [[ -n ${TERMUX_AI_TEST_HERMES_RELEASE:-} && $TERMUX_AI_TEST_HERMES_RELEASE != fail ]] || exit 22
        printf '%s\n' "$TERMUX_AI_TEST_HERMES_RELEASE" > "$destination"
        ;;
    https://hermes-agent.nousresearch.com/install.sh)
        case "${TERMUX_AI_TEST_HERMES_INSTALLER:-ok}" in
            fail) exit 22 ;;
            empty) : > "$destination" ;;
            *) cp "$TERMUX_AI_TEST_HERMES_INSTALLER_SCRIPT" "$destination" ;;
        esac
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
assert_equal "$(wc -l < "$TERMUX_AI_TEST_CURL_ARGS" | tr -d ' ')" 3 'checks all three agent downloads'
while IFS= read -r curl_arguments; do
    [[ $curl_arguments == *'--connect-timeout 15'* && $curl_arguments == *'--max-time 300'* \
        && $curl_arguments == *'--retry 2'* && $curl_arguments == *'--retry-max-time 600'* ]] \
        || fail_test 'agent download lacks bounded timeouts and retries'
done < "$TERMUX_AI_TEST_CURL_ARGS"
printf '%s\n' 'PASS agent downloads have bounded timeouts and retries'
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
test ! -e "$HOME/.local/bin/hermes" || fail_test 'the optional Hermes was installed with the other agents'
if grep -qi 'hermes' "$TERMUX_AI_TEST_DOWNLOAD_LOG" "$test_root/guest-setup.log"; then
    fail_test 'the agents stage touched the optional Hermes'
fi
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
    opencode "$opencode_pin" "$opencode_pin-beta.1" current \
    hermes - "$hermes_pin" missing)"
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

cat > "$TERMUX_AI_TEST_HERMES_STUB" <<'MOCK'
#!/usr/bin/env bash
version_file="$HOME/.hermes-test-version"
case "${1:-}" in
    --version)
        [[ $(< "$version_file") != broken ]] || exit 3
        printf 'Hermes Agent v%s+1.g5575a08 (2026.9.24) \xc2\xb7 stable \xc2\xb7 local 5575a0859d62\n' "$(< "$version_file")"
        ;;
    update)
        printf '%s\n' "$*" >> "$TERMUX_AI_TEST_HERMES_LOG"
        [[ ${TERMUX_AI_TEST_HERMES_UPDATE_FAILURE:-0} == 0 ]] || exit 4
        printf '%s\n' "${TERMUX_AI_TEST_HERMES_UPDATE_VERSION:-0.22.1}" > "$version_file"
        ;;
    *) exit 2 ;;
esac
MOCK
cat > "$TERMUX_AI_TEST_HERMES_INSTALLER_SCRIPT" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'installer %s|%s|%s\n' "$*" "${TERMUX_VERSION-unset}" "${PREFIX-unset}" >> "$TERMUX_AI_TEST_HERMES_LOG"
[[ ${TERMUX_AI_TEST_HERMES_INSTALL_FAILURE:-0} == 0 ]] || exit 3
[[ ${TERMUX_AI_TEST_HERMES_INSTALL_NOOP:-0} == 0 ]] || exit 0
mkdir -p "$HOME/.local/bin"
install -m 755 "$TERMUX_AI_TEST_HERMES_STUB" "$HOME/.local/bin/hermes"
printf '%s\n' "${TERMUX_AI_TEST_HERMES_INSTALL_VERSION:-0.22.1}" > "$HOME/.hermes-test-version"
MOCK
chmod 755 "$TERMUX_AI_TEST_HERMES_STUB"

hermes_version_line() {
    bash "$setup_script" versions | awk -F'\t' '$2 == "hermes"'
}
hermes_release() {
    printf '{"tag_name":"%s","draft":%s,"prerelease":%s}' "$1" "${2:-false}" "${3:-false}"
}
assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE="$(hermes_release v0.23.4)" hermes_version_line)" \
    $'@version\thermes\t-\t0.23.4\tmissing' 'offers the latest stable Hermes release when it is missing'
for ignored_release in "$(hermes_release v2026.9.24)" "$(hermes_release v0.23.5 false true)" "$(hermes_release v0.23.5 true false)" \
    "$(hermes_release v1000.0.1)" 'not json' fail ''; do
    assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE="$ignored_release" hermes_version_line)" \
        $'@version\thermes\t-\t'"$hermes_pin"$'\tmissing' "falls back to the validated Hermes version for: $ignored_release"
done
install -m 755 "$TERMUX_AI_TEST_HERMES_STUB" "$HOME/.local/bin/hermes"
printf '0.22.0\n' > "$HOME/.hermes-test-version"
assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE="$(hermes_release v0.22.1)" hermes_version_line)" \
    $'@version\thermes\t0.22.0\t0.22.1\toutdated' 'reports an outdated Hermes without the build metadata'
assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE="$(hermes_release v0.22.0)" hermes_version_line)" \
    $'@version\thermes\t0.22.0\t0.22.0\tcurrent' 'reports a current Hermes'
assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE="$(hermes_release v0.21.9)" hermes_version_line)" \
    $'@version\thermes\t0.22.0\t0.21.9\tcurrent' 'keeps a Hermes that is newer than the latest release'
assert_equal "$(TERMUX_AI_TEST_HERMES_RELEASE=fail hermes_version_line)" \
    $'@version\thermes\t0.22.0\t-\tunknown' 'reports an unknown Hermes status without the release lookup'

update_hermes() {
    if ! "$@" > "$test_root/guest-update-hermes.log" 2> "$test_root/guest-update-hermes.err"; then
        cat "$test_root/guest-update-hermes.log" "$test_root/guest-update-hermes.err" >&2
        fail_test "Hermes update failed: $*"
    fi
}

rm "$HOME/.local/bin/hermes" "$HOME/.hermes-test-version"
: > "$TERMUX_AI_TEST_HERMES_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
update_hermes env TERMUX_VERSION=0.118.3 bash "$setup_script" update hermes 0.22.1
grep -Fqx 'Atualizado: Hermes Agent 0.22.1' "$test_root/guest-update-hermes.log"
assert_equal "$(< "$TERMUX_AI_TEST_HERMES_LOG")" 'installer --non-interactive --skip-browser --skip-computer-use|unset|unset' \
    'runs the official Hermes installer outside the Termux environment'
assert_equal "$(< "$TERMUX_AI_TEST_DOWNLOAD_LOG")" 'https://hermes-agent.nousresearch.com/install.sh' 'downloads only the official Hermes installer'
printf '0.22.0\n' > "$HOME/.hermes-test-version"
: > "$TERMUX_AI_TEST_HERMES_LOG"
: > "$TERMUX_AI_TEST_DOWNLOAD_LOG"
update_hermes bash "$setup_script" update hermes 0.22.1
grep -Fqx 'Atualizado: Hermes Agent 0.22.1' "$test_root/guest-update-hermes.log"
assert_equal "$(< "$TERMUX_AI_TEST_HERMES_LOG")" 'update --yes --no-gateway-restart' 'updates an installed Hermes with its own command'
test ! -s "$TERMUX_AI_TEST_DOWNLOAD_LOG"
printf '0.21.0\n' > "$HOME/.hermes-test-version"
update_hermes env TERMUX_AI_TEST_HERMES_UPDATE_VERSION=0.21.5 bash "$setup_script" update hermes 0.22.1
grep -Fqx 'Atualizado: Hermes Agent 0.21.5' "$test_root/guest-update-hermes.log"
grep -Fq 'Aviso: o Hermes Agent informou 0.21.5; a ultima release consultada e 0.22.1.' "$test_root/guest-update-hermes.err"
printf 'broken\n' > "$HOME/.hermes-test-version"
: > "$TERMUX_AI_TEST_HERMES_LOG"
update_hermes bash "$setup_script" update hermes 0.22.1
grep -Fqx 'Atualizado: Hermes Agent 0.22.1' "$test_root/guest-update-hermes.log"
assert_equal "$(< "$TERMUX_AI_TEST_HERMES_LOG")" 'installer --non-interactive --skip-browser --skip-computer-use|unset|unset' \
    'repairs a Hermes that does not start with the official installer'
expect_failure 'a failed Hermes update was reported as done' env TERMUX_AI_TEST_HERMES_UPDATE_FAILURE=1 bash "$setup_script" update hermes 0.22.1
if grep -q 'Atualizado' "$test_root/expected-failure.log"; then
    fail_test 'a failed Hermes update printed a success line'
fi
rm "$HOME/.local/bin/hermes" "$HOME/.hermes-test-version"
for failure_flag in TERMUX_AI_TEST_HERMES_INSTALLER=fail TERMUX_AI_TEST_HERMES_INSTALLER=empty \
    TERMUX_AI_TEST_HERMES_INSTALL_FAILURE=1 TERMUX_AI_TEST_HERMES_INSTALL_NOOP=1; do
    expect_failure "Hermes installation failure ignored: $failure_flag" env "$failure_flag" bash "$setup_script" update hermes 0.22.1
    test ! -e "$HOME/.local/bin/hermes"
done
grep -Fq 'nao respondeu ao teste de versao' "$test_root/expected-failure.log"
expect_failure 'an empty Hermes installer was run' env TERMUX_AI_TEST_HERMES_INSTALLER=empty bash "$setup_script" update hermes 0.22.1
grep -Fq 'veio vazio' "$test_root/expected-failure.log"
printf '%s\n' 'PASS Hermes is optional, installed or updated only on request and verified afterwards'

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
for invalid_stage in update 'update codex' 'update gemini 1.0.0' 'update codex 1.0' 'update codex 1.0.0;id' 'update codex 1.0.0 extra' 'diagnose a b' unknown; do
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

export HOME="$test_root/diag-home"
export TERMUX_AI_TEST_SANDBOX_LOG="$test_root/sandbox.log"
diag_tools="$test_root/diag-tools"
diag_system="$test_root/diag-system"
diag_work="$test_root/diag work"
sandbox_probe="$HOME/.termux-ai-sandbox-probe"
mkdir -p "$HOME/.local/bin" "$HOME/.copilot" "$HOME/.gemini/antigravity-cli" "$diag_tools" "$diag_system" "$diag_work"
# Espelha /usr/bin e /bin sem os agentes reais de quem roda os testes no Linux do PRoot.
ln -s /usr/bin/* /bin/* "$diag_system/" 2> /dev/null || true
rm -f "$diag_system/"{codex,copilot,claude,agy,antigravity,opencode,hermes}
test -x "$diag_system/bash" || fail_test 'could not mirror the system commands'
cp "$test_root/bin/curl" "$diag_tools/curl"
cat > "$diag_tools/node" <<'MOCK'
#!/usr/bin/env bash
[[ $* == --version ]] || exit 2
printf 'v%s\n' "${TERMUX_AI_TEST_NODE_VERSION:-22.23.3}"
exit "${TERMUX_AI_TEST_NODE_FAILURE:-0}"
MOCK
cat > "$diag_tools/git" <<'MOCK'
#!/usr/bin/env bash
[[ $* == --version ]] || exit 2
printf 'git version 2.53.0\n'
exit "${TERMUX_AI_TEST_GIT_FAILURE:-0}"
MOCK
# Agente falso: o nome do arquivo escolhe o agente e TERMUX_AI_TEST_DIAG_<AGENTE> o estado.
cat > "$HOME/.local/bin/codex" <<'MOCK'
#!/usr/bin/env bash
tool="${0##*/}"
state_name="TERMUX_AI_TEST_DIAG_${tool^^}"
state="${!state_name:-yes}"
if [[ $* == --version ]]; then
    [[ $state != broken ]] || exit 3
    printf '%s 1.2.3\n' "$tool"
    exit 0
fi
case "$tool:${1:-}" in
    codex:login)
        case "$state" in
            yes) printf 'Logged in using ChatGPT\n' >&2 ;;
            no) printf 'Not logged in\n' >&2; exit 1 ;;
            *) printf 'Error: credentials unreadable\n' >&2; exit 1 ;;
        esac
        ;;
    codex:sandbox)
        printf '%s\n' "$*" >> "$TERMUX_AI_TEST_SANDBOX_LOG"
        while [[ $# -gt 0 && $1 != -- ]]; do
            shift
        done
        shift
        case "${TERMUX_AI_TEST_SANDBOX:-unavailable}" in
            unavailable) printf 'error building bubblewrap command\n' >&2; exit 1 ;;
            ineffective) exec "$@" ;;
            active) [[ $1 == /bin/true ]] || exit 1 ;;
        esac
        ;;
    claude:auth)
        case "$state" in
            yes) printf '{\n  "loggedIn": true,\n  "email": "secret@example.com"\n}\n' ;;
            no) printf '{\n  "loggedIn": false\n}\n'; exit 1 ;;
            *) printf 'Unexpected output\n' ;;
        esac
        ;;
    hermes:auth)
        [[ ${2:-} == list ]] || exit 2
        case "$state" in
            yes) printf 'openrouter (1 credentials):\n  #1  api_key  manual\n' ;;
            no) ;;
            *) printf 'Traceback (most recent call last)\n' >&2; exit 1 ;;
        esac
        ;;
    opencode:auth)
        if [[ $state == unknown ]]; then
            printf 'Unexpected output\n'
            exit 0
        fi
        printf '\033[90m+\033[0m  Credentials \033[90m~/.local/share/opencode/auth.json\033[0m\n'
        if [[ $state == yes ]]; then
            printf '|  GitHub Copilot \033[90moauth\033[0m\n\033[90m+\033[0m  2 credentials\n'
        else
            printf '\033[90m+\033[0m  0 credentials\n'
        fi
        if [[ $state == env ]]; then
            printf '\033[90m+\033[0m  Environment\n|  OpenAI \033[90mOPENAI_API_KEY\033[0m\n\033[90m+\033[0m  1 environment variable\n'
        fi
        ;;
    *) exit 2 ;;
esac
MOCK
for tool_name in copilot claude agy opencode; do
    cp "$HOME/.local/bin/codex" "$HOME/.local/bin/$tool_name"
done
chmod +x "$diag_tools/"* "$HOME/.local/bin/"*
printf 'token\n' > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"

write_copilot_config() {
    if [[ $1 == yes ]]; then
        printf '{\n  "loggedInUsers": [\n    {\n      "host": "https://github.com",\n      "login": "octocat"\n    }\n  ]\n}\n' \
            > "$HOME/.copilot/config.json"
    else
        printf '{\n  "loggedInUsers": [ ],\n  "trusted_folders": [\n    "/tmp"\n  ]\n}\n' > "$HOME/.copilot/config.json"
    fi
}

# Os tokens reais do ambiente nunca entram no teste.
run_guest_diagnostics() {
    env -u COPILOT_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_PROVIDER_BASE_URL -u COPILOT_HOME -u HERMES_HOME \
        PATH="$diag_tools:$diag_system" "$@"
}

expect_diag_lines() {
    local log_file="$1" expected_line
    shift
    for expected_line in "$@"; do
        grep -Fqx -- "$expected_line" "$log_file" || fail_test "missing <$expected_line> in $log_file"
    done
}

write_copilot_config yes
: > "$TERMUX_AI_TEST_SANDBOX_LOG"
run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag.log"
expected_diag="$(printf '@diag\t%s\t%s\t%s\t%s\n' \
    check node ok 22.23.3 \
    check git ok 2.53.0 \
    check workdir ok - \
    agent copilot yes 1.2.3 \
    agent claude yes 1.2.3 \
    agent codex yes 1.2.3 \
    agent agy yes 1.2.3 \
    agent opencode yes 1.2.3 \
    agent hermes missing - \
    check network ok - \
    isolation codex unavailable - \
    local embeddinggemma missing - \
    web painel stopped - \
    web terminal stopped - \
    web embedding stopped -)"
assert_equal "$(sed 1d "$test_root/guest-diag.log")" "$expected_diag" 'reports every check and agent in order'
grep -Eq $'^@diag\tcheck\tdistro\tok\t([A-Za-z0-9 ._()/+:-]{1,60}|-)$' <<< "$(head -n 1 "$test_root/guest-diag.log")" \
    || fail_test 'invalid Linux name in the diagnostic'
assert_equal "$(< "$TERMUX_AI_TEST_SANDBOX_LOG")" 'sandbox -c sandbox_mode="read-only" -- /bin/true' 'tests the Codex sandbox in read-only mode'
test -z "$(ls -A "$diag_work")" || fail_test 'diagnostic left files in the work folder'
if grep -Eq 'secret@example\.com|octocat' "$test_root/guest-diag.log"; then
    fail_test 'diagnostic exposed account details'
fi
printf '%s\n' 'PASS guest diagnostic reports versions, logins and the Codex sandbox'

write_copilot_config no
rm "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
run_guest_diagnostics TERMUX_AI_TEST_DIAG_CODEX=no TERMUX_AI_TEST_DIAG_CLAUDE=no TERMUX_AI_TEST_DIAG_OPENCODE=no \
    bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-no.log"
expect_diag_lines "$test_root/guest-diag-no.log" \
    $'@diag\tagent\tcopilot\tno\t1.2.3' \
    $'@diag\tagent\tclaude\tno\t1.2.3' \
    $'@diag\tagent\tcodex\tno\t1.2.3' \
    $'@diag\tagent\tagy\tno\t1.2.3' \
    $'@diag\tagent\topencode\tno\t1.2.3'
printf 'export GH_TOKEN=test-token-value\n' > "$HOME/.profile"
run_guest_diagnostics TERMUX_AI_TEST_DIAG_OPENCODE=env bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-env.log"
expect_diag_lines "$test_root/guest-diag-env.log" \
    $'@diag\tagent\tcopilot\tyes\t1.2.3' \
    $'@diag\tagent\topencode\tyes\t1.2.3'
if grep -q 'test-token-value' "$test_root/guest-diag-env.log"; then
    fail_test 'diagnostic exposed a token'
fi
rm "$HOME/.profile" "$HOME/.copilot/config.json"
mv "$HOME/.local/bin/agy" "$test_root/agy.diag"
run_guest_diagnostics TERMUX_AI_TEST_DIAG_COPILOT=broken TERMUX_AI_TEST_DIAG_CLAUDE=unknown \
    TERMUX_AI_TEST_DIAG_CODEX=unknown TERMUX_AI_TEST_DIAG_OPENCODE=unknown \
    bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-unknown.log"
expect_diag_lines "$test_root/guest-diag-unknown.log" \
    $'@diag\tagent\tcopilot\tbroken\t-' \
    $'@diag\tagent\tclaude\tunknown\t1.2.3' \
    $'@diag\tagent\tcodex\tunknown\t1.2.3' \
    $'@diag\tagent\tagy\tmissing\t-' \
    $'@diag\tagent\topencode\tunknown\t1.2.3'
run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-copilot.log"
expect_diag_lines "$test_root/guest-diag-copilot.log" $'@diag\tagent\tcopilot\tno\t1.2.3'
mv "$test_root/agy.diag" "$HOME/.local/bin/agy"
printf '%s\n' 'PASS guest diagnostic separates missing, unknown and broken agents'

install -m 755 "$HOME/.local/bin/codex" "$HOME/.local/bin/hermes"
mkdir -p "$HOME/.hermes"
hermes_diag_line() {
    run_guest_diagnostics "$@" bash "$setup_script" diagnose "$diag_work" | grep -F $'@diag\tagent\thermes\t'
}
write_hermes_env() {
    printf '%s\n' "$@" > "$HOME/.hermes/.env"
}
for hermes_state in yes no unknown; do
    assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES="$hermes_state")" $'@diag\tagent\thermes\t'"$hermes_state"$'\t1.2.3' \
        "reports the Hermes login state: $hermes_state"
done
assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES=broken)" $'@diag\tagent\thermes\tbroken\t-' 'reports a Hermes that does not start'
write_hermes_env 'HERMES_MODEL=some-model' '# OPENROUTER_API_KEY=commented' 'OPENROUTER_API_KEY=' 'GH_TOKEN=""' "SOME_KEY=''" \
    'TOKEN_NOTE=spaced' 'ANOTHER_KEY=   ' 'KEY_WITH_COMMENT= # not a value'
assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES=no)" $'@diag\tagent\thermes\tno\t1.2.3' 'ignores comments, empty values and unrelated settings in the Hermes configuration'
for hermes_env_line in 'export ANTHROPIC_API_KEY="sk-secret-value"' '  OPENROUTER_API_KEY=sk-secret-value' "TELEGRAM_BOT_TOKEN='123:secret-value'" \
    'DEEPSEEK_API_KEY = sk-secret-value'; do
    write_hermes_env 'HERMES_MODEL=some-model' "$hermes_env_line"
    for hermes_state in no unknown; do
        assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES="$hermes_state")" $'@diag\tagent\thermes\tyes\t1.2.3' \
            "recognizes a Hermes credential in its configuration: $hermes_env_line"
    done
done
run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-hermes.log"
if grep -q 'secret-value' "$test_root/guest-diag-hermes.log"; then
    fail_test 'diagnostic exposed a Hermes credential'
fi
rm "$HOME/.hermes/.env"
mkdir -p "$test_root/hermes-home"
printf 'OPENROUTER_API_KEY=sk-other-home\n' > "$test_root/hermes-home/.env"
assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES=no HERMES_HOME="$test_root/hermes-home")" $'@diag\tagent\thermes\tyes\t1.2.3' \
    'reads the Hermes configuration from HERMES_HOME'
assert_equal "$(hermes_diag_line TERMUX_AI_TEST_DIAG_HERMES=no)" $'@diag\tagent\thermes\tno\t1.2.3' 'does not mix the default Hermes configuration with HERMES_HOME'
rm "$HOME/.local/bin/hermes"
rmdir "$HOME/.hermes"
printf '%s\n' 'PASS guest diagnostic reads Hermes logins without exposing credentials'

mkdir -p "$HOME/.local/share/termux-ai/web"
bash -c 'exec -a termux-ai/hub/server.mjs sleep 60' &
fake_panel=$!
printf '%s\n' "$fake_panel" > "$HOME/.local/share/termux-ai/web/painel.pid"
run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-web.log"
expect_diag_lines "$test_root/guest-diag-web.log" $'@diag\tweb\tpainel\tactive\t127.0.0.1:7690'
kill "$fake_panel"
wait "$fake_panel" 2> /dev/null || true
for stale_pid in "$fake_panel" "$$" not-a-pid; do
    printf '%s\n' "$stale_pid" > "$HOME/.local/share/termux-ai/web/painel.pid"
    run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-web.log"
    expect_diag_lines "$test_root/guest-diag-web.log" $'@diag\tweb\tpainel\tstopped\t-'
done
rm "$HOME/.local/share/termux-ai/web/painel.pid"
printf '%s\n' 'PASS guest diagnostic reports the panel only while its process is alive'

for sandbox_mode in ineffective active; do
    : > "$TERMUX_AI_TEST_SANDBOX_LOG"
    run_guest_diagnostics TERMUX_AI_TEST_SANDBOX="$sandbox_mode" bash "$setup_script" diagnose "$diag_work" \
        > "$test_root/guest-diag-sandbox.log"
    expect_diag_lines "$test_root/guest-diag-sandbox.log" $'@diag\tisolation\tcodex\t'"$sandbox_mode"$'\t-'
    assert_equal "$(grep -c '^sandbox -c sandbox_mode="read-only" -- ' "$TERMUX_AI_TEST_SANDBOX_LOG")" 2 'tests the sandbox and a blocked write'
    test ! -e "$sandbox_probe" || fail_test 'sandbox probe was left behind'
done
mv "$HOME/.local/bin/codex" "$test_root/codex.diag"
run_guest_diagnostics bash "$setup_script" diagnose "$diag_work" > "$test_root/guest-diag-no-codex.log"
expect_diag_lines "$test_root/guest-diag-no-codex.log" \
    $'@diag\tagent\tcodex\tmissing\t-' \
    $'@diag\tisolation\tcodex\tmissing\t-'
mv "$test_root/codex.diag" "$HOME/.local/bin/codex"
printf '%s\n' 'PASS guest diagnostic only trusts a sandbox that blocks writes'

run_guest_diagnostics TERMUX_AI_TEST_NODE_VERSION=20.11.1 TERMUX_AI_TEST_NETWORK_FAILURE=7 \
    bash "$setup_script" diagnose "$test_root/missing folder" > "$test_root/guest-diag-system.log"
expect_diag_lines "$test_root/guest-diag-system.log" \
    $'@diag\tcheck\tnode\told\t20.11.1' \
    $'@diag\tcheck\tworkdir\tfail\t-' \
    $'@diag\tcheck\tnetwork\tfail\t-'
test ! -e "$test_root/missing folder"
run_guest_diagnostics TERMUX_AI_TEST_NODE_FAILURE=1 TERMUX_AI_TEST_GIT_FAILURE=1 \
    bash "$setup_script" diagnose relative/folder > "$test_root/guest-diag-system.log"
expect_diag_lines "$test_root/guest-diag-system.log" \
    $'@diag\tcheck\tnode\tmissing\t-' \
    $'@diag\tcheck\tgit\tmissing\t-' \
    $'@diag\tcheck\tworkdir\tskip\t-'
run_guest_diagnostics bash "$setup_script" diagnose > "$test_root/guest-diag-system.log"
expect_diag_lines "$test_root/guest-diag-system.log" $'@diag\tcheck\tworkdir\tskip\t-'
printf '%s\n' 'PASS guest diagnostic checks Node.js, Git, network and the work folder'

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
cmp "$state_dir/webui.sh" "$project_root/scripts/webui.sh"
cmp "$state_dir/web/menu.sh" "$project_root/scripts/web-menu.sh"
cmp "$state_dir/tools/embeddinggemma_web.py" "$project_root/scripts/embeddinggemma_web.py"
cmp "$state_dir/tools/embeddinggemma_cli.py" "$project_root/scripts/embeddinggemma_cli.py"
for tool_name in ia codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
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
for tool_name in ia codex copilot claude antigravity agy opencode hermes embeddinggemma embedding; do
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
test ! -e "$PREFIX/bin/hermes"
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

for relative_path in install.sh bin/ia scripts/setup-linux.sh scripts/menu.bash scripts/webui.sh scripts/web-menu.sh scripts/embeddinggemma_web.py scripts/embeddinggemma_cli.py scripts/embeddinggemma-launcher.sh scripts/add-opencode-ubuntu.sh scripts/hub/attach.sh tests/run.sh; do
    if [[ $relative_path != *.py ]]; then
        bash -n "$project_root/$relative_path"
    fi
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        printf 'FAIL: CRLF in %s\n' "$relative_path" >&2
        exit 1
    fi
done
for relative_path in scripts/hub/util.mjs scripts/hub/agents.mjs scripts/hub/orchestrator.mjs scripts/hub/sessions.mjs scripts/hub/server.mjs scripts/hub/cli.mjs scripts/hub/index.html scripts/hub/tmux.conf; do
    if LC_ALL=C grep -q $'\r' "$project_root/$relative_path"; then
        printf 'FAIL: CRLF in %s\n' "$relative_path" >&2
        exit 1
    fi
done
PYTHONPYCACHEPREFIX="$test_root/pycache" python3 -m py_compile "$project_root/scripts/embeddinggemma_web.py"
PYTHONPYCACHEPREFIX="$test_root/pycache" python3 -m py_compile "$project_root/scripts/embeddinggemma_cli.py"
python3 "$project_root/scripts/embeddinggemma_cli.py" --version > "$test_root/embedding-version.log"
assert_equal "$(< "$test_root/embedding-version.log")" 2.0.0 'runs the version command without loading model dependencies'
expect_failure 'EmbeddingGemma server accepted a non-loopback host' python3 "$project_root/scripts/embeddinggemma_cli.py" serve --host 0.0.0.0
grep -q 'invalid choice' "$test_root/expected-failure.log"
grep -Fq 'codex -s workspace-write -a on-request' "$project_root/scripts/web-menu.sh"
grep -Fq '7. EmbeddingGemma 2 (local, opcional)' "$project_root/scripts/web-menu.sh"
grep -Fq '8. Versoes e atualizacoes dos agentes' "$project_root/scripts/web-menu.sh"
grep -Fq '9. Diagnostico do ambiente' "$project_root/scripts/web-menu.sh"
grep -Fq '10. Hermes Agent (opcional)' "$project_root/scripts/web-menu.sh"
grep -Fq 'web_hermes' "$project_root/scripts/web-menu.sh"

TERMUX_AI_CACHE_DIR="$test_root/emb-cache" python3 - "$project_root/scripts" "$test_root" <<'PYTEST'
import pathlib
import sys

scripts_dir = pathlib.Path(sys.argv[1])
test_root = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(scripts_dir))

import embeddinggemma_cli as cli

search_dir = test_root / "search-sample"
search_dir.mkdir(parents=True, exist_ok=True)
(search_dir / "valid.py").write_text(
    "def authenticate_user(token):\n    # Valida o token de sessao do usuario no sistema\n    return bool(token)\n",
    encoding="utf-8",
)
(search_dir / "oversized.py").write_text("x = 1\n" * 60000, encoding="utf-8")

outside_file = test_root / "outside-secret.py"
outside_file.write_text("secret = 'should not be indexed through symlink'\n" * 3, encoding="utf-8")
(search_dir / "escape.py").symlink_to(outside_file)

chunks = cli.collect_search_chunks(search_dir)
assert len(chunks) == 1, f"expected 1 valid chunk, got {len(chunks)}"
assert chunks[0]["file"] == "valid.py"

class FakeEncoder:
    def __init__(self):
        self.doc_calls = 0
        self.query_calls = 0

    def encode(self, texts, prompt_name=None, truncate_dim=256, normalize_embeddings=True, batch_size=16):
        if prompt_name == "Document":
            self.doc_calls += len(texts)
            return [[0.5] * truncate_dim for _ in texts]
        self.query_calls += 1
        return [0.5] * truncate_dim

encoder = FakeEncoder()
results1, cached1, encoded1 = cli.rank_search_chunks("autenticacao", chunks, dimensions=128, top=5, encoder=encoder)
assert cached1 == 0 and encoded1 == 1 and encoder.doc_calls == 1
assert len(results1) == 1 and results1[0]["file"] == "valid.py"

results2, cached2, encoded2 = cli.rank_search_chunks("autenticacao", chunks, dimensions=128, top=5, encoder=encoder)
assert cached2 == 1 and encoded2 == 0 and encoder.doc_calls == 1
assert len(results2) == 1 and results2[0]["file"] == "valid.py"
PYTEST
printf '%s\n' 'PASS EmbeddingGemma file limits, symlink boundary and persistent embedding cache'
printf '%s\n' 'PASS shell syntax and Linux line endings'