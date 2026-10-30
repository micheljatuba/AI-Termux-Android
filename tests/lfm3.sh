#!/usr/bin/env bash
# Testes offline do LFM3 (scripts/lfm3.sh): pkg, dpkg-query, llama-cli e llama-server simulados.
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lfm3="$project_root/scripts/lfm3.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export HOME="$test_root/home"
export PREFIX="$test_root/prefix"
export MOCK_LOG="$test_root/calls.log"
export TERMUX_AI_TEST_FREE_KIB=$((8 * 1024 * 1024))
export TERMUX_AI_TEST_RAM_KIB=$((8 * 1024 * 1024))
unset TERMUX_AI_GUEST
mkdir -p "$HOME" "$PREFIX/bin" "$test_root/llama"
export PATH="$PREFIX/bin:$PATH"

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cat > "$PREFIX/bin/pkg" <<'MOCK'
#!/usr/bin/env bash
printf 'pkg %s\n' "$*" >> "$MOCK_LOG"
for tool in llama-cli llama-server; do
    ln -sf "$MOCK_LLAMA_DIR/$tool" "$PREFIX/bin/$tool"
done
MOCK
cat > "$PREFIX/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
[[ -n ${MOCK_PACKAGE_VERSION:-} ]] || exit 1
printf '%s' "$MOCK_PACKAGE_VERSION"
MOCK
cat > "$test_root/llama/llama-cli" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then
    printf 'version: %s (8642541)\n' "${MOCK_BUILD:-11960}"
    exit 0
fi
printf 'llama-cli LLAMA_CACHE=%s %s\n' "$LLAMA_CACHE" "$*" >> "$MOCK_LOG"
if [[ " $* " != *' --offline '* && -z ${MOCK_DOWNLOAD_FAILS:-} ]]; then
    mkdir -p "$LLAMA_CACHE"
    : > "$LLAMA_CACHE/LiquidAI_LFM3-1.7B-GGUF_LFM3-1.7B-Q4_K_M.gguf"
fi
MOCK
cat > "$test_root/llama/llama-server" <<'MOCK'
#!/usr/bin/env bash
printf 'llama-server LLAMA_CACHE=%s %s\n' "$LLAMA_CACHE" "$*" >> "$MOCK_LOG"
MOCK
chmod +x "$PREFIX/bin/pkg" "$PREFIX/bin/dpkg-query" "$test_root/llama/llama-cli" "$test_root/llama/llama-server"
export MOCK_LLAMA_DIR="$test_root/llama"
export MOCK_PACKAGE_VERSION=0.8.0

lfm3_dir="$HOME/.local/share/termux-ai/lfm3"
mode_of() {
    stat -c '%a' "$1"
}

# Fora de um terminal, nada e instalado sem --sim.
status=0
bash "$lfm3" instalar < /dev/null > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] || die 'install ran without confirmation'
[[ ! -e $MOCK_LOG ]] || die 'install called a tool without confirmation'
grep -Fq 'LFM Open License v1.0' "$test_root/out" || die 'install did not show the license'
printf '%s\n' 'PASS LFM3 install asks for confirmation and shows the license'

# Dentro do Linux (PRoot) o comando recusa: o llama-cpp e do Termux.
status=0
TERMUX_AI_GUEST=1 bash "$lfm3" status > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] && grep -Fq 'fora do Linux' "$test_root/out" || die 'lfm3 ran inside the guest'
printf '%s\n' 'PASS LFM3 refuses to run inside PRoot'

# Pouco espaco aborta antes de instalar.
status=0
TERMUX_AI_TEST_FREE_KIB=1048576 bash "$lfm3" instalar --sim > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 && ! -e $MOCK_LOG ]] || die 'install continued without free space'
printf '%s\n' 'PASS LFM3 install checks free space first'

# Nomes de modelo, quantizacao e porta sao validados (sem repositorio arbitrario nem injecao de argumentos).
for bad in '--modelo evil/LFM3-1.7B-GGUF' '--modelo LiquidAI/LFM3-x-GGUF;rm' '--quant ../x' '--quant -hf' '--porta 80' '--porta abc'; do
    status=0
    # shellcheck disable=SC2086
    bash "$lfm3" instalar --sim $bad > "$test_root/out" 2>&1 || status=$?
    [[ $status -ne 0 ]] || die "accepted invalid option: $bad"
done
[[ ! -e $MOCK_LOG ]] || die 'an invalid option reached a tool'
printf '%s\n' 'PASS LFM3 validates model, quantization and port'

# llama-cpp antigo (sem LFM3) e recusado antes do download.
status=0
MOCK_PACKAGE_VERSION=0.7.9 bash "$lfm3" instalar --sim > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] && grep -Fq 'pkg upgrade llama-cpp' "$test_root/out" || die 'old llama-cpp was accepted'
! grep -q '^llama-cli' "$MOCK_LOG" || die 'old llama-cpp started a download'
# Sem dpkg-query, vale o numero do build.
status=0
MOCK_PACKAGE_VERSION='' MOCK_BUILD=11959 bash "$lfm3" instalar --sim > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] || die 'build 11959 was accepted'
printf '%s\n' 'PASS LFM3 requires llama-cpp 0.8.0 (build 11960) or newer'

# Download que falha nao deixa o modelo como pronto.
status=0
MOCK_DOWNLOAD_FAILS=1 bash "$lfm3" instalar --sim > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] || die 'install succeeded without a model'
bash "$lfm3" status > "$test_root/out"
grep -Fq 'nao baixado' "$test_root/out" || die 'status reported a missing model as present'
status=0
bash "$lfm3" > "$test_root/out" 2>&1 || status=$?
[[ $status -ne 0 ]] && grep -Fq 'ia lfm3 instalar' "$test_root/out" || die 'chat opened without a model'
printf '%s\n' 'PASS LFM3 failed download is reported and chat refuses'

: > "$MOCK_LOG"
bash "$lfm3" instalar --sim --quant Q4_K_M > "$test_root/out" 2>&1 || { cat "$test_root/out"; die 'install failed'; }
grep -Fqx 'pkg install -y llama-cpp' "$MOCK_LOG" || die 'llama-cpp was not installed'
grep -Fq "llama-cli LLAMA_CACHE=$lfm3_dir/modelos -hf LiquidAI/LFM3-1.7B-GGUF:Q4_K_M -no-cnv" "$MOCK_LOG" \
    || die 'model was not downloaded into the private cache'
[[ $(mode_of "$lfm3_dir") == 700 && $(mode_of "$lfm3_dir/modelos") == 700 ]] || die 'LFM3 folders are not private'
[[ $(mode_of "$lfm3_dir/lfm3.conf") == 600 ]] || die 'lfm3.conf is not private'
printf '%s\n' 'PASS LFM3 install downloads into a private folder'

: > "$MOCK_LOG"
bash "$lfm3" > /dev/null
grep -Fq "llama-cli LLAMA_CACHE=$lfm3_dir/modelos -hf LiquidAI/LFM3-1.7B-GGUF:Q4_K_M --offline" "$MOCK_LOG" \
    || die 'chat did not run offline with the saved model'
printf '%s\n' 'PASS LFM3 chat runs offline with the saved model'

# A configuracao e lida como dados: linhas estranhas sao ignoradas.
printf 'repo=LiquidAI/LFM3-1.7B-GGUF\nquant=$(touch %s)\nrepo=evil/x\n' "$test_root/pwned" > "$lfm3_dir/lfm3.conf"
: > "$MOCK_LOG"
bash "$lfm3" > /dev/null
[[ ! -e $test_root/pwned ]] || die 'lfm3.conf was executed'
grep -Fq -- '-hf LiquidAI/LFM3-1.7B-GGUF --offline' "$MOCK_LOG" || die 'invalid config values were used'
printf '%s\n' 'PASS LFM3 config is read as data'

status=0
bash "$lfm3" token > /dev/null 2>&1 || status=$?
[[ $status -ne 0 ]] || die 'token printed before the server created one'
: > "$MOCK_LOG"
bash "$lfm3" servidor --porta 8099 > /dev/null 2>&1
server_line="$(grep '^llama-server' "$MOCK_LOG")"
[[ $server_line == *'--host 127.0.0.1 --port 8099 '* ]] || die 'server is not bound to loopback'
[[ $server_line == *"--api-key-file $lfm3_dir/token"* ]] || die 'server runs without the token'
[[ $server_line == *'--no-webui'* && $server_line == *'--offline'* ]] || die 'server web UI or network not disabled'
[[ $(mode_of "$lfm3_dir/token") == 600 ]] || die 'token file is not private'
grep -Eqx '[0-9a-f]{64}' "$lfm3_dir/token" || die 'token is not 256 bits of hex'
first_token="$(bash "$lfm3" token)"
bash "$lfm3" servidor > /dev/null 2>&1
[[ $(bash "$lfm3" token) == "$first_token" ]] || die 'token changed between runs'
grep -Fq -- '--port 8086 ' "$MOCK_LOG" || die 'default port is not 8086'
printf '%s\n' 'PASS LFM3 server listens on 127.0.0.1 with a private token and no web UI'

status=0
bash "$lfm3" remover < /dev/null > /dev/null 2>&1 || status=$?
[[ $status -ne 0 && -d $lfm3_dir/modelos ]] || die 'remove ran without confirmation'
bash "$lfm3" remover --sim > /dev/null
[[ ! -e $lfm3_dir/modelos && -f $lfm3_dir/token ]] || die 'remove did not delete only the models'
printf '%s\n' 'PASS LFM3 remove deletes only the downloaded models after confirmation'
