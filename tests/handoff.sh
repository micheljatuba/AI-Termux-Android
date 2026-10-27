#!/usr/bin/env bash
# Testes offline do handoff (scripts/handoff.sh): repositorios locais e gh simulado.
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
handoff="$project_root/scripts/handoff.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export HOME="$test_root/home"
export GIT_CONFIG_GLOBAL="$test_root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$test_root/bin"
git config --global user.name 'Tester'
git config --global user.email 'tester@example.com'
git config --global init.defaultBranch main
export PATH="$test_root/bin:$PATH"

cat > "$test_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2" in
    'auth status') exit "${MOCK_GH_AUTH:-0}" ;;
    'repo view') printf '%s\n' "${MOCK_GH_PRIVATE:-true}" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$test_root/bin/gh"

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        printf 'FAIL: %s\nExpected: <%s>\nActual: <%s>\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_contains() {
    grep -qF -- "$2" <<< "$1" || die "$3 (faltou: $2)"$'\n'"$1"
}

assert_not_contains() {
    if grep -qF -- "$2" <<< "$1"; then die "$3 (nao devia conter: $2)"; fi
}

# Valores falsos montados em tempo de execucao: o repositorio nao guarda nada
# que pareca uma credencial.
repeat() { local out='' i; for (( i = 0; i < $2; i++ )); do out+="$1"; done; printf '%s' "$out"; }
fake_github_token="ghp_$(repeat a 36)"
fake_aws_key="AKIA$(repeat A 16)"

remote="$test_root/remote.git"
device_a="$test_root/device-a"
git init -q --bare "$remote"
git init -q "$device_a"
(
    cd "$device_a"
    printf 'v1\n' > app.txt
    git add app.txt
    git commit -q -m 'primeiro commit'
    git remote add origin https://github.com/acme/private-repo.git
    git config "url.$remote.insteadOf" https://github.com/acme/private-repo.git
    git push -q origin main
)
device_b="$test_root/device-b"
git clone -q "$remote" "$device_b"

run_in() {
    local dir="$1"
    shift
    (cd "$dir" && "$@" < /dev/null)
}
a_handoff() { run_in "$device_a" bash "$handoff" "$@"; }
remote_branches() { git -C "$remote" for-each-ref --format='%(refname)' refs/heads/ia/handoff/; }
count_branches() { remote_branches | wc -l | tr -d ' '; }

# expect_failure NOME MENSAGEM SEGREDO COMANDO...
expect_failure() {
    local name="$1" expected="$2" secret="$3" before out
    shift 3
    before="$(count_branches)"
    if out="$("$@" 2>&1)"; then
        die "$name: comando aceito"
    fi
    assert_contains "$out" "$expected" "$name: mensagem"
    [[ -z $secret ]] || assert_not_contains "$out" "$secret" "$name: vazou o segredo"
    assert_equal "$(count_branches)" "$before" "$name: nada pode ser enviado"
}

# ---------------------------------------------------------------- tabela de caminhos
# shellcheck source=../scripts/handoff.sh
source "$handoff"
for path in .env .env.local config/.env.production id_rsa id_ed25519.pub certs/KEY.PEM a/b/.ssh/known_hosts \
    .claude/settings.json .codex/auth.json .gemini/x node_modules/x/index.js sub/node_modules/y credentials.json \
    auth.json .npmrc db.sqlite3 data.DB .ia/HANDOFF.md .config/gh/hosts.yml .local/share/opencode/auth.json; do
    is_sensitive_path "$path" || die "caminho sensivel aceito: $path"
done
for path in README.md src/env.js environment.ts keyboard.js auth.js .envrc docs/credentials.md .gitignore notes/todo.md; do
    ! is_sensitive_path "$path" || die "caminho comum bloqueado: $path"
done
printf '%s\n' 'PASS sensitive path table'

# ---------------------------------------------------------------- varredura de segredos
scan_dir="$test_root/scan"
mkdir -p "$scan_dir"
jwt="eyJ$(repeat a 12).eyJ$(repeat b 12).$(repeat c 12)"
secret_cases=(
    "$fake_github_token"
    "github_pat_$(repeat a 25)"
    "sk-ant-$(repeat a 30)"
    "sk-proj-$(repeat b 30)"
    "$fake_aws_key"
    "AIza$(repeat a 35)"
    "xoxb-$(repeat 1 12)"
    "$jwt"
    "-----BEGIN RSA PRIVATE KEY-----"
    'url = https://usuario:senha123@example.com/repo'
    "api_key = \"$(repeat z 26)\""
)
for secret in "${secret_cases[@]}"; do
    printf 'linha anterior\nvalor: %s\n' "$secret" > "$scan_dir/sample"
    if out="$(scan_file "$scan_dir/sample" sample 2>&1)"; then
        die "segredo nao detectado: ${secret:0:8}..."
    fi
    assert_not_contains "$out" "$secret" 'o relatorio nao pode repetir o segredo'
    assert_contains "$out" 'linha 2' 'informa a linha'
done
for harmless in 'task-manager-description-longer-than-twenty' 'git@github.com:acme/repo.git' 'password = getenv()' 'AKIA' \
    'const x = process.env.TOKEN;' 'Handoff funciona entre aparelhos'; do
    printf '%s\n' "$harmless" > "$scan_dir/sample"
    scan_file "$scan_dir/sample" sample > /dev/null 2>&1 || die "falso positivo: $harmless"
done
printf '%s\n' 'PASS secret scanner reports rules and lines without echoing values'

# ---------------------------------------------------------------- envio feliz
(
    cd "$device_a"
    printf 'local\n' > local.txt
    git add local.txt
    git commit -q -m 'commit local ainda nao publicado'
    printf 'v2\n' >> app.txt
    mkdir -p notes node_modules/pkg
    printf 'proximo: login\n' > notes/todo.md
    printf 'SEGREDO_DE_TESTE_NAO_ENVIAR\n' > .env
    printf 'module.exports = 1;\n' > node_modules/pkg/index.js
    git status > /dev/null
)
a_head="$(git -C "$device_a" rev-parse HEAD)"
a_status="$(git -C "$device_a" status --porcelain -uall)"
a_index="$(sha256sum "$device_a/.git/index" | cut -d' ' -f1)"
a_refs="$(git -C "$device_a" for-each-ref --format='%(refname) %(objectname)' | grep -v 'refs/remotes' || true)"

out="$(a_handoff handoff --yes --device pixel-9 --note 'Proximo passo: testar o login do usuario')"
assert_contains "$out" 'privado confirmado' 'confirma a visibilidade'
assert_contains "$out" 'ia continuar' 'explica como continuar'
assert_equal "$(count_branches)" 1 'cria exatamente um branch de handoff'
handoff_ref="$(remote_branches)"
[[ $handoff_ref =~ ^refs/heads/ia/handoff/pixel-9/[0-9]{8}T[0-9]{6}Z$ ]] || die "nome inesperado: $handoff_ref"
files="$(git -C "$remote" ls-tree -r --name-only "$handoff_ref")"
for expected in app.txt local.txt notes/todo.md .ia/HANDOFF.md; do
    assert_contains "$files" "$expected" 'arquivo esperado no envio'
done
assert_not_contains "$files" '.env' 'o .env nao pode ser enviado'
assert_not_contains "$files" 'node_modules' 'node_modules nao pode ser enviado'
note="$(git -C "$remote" show "$handoff_ref:.ia/HANDOFF.md")"
assert_contains "$note" 'Proximo passo: testar o login do usuario' 'nota do autor'
assert_contains "$note" 'commit local ainda nao publicado' 'commits locais listados'
assert_contains "$note" 'Excluidos por seguranca' 'exclusoes registradas'
assert_not_contains "$note" "$test_root" 'a nota nao pode conter caminhos locais'
assert_not_contains "$(git -C "$remote" show "$handoff_ref:app.txt")" SEGREDO 'conteudo nao mistura segredos'
printf '%s\n' 'PASS handoff pushes a dedicated branch without sensitive files or local paths'

assert_equal "$(git -C "$device_a" rev-parse HEAD)" "$a_head" 'HEAD permanece'
assert_equal "$(git -C "$device_a" status --porcelain -uall)" "$a_status" 'arquivos e indice permanecem'
assert_equal "$(sha256sum "$device_a/.git/index" | cut -d' ' -f1)" "$a_index" 'o indice real nao e escrito'
assert_equal "$(git -C "$device_a" for-each-ref --format='%(refname) %(objectname)' | grep -v 'refs/remotes' || true)" "$a_refs" 'nenhuma ref local nova'
test ! -e "$device_a/.ia" || die 'handoff nao pode criar .ia no projeto'
assert_equal "$(git -C "$device_a" stash list)" '' 'sem stash'
printf '%s\n' 'PASS handoff leaves branch, index and working tree untouched'

# ---------------------------------------------------------------- retomada
list_out="$(run_in "$device_b" bash "$handoff" continuar --list)"
assert_contains "$list_out" pixel-9 'lista o handoff'
assert_contains "$list_out" 'branch main' 'mostra o branch de origem'
assert_equal "$(git -C "$device_b" branch --list 'ia/*')" '' '--list nao cria branches'
run_in "$device_b" bash "$handoff" continuar --latest --yes > "$test_root/continue.log"
b_branch="$(git -C "$device_b" symbolic-ref --short HEAD)"
[[ $b_branch =~ ^ia/continuar/pixel-9/[0-9]{8}T[0-9]{6}Z$ ]] || die "branch local inesperado: $b_branch"
assert_equal "$(git -C "$device_b" rev-parse HEAD)" "$a_head" 'a base inclui o commit local do outro aparelho'
b_status="$(git -C "$device_b" status --porcelain -uall)"
assert_contains "$b_status" ' M app.txt' 'alteracao restaurada como nao confirmada'
assert_contains "$b_status" '?? notes/todo.md' 'arquivo novo restaurado'
assert_not_contains "$b_status" '.ia' 'a nota nao aparece no git status'
assert_equal "$(< "$device_b/app.txt")" "$(printf 'v1\nv2')" 'conteudo restaurado'
assert_equal "$(< "$device_b/.ia/HANDOFF.md")" "$note" 'a nota chegou intacta'
test ! -e "$device_b/.env" || die '.env nao pode aparecer no outro aparelho'
grep -qxF '/.ia/' "$device_b/.git/info/exclude" || die '.ia deve ficar fora do git'
if run_in "$device_b" bash "$handoff" continuar --latest --yes > "$test_root/again.log" 2>&1; then
    die 'segunda retomada com alteracoes nao confirmadas foi aceita'
fi
assert_contains "$(< "$test_root/again.log")" 'alteracoes nao confirmadas' 'protege o trabalho existente'
printf '%s\n' 'PASS continue restores uncommitted work on a new branch and protects existing work'

# ---------------------------------------------------------------- recusas de seguranca
printf 'proximo\n' >> "$device_a/notes/todo.md"
expect_failure 'repositorio publico' 'e publico' '' \
    run_in "$device_a" env MOCK_GH_PRIVATE=false bash "$handoff" handoff --yes
expect_failure 'visibilidade desconhecida' 'Nao foi possivel confirmar a visibilidade' '' \
    run_in "$device_a" env MOCK_GH_PRIVATE=unknown bash "$handoff" handoff --yes
expect_failure 'gh sem login' 'gh auth login' '' \
    run_in "$device_a" env MOCK_GH_AUTH=1 bash "$handoff" handoff --yes
expect_failure 'sem confirmacao interativa' 'Sem entrada interativa' '' a_handoff handoff
expect_failure 'opcao desconhecida' 'Opcao desconhecida' '' a_handoff handoff --force
expect_failure 'sem identidade git' 'Configure sua identidade git' '' \
    run_in "$device_a" env GIT_CONFIG_GLOBAL=/dev/null bash "$handoff" handoff --yes
if out="$(run_in "$device_b" env GIT_CONFIG_GLOBAL=/dev/null bash "$handoff" continuar --latest --yes 2>&1)"; then
    die 'continuar sem identidade git foi aceito'
fi
assert_contains "$out" 'Configure sua identidade git' 'continuar exige identidade'
printf '%s\n' 'PASS private-repository gate and non-interactive confirmation'

github_url='https://github.com/acme/private-repo.git'
git -C "$device_a" config remote.origin.url "https://usuario:$fake_github_token@github.com/acme/private-repo.git"
expect_failure 'credencial na URL' 'Nao consigo confirmar que o remoto e privado' "$fake_github_token" \
    a_handoff handoff --yes
git -C "$device_a" config remote.origin.url "$github_url"
git -C "$device_a" config --add remote.origin.url https://github.com/acme/public-mirror.git
expect_failure 'segunda URL de envio' 'mais de uma URL' '' a_handoff handoff --yes
git -C "$device_a" config --unset-all remote.origin.url
git -C "$device_a" config remote.origin.url "$github_url"
git -C "$device_a" config remote.origin.pushurl https://github.com/acme/public-mirror.git
expect_failure 'pushurl diferente' 'pushurl diferente' '' a_handoff handoff --yes
git -C "$device_a" config --unset remote.origin.pushurl
git -C "$device_a" config url.https://github.com/acme/public-mirror.git.pushInsteadOf "$github_url"
expect_failure 'pushInsteadOf' 'pushInsteadOf' '' a_handoff handoff --yes
git -C "$device_a" config --unset url.https://github.com/acme/public-mirror.git.pushInsteadOf
git -C "$device_a" config remote.origin.url "$remote"
expect_failure 'remoto fora do GitHub' 'Nao consigo confirmar que o remoto e privado' '' a_handoff handoff --yes
git -C "$device_a" config remote.origin.url "$github_url"
printf '%s\n' 'PASS remotes without verifiable visibility are refused'

printf 'const k = "%s";\n' "$fake_github_token" > "$device_a/config.js"
expect_failure 'segredo em arquivo' 'token GitHub' "$fake_github_token" a_handoff handoff --yes
assert_contains "$(a_handoff handoff --yes 2>&1 || true)" 'config.js' 'aponta o arquivo'
rm "$device_a/config.js"

printf 'chave = %s\n' "$fake_aws_key" > "$device_a/old.txt"
git -C "$device_a" add old.txt
git -C "$device_a" commit -q -m 'commit com segredo'
expect_failure 'segredo em commit local' 'Segredo em commits locais' "$fake_aws_key" a_handoff handoff --yes
git -C "$device_a" reset -q --mixed HEAD~1
rm "$device_a/old.txt"

expect_failure 'segredo na nota' 'A nota contem um segredo' "$fake_github_token" \
    a_handoff handoff --yes --note "use $fake_github_token"

head -c $((6 * 1024 * 1024)) /dev/zero > "$device_a/grande.bin"
expect_failure 'arquivo grande' 'maior que 5 MiB' '' a_handoff handoff --yes
rm "$device_a/grande.bin"

touch "$device_a/.git/MERGE_HEAD"
expect_failure 'merge em andamento' 'operacao git em andamento' '' a_handoff handoff --yes
rm "$device_a/.git/MERGE_HEAD"

not_a_repo="$test_root/not-a-repo"
mkdir -p "$not_a_repo"
if out="$(run_in "$not_a_repo" bash "$handoff" handoff --yes 2>&1)"; then die 'fora de um repositorio foi aceito'; fi
assert_contains "$out" 'dentro de um repositorio git' 'fora de repositorio'
no_remote="$test_root/no-remote"
git init -q "$no_remote"
git -C "$no_remote" commit -q --allow-empty -m inicial
if out="$(run_in "$no_remote" bash "$handoff" handoff --yes 2>&1)"; then die 'repositorio sem remoto foi aceito'; fi
assert_contains "$out" 'remoto origin' 'sem remoto'
printf '%s\n' 'PASS secrets, large files, unfinished operations and invalid repositories abort without pushing'

# ---------------------------------------------------------------- simulacao e remoto nao verificado
before="$(count_branches)"
out="$(a_handoff handoff --dry-run)"
assert_contains "$out" 'Simulacao: nada foi enviado' 'dry-run'
assert_equal "$(count_branches)" "$before" 'dry-run nao envia'
git -C "$device_a" config remote.origin.url "$remote"
sleep 1
out="$(a_handoff handoff --yes --device tablet --allow-unverified-remote 2>&1)"
assert_contains "$out" 'NAO verificada' 'avisa quando nao verifica'
assert_equal "$(count_branches)" 2 'envio explicito para remoto nao verificado'
git -C "$device_a" config remote.origin.url "$github_url"
printf '%s\n' 'PASS dry run and explicit unverified-remote override'

# ---------------------------------------------------------------- colisao de nome: nunca sobrescreve
cat > "$test_root/bin/date" <<'MOCK'
#!/usr/bin/env bash
if [[ -n ${MOCK_DATE_STAMP:-} && "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then
    printf '%s\n' "$MOCK_DATE_STAMP"
else
    PATH=/usr/bin:/bin exec date "$@"
fi
MOCK
chmod +x "$test_root/bin/date"
run_in "$device_a" env MOCK_DATE_STAMP=20300101T000000Z bash "$handoff" handoff --yes --device colide > /dev/null
collision_ref='refs/heads/ia/handoff/colide/20300101T000000Z'
first_sha="$(git -C "$remote" rev-parse "$collision_ref")"
printf 'mais uma edicao\n' >> "$device_a/notes/todo.md"
expect_failure 'colisao de nome' 'Falha ao enviar' '' \
    run_in "$device_a" env MOCK_DATE_STAMP=20300101T000000Z bash "$handoff" handoff --yes --device colide
assert_equal "$(git -C "$remote" rev-parse "$collision_ref")" "$first_sha" 'um handoff existente nunca e sobrescrito'
printf '%s\n' 'PASS an existing handoff branch is never overwritten'

# ---------------------------------------------------------------- identidade e ramos invalidos
git -C "$device_a" config user.email 'outra.pessoa@example.com'
sleep 1
a_handoff handoff --yes --device intruso > /dev/null
git -C "$device_a" config --unset user.email

device_d="$test_root/device-d"
git clone -q "$remote" "$device_d"
if out="$(run_in "$device_d" bash "$handoff" continuar --latest --yes 2>&1)"; then
    die 'handoff de outra identidade foi aceito'
fi
assert_contains "$out" 'outra identidade' 'protege contra autor diferente'
assert_equal "$(git -C "$device_d" branch --list 'ia/continuar/*')" '' 'nada foi restaurado'
run_in "$device_d" bash "$handoff" continuar --latest --yes --allow-other-author > /dev/null
assert_contains "$(git -C "$device_d" symbolic-ref --short HEAD)" intruso 'continua com autorizacao explicita'

git -C "$device_a" push -q origin HEAD:refs/heads/ia/handoff/falso/20200101T000000Z
git -C "$device_a" push -q origin HEAD:refs/heads/ia/handoff/NOME_INVALIDO/x
good_tip="$(git -C "$remote" rev-parse "refs/heads/ia/handoff/tablet/$(git -C "$remote" for-each-ref --format='%(refname)' refs/heads/ia/handoff/tablet/ | sed 's|.*/||')")"
good_snapshot="$(git -C "$remote" rev-parse "$good_tip^")"
good_note_tree="$(git -C "$remote" rev-parse "$good_tip^{tree}")"
good_snapshot_tree="$(git -C "$remote" rev-parse "$good_snapshot^{tree}")"
craft() { # nome arvore mensagem pais...
    local name="$1" tree="$2" message="$3" commit
    shift 3
    commit="$(printf '%b' "$message" | git -C "$device_a" commit-tree "$tree" "$@")"
    git -C "$device_a" push -q origin "$commit:refs/heads/ia/handoff/$name/20300101T000001Z"
}
note_message='ia handoff\n\nIa-Handoff-Version: 1\nIa-Origin-Branch: main\nIa-Handoff-Role: note\n'
git -C "$device_a" fetch -q origin
craft bad1 "$good_note_tree" "$note_message" -p "$good_snapshot" -p "$(git -C "$device_a" rev-parse HEAD)"
craft bad2 "$good_snapshot_tree" "$note_message" -p "$good_snapshot"
craft bad3 "$good_note_tree" "$note_message" -p "$(git -C "$device_a" rev-parse HEAD)"
craft bad4 "$good_note_tree" 'ia handoff\n\nIa-Handoff-Version: 2\nIa-Origin-Branch: main\nIa-Handoff-Role: note\n' -p "$good_snapshot"
craft bad5 "$good_note_tree" 'ia handoff\n\nIa-Handoff-Version: 1\nIa-Origin-Branch: main\nIa-Handoff-Role: snapshot\n' -p "$good_snapshot"
git -C "$device_a" push -q origin "$good_tip:refs/heads/ia/handoff/bad_6/20300101T000002Z"
git -C "$device_a" push -q origin "$good_tip:refs/heads/ia/handoff/bad7/2030-01-01"
device_e="$test_root/device-e"
git clone -q "$remote" "$device_e"
out="$(run_in "$device_e" bash "$handoff" continuar --list)"
assert_not_contains "$out" falso 'commit comum sob ia/handoff nao e um handoff'
assert_not_contains "$out" INVALIDO 'nome invalido e ignorado'
assert_contains "$out" tablet 'handoffs validos continuam listados'
assert_not_contains "$out" bad 'cada checagem estrutural rejeita handoffs forjados'

device_f="$test_root/device-f"
remote_empty="$test_root/remote-empty.git"
git init -q --bare "$remote_empty"
git -C "$device_a" push -q "$remote_empty" main
git clone -q "$remote_empty" "$device_f"
if out="$(run_in "$device_f" bash "$handoff" continuar --latest --yes 2>&1)"; then die 'continuar sem handoff foi aceito'; fi
assert_contains "$out" 'Nenhum handoff valido' 'sem handoffs'

intruso_ref="$(git -C "$remote" for-each-ref --format='%(refname)' refs/heads/ia/handoff/intruso/)"
device_j="$test_root/device-j"
git clone -q "$remote" "$device_j"
git -C "$device_j" branch "ia/continuar/${intruso_ref#refs/heads/ia/handoff/}"
if out="$(run_in "$device_j" bash "$handoff" continuar --latest --yes --allow-other-author 2>&1)"; then
    die 'branch local existente foi sobrescrito'
fi
assert_contains "$out" 'ja existe' 'nao sobrescreve um branch local'

printf 'edicao pendente\n' >> "$device_e/app.txt"
if out="$(run_in "$device_e" bash "$handoff" continuar --latest --yes 2>&1)"; then die 'retomada sobre alteracoes pendentes'; fi
assert_contains "$out" 'alteracoes nao confirmadas' 'protege alteracoes pendentes'
assert_equal "$(git -C "$device_e" branch --list 'ia/continuar/*')" '' 'nenhum branch criado'
printf '%s\n' 'PASS foreign authors, malformed handoff branches and empty remotes are rejected'

# ---------------------------------------------------------------- repositorio hostil
hostile_remote="$test_root/hostile.git"
device_h="$test_root/device-h"
git init -q --bare "$hostile_remote"
git init -q "$device_h"
(
    cd "$device_h"
    printf 'OLD_PUBLIC_VALUE\n' > .env
    printf 'obsoleto\n' > velho.txt
    printf 'base\n' > base.txt
    git add .env velho.txt base.txt
    git commit -q -m inicial
    git remote add origin https://github.com/acme/hostile.git
    git config "url.$hostile_remote.insteadOf" https://github.com/acme/hostile.git
    git push -q origin main
    printf 'NEW_SECRET_VALUE\n' > .env
    rm velho.txt
    printf 'x\n' > $'ruim\nnome\e[31m.txt'
    printf 'y\n' > 'acentuacao cafe.txt'
    printf 'TOPSECRET_TARGET\n' > "$test_root/alvo-secreto"
    ln -s "$test_root/alvo-secreto" atalho
    mkdir -p vendor/lib ignorada
    git init -q vendor/lib
    git -C vendor/lib commit -q --allow-empty -m interno
    printf 'ignorada/\n' > .gitignore
    printf 'chave = %s\n' "$fake_aws_key" > ignorada/segredo.txt
    git checkout -q --detach
)
out="$(run_in "$device_h" bash "$handoff" handoff --yes --device hostil 2>&1)"
hostile_ref="$(git -C "$hostile_remote" for-each-ref --format='%(refname)' refs/heads/ia/handoff/hostil/)"
[[ -n $hostile_ref ]] || die 'handoff hostil nao foi enviado'
hostile_tree="$(git -C "$hostile_remote" ls-tree -r "$hostile_ref")"
assert_equal "$(git -C "$hostile_remote" show "$hostile_ref:.env")" OLD_PUBLIC_VALUE '.env rastreado nunca envia o valor novo'
if git -C "$hostile_remote" grep -q -e NEW_SECRET_VALUE -e TOPSECRET_TARGET -e "$fake_aws_key" "$hostile_ref"; then
    die 'valor sensivel chegou ao remoto'
fi
assert_not_contains "$hostile_tree" 'segredo.txt' 'arquivo ignorado nao e enviado'
assert_not_contains "$hostile_tree" '160000' 'repositorio aninhado nao e enviado'
assert_contains "$out" 'repositorio aninhado' 'avisa sobre o repositorio aninhado'
assert_contains "$hostile_tree" 'acentuacao cafe.txt' 'nome com espacos e acentos'
hostile_note="$(git -C "$hostile_remote" show "$hostile_ref:.ia/HANDOFF.md")"
if grep -q $'\e' <<< "$hostile_note"; then die 'sequencia de escape na nota'; fi
assert_contains "$hostile_note" 'Branch de origem: (detached)' 'HEAD destacado'
assert_equal "$(grep -c '^A ruim' <<< "$hostile_note")" 1 'nome com quebra de linha vira uma unica linha'
device_i="$test_root/device-i"
git clone -q "$hostile_remote" "$device_i"
run_in "$device_i" bash "$handoff" continuar --latest --yes > /dev/null
assert_contains "$(git -C "$device_i" status --porcelain)" ' D velho.txt' 'remocao restaurada'
assert_equal "$(< "$device_i/.env")" OLD_PUBLIC_VALUE 'o outro aparelho nunca recebe o .env novo'
printf '%s\n' 'PASS hostile repository: control characters, symlinks, nested repositories, tracked secrets and detached HEAD'

many="$test_root/many"
git init -q "$many"
(
    cd "$many"
    git commit -q --allow-empty -m inicial
    git remote add origin https://github.com/acme/many.git
    mkdir lote
    for (( i = 0; i < 2001; i++ )); do printf '%d\n' "$i" > "lote/f$i.txt"; done
)
if out="$(run_in "$many" bash "$handoff" handoff --yes 2>&1)"; then die 'excesso de arquivos aceito'; fi
assert_contains "$out" 'Mais de 2000 arquivos' 'limite de arquivos'
printf '%s\n' 'PASS file-count limit'

for relative_path in scripts/handoff.sh tests/handoff.sh; do
    bash -n "$project_root/$relative_path"
done
printf '%s\n' 'PASS handoff test suite'
