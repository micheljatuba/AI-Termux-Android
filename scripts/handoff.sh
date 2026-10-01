#!/usr/bin/env bash
# Handoff seguro entre aparelhos (experimental).
#
#   ia handoff    envia o trabalho em andamento para um branch dedicado do seu
#                 repositorio PRIVADO (ia/handoff/<aparelho>/<data>).
#   ia continuar  retoma esse trabalho em outro aparelho, no mesmo repositorio.
#
# Principios de seguranca:
#   - o envio nunca altera seu branch, seu indice nem seus arquivos: os commits
#     sao montados com comandos de baixo nivel em um indice temporario, sem hooks
#     de commit (o git push final e normal: um hook pre-push seu, se houver, roda);
#   - so envia se o repositorio for confirmado como privado;
#   - arquivos de credenciais sao excluidos e segredos conhecidos abortam o envio;
#   - nunca usa force-push e so escreve em refs/heads/ia/handoff/*;
#   - a nota gerada e dado, nao instrucao.
set -euo pipefail

export GIT_LITERAL_PATHSPECS=1
export GIT_TERMINAL_PROMPT=0

readonly handoff_prefix='ia/handoff'
readonly handoff_version=1
readonly max_file_bytes=$((5 * 1024 * 1024))
readonly max_scan_bytes=$((20 * 1024 * 1024))
readonly max_files=2000

secret_rules=(
    'chave privada|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'token GitHub|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}'
    'chave Anthropic/OpenAI|(^|[^A-Za-z0-9])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}'
    'chave AWS|(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}'
    'chave Google|AIza[0-9A-Za-z_-]{35}'
    'token Slack|xox[abprs]-[A-Za-z0-9-]{10,}'
    'token npm/GitLab|npm_[A-Za-z0-9]{36}|glpat-[A-Za-z0-9_-]{20,}'
    'JWT|eyJ[A-Za-z0-9_-]{10,}[.]eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}'
    'credencial em URL|[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@'
)
secret_rules_ci=(
    $'atribuicao de segredo|(api[_-]?key|secret|token|passw(or)?d|senha)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*["\'][A-Za-z0-9/+_=.-]{20,}["\']'
)

show_help() {
    printf '%s\n' \
        'Uso: ia handoff [--yes] [--dry-run] [--note TEXTO] [--device NOME] [--allow-unverified-remote]' \
        '     ia continuar [--yes] [--list] [--latest] [--allow-other-author]' \
        '' \
        'handoff   Envia seu trabalho em andamento para um branch dedicado do repositorio privado.' \
        '          Seu branch, indice e arquivos nao sao alterados.' \
        'continuar Retoma o ultimo handoff em outro aparelho, no mesmo repositorio, como alteracoes' \
        '          nao confirmadas em um novo branch local. A nota fica em .ia/HANDOFF.md.' \
        '' \
        'Experimental: ainda nao validado em Android/PRoot. Exige git e, para confirmar que o' \
        'repositorio e privado, o GitHub CLI autenticado (gh auth login).'
}

fail() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'Aviso: %s\n' "$*" >&2
}

# Remove caracteres de controle e crases, que quebrariam a nota ou o terminal.
sanitize() {
    local text
    text="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177`')"
    printf '%s' "${text:0:${2:-160}}"
}

is_sensitive_path() {
    local path="$1" lower
    lower="${path##*/}"
    lower="${lower,,}"
    case "/$path/" in
        */.ssh/*|*/.aws/*|*/.gnupg/*|*/.claude/*|*/.codex/*|*/.copilot/*|*/.gemini/*|*/.config/gh/*|*/.local/share/opencode/*|*/.ia/*|*/node_modules/*)
            return 0 ;;
    esac
    case "$lower" in
        .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*) return 0 ;;
        .netrc|_netrc|.git-credentials|.npmrc|.pypirc|.pgpass|.htpasswd|credentials|credentials.json|auth.json) return 0 ;;
        secrets.json|secrets.yml|secrets.yaml|service-account*.json|*.sqlite|*.sqlite3|*.db) return 0 ;;
    esac
    return 1
}

combine_rules() {
    local rule
    local -a parts=()
    for rule in "$@"; do
        parts+=("(${rule#*|})")
    done
    local IFS='|'
    printf '%s' "${parts[*]}"
}

# Procura segredos conhecidos em um arquivo. Imprime so o rotulo, a regra e as
# linhas, nunca o valor encontrado. Retorna 1 se houver ocorrencias.
scan_file() {
    local file="$1" label="$2" rule name regex lines found=0
    local combined_cs combined_ci
    combined_cs="$(combine_rules "${secret_rules[@]}")"
    combined_ci="$(combine_rules "${secret_rules_ci[@]}")"
    if ! grep -qaE -e "$combined_cs" -- "$file" && ! grep -qaiE -e "$combined_ci" -- "$file"; then
        return 0
    fi
    for rule in "${secret_rules[@]}"; do
        name="${rule%%|*}"
        regex="${rule#*|}"
        if grep -qaE -e "$regex" -- "$file"; then
            lines="$(grep -anE -e "$regex" -- "$file" | cut -d: -f1 | head -n 5 | paste -sd, - || true)"
            printf '  - %s: %s (linha %s)\n' "$(sanitize "$label")" "$name" "$lines" >&2
            found=1
        fi
    done
    for rule in "${secret_rules_ci[@]}"; do
        name="${rule%%|*}"
        regex="${rule#*|}"
        if grep -qaiE -e "$regex" -- "$file"; then
            lines="$(grep -aniE -e "$regex" -- "$file" | cut -d: -f1 | head -n 5 | paste -sd, - || true)"
            printf '  - %s: %s (linha %s)\n' "$(sanitize "$label")" "$name" "$lines" >&2
            found=1
        fi
    done
    (( found == 0 ))
}

device_name() {
    local raw="${1:-${IA_DEVICE_NAME:-}}" name
    if [[ -z $raw ]]; then
        raw="$(hostname 2>/dev/null || true)"
    fi
    name="$(printf '%s' "${raw,,}" | LC_ALL=C tr -c 'a-z0-9\n' '-' | sed -e 's/^-*//' -e 's/-*$//')"
    name="${name:0:24}"
    name="${name%-}"
    case "$name" in
        ''|localhost) name=aparelho ;;
    esac
    printf '%s' "$name"
}

# A identidade git e necessaria para o handoff: ela protege contra retomar, por
# engano, o trabalho de outra pessoa em um repositorio compartilhado.
require_identity() {
    [[ -n "$(git config user.email || true)" && -n "$(git config user.name || true)" ]] \
        || fail 'Configure sua identidade git: git config --global user.name "Seu Nome" e git config --global user.email "voce@exemplo.com"'
}

require_repo() {
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'Execute dentro de um repositorio git.'
    cd -- "$top"
    git rev-parse --verify -q HEAD >/dev/null || fail 'O repositorio ainda nao tem nenhum commit.'
    git config --get remote.origin.url >/dev/null || fail 'O repositorio nao tem o remoto origin.'
    local gitdir name
    gitdir="$(git rev-parse --absolute-git-dir)"
    for name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
        if [[ -e "$gitdir/$name" ]]; then
            fail "Ha uma operacao git em andamento ($name). Conclua ou cancele antes de continuar."
        fi
    done
}

# O git envia para TODAS as URLs de push e aplica pushurl/pushInsteadOf. A checagem
# de visibilidade so vale se o destino real for exatamente a URL verificada.
assert_single_push_target() {
    local -a urls=() pushurls=()
    mapfile -t urls < <(git config --get-all remote.origin.url)
    (( ${#urls[@]} == 1 )) \
        || fail 'O remoto origin tem mais de uma URL e o git enviaria para todas. Deixe apenas uma.'
    if git config --get-regexp '^url\..*\.pushinsteadof$' > /dev/null 2>&1; then
        fail 'Ha regras pushInsteadOf no git; elas podem redirecionar o envio. Remova-as para usar o handoff.'
    fi
    mapfile -t pushurls < <(git config --get-all remote.origin.pushurl || true)
    if (( ${#pushurls[@]} > 0 )); then
        [[ ${#pushurls[@]} -eq 1 && ${pushurls[0]} == "${urls[0]}" ]] \
            || fail 'O remoto origin tem um pushurl diferente da url; o handoff nao envia para destinos nao verificados.'
    fi
}

# Aceita somente remotos github.com sem credenciais embutidas.
remote_slug() {
    local url path
    url="$(git config --get remote.origin.url)"
    case "$url" in
        https://github.com/*) path="${url#https://github.com/}" ;;
        git@github.com:*) path="${url#git@github.com:}" ;;
        ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    path="${path%/}"
    path="${path%.git}"
    [[ $path =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s' "$path"
}

confirm_private_remote() {
    local allow_unverified="$1" slug private
    if slug="$(remote_slug)"; then
        remote_label="$slug"
    else
        remote_label='(remoto fora do GitHub ou com credenciais na URL)'
    fi
    if (( allow_unverified )); then
        warn 'Visibilidade do remoto NAO verificada, a pedido (--allow-unverified-remote).'
        remote_status='visibilidade nao verificada'
        return 0
    fi
    [[ -n ${slug:-} ]] || fail 'Nao consigo confirmar que o remoto e privado: use um remoto github.com sem credenciais na URL.'
    command -v gh >/dev/null 2>&1 || fail 'Instale/use o GitHub CLI (gh) para confirmar que o repositorio e privado.'
    gh auth status >/dev/null 2>&1 || fail 'Conecte o GitHub CLI antes: gh auth login'
    private="$(timeout 60 gh repo view "$slug" --json isPrivate --jq .isPrivate 2>/dev/null || true)"
    case "$private" in
        true) remote_status='privado confirmado' ;;
        false) fail "O repositorio $slug e publico. O handoff so envia para repositorios privados." ;;
        *) fail "Nao foi possivel confirmar a visibilidade de $slug. Nada foi enviado." ;;
    esac
}

fill_staged_entries() {
    mapfile -d '' -t staged_entries < <(git diff --cached --raw -z --no-renames HEAD)
}

stage_snapshot() {
    local i meta path newmode status
    [[ -f $GIT_INDEX_FILE ]] || git read-tree HEAD
    git add -A
    excluded=()
    fill_staged_entries
    for (( i = 0; i + 1 < ${#staged_entries[@]}; i += 2 )); do
        meta="${staged_entries[i]}"
        path="${staged_entries[i + 1]}"
        read -r _ _ _ _ status <<< "$meta"
        read -r _ newmode _ _ _ <<< "$meta"
        if is_sensitive_path "$path"; then
            excluded+=("$path")
            git reset -q HEAD -- "$path"
        elif [[ $newmode == 160000 && $status != D ]]; then
            excluded+=("$path (repositorio aninhado)")
            git reset -q HEAD -- "$path"
        fi
    done
    fill_staged_entries
    for (( i = 0; i + 1 < ${#staged_entries[@]}; i += 2 )); do
        if is_sensitive_path "${staged_entries[i + 1]}"; then
            fail 'Falha interna: um arquivo sensivel continuou na lista de envio. Nada foi enviado.'
        fi
    done
}

scan_snapshot() {
    local i meta path newmode newsha status size problems=0 count_a=0 count_m=0 count_d=0
    local blob="$work/blob"
    changed_summary=()
    (( ${#staged_entries[@]} / 2 <= max_files )) \
        || fail "Mais de $max_files arquivos alterados. Adicione pastas geradas ao .gitignore e tente de novo."
    for (( i = 0; i + 1 < ${#staged_entries[@]}; i += 2 )); do
        meta="${staged_entries[i]}"
        path="${staged_entries[i + 1]}"
        read -r _ newmode _ newsha status <<< "$meta"
        changed_summary+=("$status $(sanitize "$path" 200)")
        case "$status" in
            A) count_a=$((count_a + 1)) ;;
            D) count_d=$((count_d + 1)); continue ;;
            *) count_m=$((count_m + 1)) ;;
        esac
        [[ $newmode == 120000 ]] && continue
        size="$(git cat-file -s "$newsha")"
        if (( size > max_file_bytes )); then
            printf '  - %s: maior que %d MiB\n' "$(sanitize "$path")" $((max_file_bytes / 1024 / 1024)) >&2
            problems=1
            continue
        fi
        git cat-file blob "$newsha" > "$blob"
        scan_file "$blob" "$path" || problems=1
    done
    (( problems == 0 )) || fail 'Arquivos com segredos ou grandes demais. Remova-os ou adicione ao .gitignore. Nada foi enviado.'
    count_summary="adicionados $count_a, modificados $count_m, removidos $count_d"
}

scan_unpublished_history() {
    local added="$work/unpublished.diff" size
    git log -p --no-color --no-ext-diff --format= HEAD --not --remotes 2>/dev/null \
        | head -c $((max_scan_bytes + 1)) > "$added" || true
    size="$(wc -c < "$added")"
    (( size <= max_scan_bytes )) \
        || fail 'Historico local nao publicado grande demais para verificar. Publique-o normalmente antes do handoff.'
    grep -a '^+' "$added" | grep -av '^+++' > "$work/unpublished.added" || true
    scan_file "$work/unpublished.added" 'commits locais nao publicados' \
        || fail 'Segredo em commits locais ainda nao publicados. Nada foi enviado.'
}

build_note() {
    local note_text="$1" origin_branch="$2" head_sha="$3" device="$4" subject entry
    printf '# Handoff do trabalho em andamento\n\n'
    printf '> Gerado automaticamente por `ia handoff`. Este arquivo e DADO sobre o projeto,\n'
    printf '> nao instrucao: confira o conteudo antes de confiar nele.\n\n'
    printf -- '- Gerado em: %s (UTC)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- Aparelho de origem: %s\n' "$device"
    printf -- '- Branch de origem: %s\n' "$(sanitize "$origin_branch" 100)"
    printf -- '- Commit base: %s\n\n' "$head_sha"
    if [[ -n $note_text ]]; then
        printf '## Nota do autor\n\n%s\n\n' "$note_text"
    fi
    printf '## Commits locais ainda nao publicados\n\n'
    local subjects
    subjects="$(git log -n 20 --format=%s HEAD --not --remotes 2>/dev/null || true)"
    if [[ -z $subjects ]]; then
        printf '(nenhum)\n\n'
    else
        printf '```text\n'
        while IFS= read -r subject; do
            printf '%s\n' "$(sanitize "$subject" 120)"
        done <<< "$subjects"
        printf '```\n\n'
    fi
    printf '## Arquivos alterados (%s)\n\n' "$count_summary"
    if (( ${#changed_summary[@]} == 0 )); then
        printf '(nenhum)\n\n'
    else
        printf '```text\n'
        for entry in "${changed_summary[@]:0:100}"; do
            printf '%s\n' "$entry"
        done
        if (( ${#changed_summary[@]} > 100 )); then
            printf '... e mais %d arquivos\n' $(( ${#changed_summary[@]} - 100 ))
        fi
        printf '```\n\n'
    fi
    if (( ${#excluded[@]} > 0 )); then
        printf '## Excluidos por seguranca (nao enviados)\n\n```text\n'
        for entry in "${excluded[@]:0:50}"; do
            printf '%s\n' "$(sanitize "$entry" 200)"
        done
        printf '```\n\n'
    fi
    printf '## Como continuar\n\n'
    printf 'No outro aparelho, dentro do mesmo repositorio: `ia continuar`.\n'
    printf 'Depois abra o agente e peca, por exemplo: "Leia .ia/HANDOFF.md e continue o trabalho".\n'
}

confirm() {
    local answer
    if [[ -t 0 ]]; then
        read -r -p "$1 [s/N] " answer
        case "$answer" in
            s|S|sim|SIM|y|Y|yes) return 0 ;;
        esac
        return 1
    fi
    fail 'Sem entrada interativa. Revise a previa e use --yes para confirmar.'
}

cmd_handoff() {
    local assume_yes=0 dry_run=0 allow_unverified=0 note_text='' device_arg=''
    while (( $# > 0 )); do
        case "$1" in
            --yes) assume_yes=1 ;;
            --dry-run) dry_run=1 ;;
            --allow-unverified-remote) allow_unverified=1 ;;
            --note) (( $# >= 2 )) || fail '--note exige um texto.'; note_text="$2"; shift ;;
            --device) (( $# >= 2 )) || fail '--device exige um nome.'; device_arg="$2"; shift ;;
            --help|-h) show_help; return 0 ;;
            *) fail "Opcao desconhecida: $(sanitize "$1" 40). Use --help." ;;
        esac
        shift
    done
    note_text="$(sanitize "$note_text" 500)"

    require_repo
    require_identity
    assert_single_push_target
    local head_sha origin_branch device stamp branch_ref
    head_sha="$(git rev-parse --verify HEAD)"
    origin_branch="$(git symbolic-ref -q --short HEAD || printf '(detached)')"
    device="$(device_name "$device_arg")"

    umask 077
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    remote_label=''
    remote_status=''
    confirm_private_remote "$allow_unverified"

    local real_index
    real_index="$(git rev-parse --absolute-git-dir)/index"
    # Trabalha numa copia do indice: o indice real nunca e escrito.
    if [[ -f $real_index ]]; then
        cp -- "$real_index" "$work/index"
    fi
    export GIT_INDEX_FILE="$work/index"
    local staged_entries=() excluded=() changed_summary=() count_summary=''
    stage_snapshot
    scan_snapshot
    scan_unpublished_history

    local note_file="$work/HANDOFF.md"
    build_note "$note_text" "$origin_branch" "$head_sha" "$device" > "$note_file"
    scan_file "$note_file" 'nota do handoff' || fail 'A nota contem um segredo. Nada foi enviado.'

    local author_name author_email
    author_name="$(git config user.name)"
    author_email="$(git config user.email)"
    export GIT_AUTHOR_NAME="$author_name" GIT_COMMITTER_NAME="$author_name"
    export GIT_AUTHOR_EMAIL="$author_email" GIT_COMMITTER_EMAIL="$author_email"

    local tree_snapshot snapshot_commit blob tree_note note_commit trailers
    tree_snapshot="$(git write-tree)"
    trailers="Ia-Handoff-Version: $handoff_version"$'\n'"Ia-Origin-Branch: $(sanitize "$origin_branch" 100)"
    snapshot_commit="$(printf '%s\n\n%s\nIa-Handoff-Role: snapshot\n' 'ia handoff: snapshot do trabalho em andamento' "$trailers" \
        | git commit-tree "$tree_snapshot" -p "$head_sha")"
    blob="$(git hash-object -w --stdin < "$note_file")"
    git update-index --add --cacheinfo "100644,$blob,.ia/HANDOFF.md"
    tree_note="$(git write-tree)"
    note_commit="$(printf '%s\n\n%s\nIa-Handoff-Role: note\n' 'ia handoff: nota de continuidade' "$trailers" \
        | git commit-tree "$tree_note" -p "$snapshot_commit")"
    unset GIT_INDEX_FILE

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    branch_ref="refs/heads/$handoff_prefix/$device/$stamp"

    printf '\nRemoto: %s (%s)\n' "$remote_label" "$remote_status"
    printf 'Branch de destino: %s\n' "${branch_ref#refs/heads/}"
    printf 'Seu branch, indice e arquivos NAO serao alterados.\n'
    printf 'Arquivos no envio: %s\n' "$count_summary"
    printf 'Commits locais ainda nao publicados: %s\n' "$(git rev-list --count HEAD --not --remotes 2>/dev/null || printf '?')"
    if (( ${#excluded[@]} > 0 )); then
        printf 'Excluidos por seguranca (nao enviados):\n'
        local entry
        for entry in "${excluded[@]:0:20}"; do
            printf '  - %s\n' "$(sanitize "$entry" 200)"
        done
    fi
    if (( dry_run )); then
        printf '\nSimulacao: nada foi enviado.\n'
        return 0
    fi
    if (( ! assume_yes )); then
        confirm 'Enviar este handoff?' || { printf '%s\n' 'Cancelado. Nada foi enviado.'; return 0; }
    fi

    timeout 180 git push --quiet origin "$note_commit:$branch_ref" \
        || fail 'Falha ao enviar. Se for autenticacao, execute gh auth login e tente de novo.'
    local remote_sha
    remote_sha="$(git ls-remote origin "$branch_ref" | cut -f1)"
    [[ $remote_sha == "$note_commit" ]] || fail 'O envio terminou, mas nao consegui confirmar o branch no remoto.'
    printf '\nHandoff enviado: %s\n' "${branch_ref#refs/heads/}"
    printf 'No outro aparelho, dentro do mesmo repositorio, execute: ia continuar\n'
}

validate_handoff() {
    local tip="$1" snapshot message
    [[ "$(git rev-list --parents -n 1 "$tip" | wc -w)" -eq 2 ]] || return 1
    message="$(git log -n 1 --format=%B "$tip")"
    grep -qx "Ia-Handoff-Version: $handoff_version" <<< "$message" || return 1
    grep -qx 'Ia-Handoff-Role: note' <<< "$message" || return 1
    snapshot="$(git rev-parse -q --verify "$tip^")" || return 1
    [[ "$(git rev-list --parents -n 1 "$snapshot" | wc -w)" -eq 2 ]] || return 1
    message="$(git log -n 1 --format=%B "$snapshot")"
    grep -qx 'Ia-Handoff-Role: snapshot' <<< "$message" || return 1
    git rev-parse -q --verify "$snapshot^" >/dev/null || return 1
    git cat-file -e "$tip:.ia/HANDOFF.md" 2>/dev/null
}

cmd_continue() {
    local assume_yes=0 list_only=0 latest=0 allow_other=0
    while (( $# > 0 )); do
        case "$1" in
            --yes) assume_yes=1 ;;
            --list) list_only=1 ;;
            --latest) latest=1 ;;
            --allow-other-author) allow_other=1 ;;
            --help|-h) show_help; return 0 ;;
            *) fail "Opcao desconhecida: $(sanitize "$1" 40). Use --help." ;;
        esac
        shift
    done

    require_repo
    (( list_only )) || require_identity
    if (( ! list_only )) && [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        fail 'Ha alteracoes nao confirmadas neste repositorio. Confirme, guarde ou descarte antes de continuar.'
    fi
    timeout 180 git fetch --quiet --no-tags origin "+refs/heads/$handoff_prefix/*:refs/remotes/origin/$handoff_prefix/*" \
        || fail 'Nao consegui buscar os handoffs. Verifique a conexao e a autenticacao (gh auth login).'

    local ref sha when author suffix origin_branch
    local -a refs=() shas=() labels=() authors=()
    while IFS=$'\t' read -r ref sha when author; do
        suffix="${ref#refs/remotes/origin/$handoff_prefix/}"
        [[ $suffix =~ ^[a-z0-9-]{1,24}/[0-9]{8}T[0-9]{6}Z$ ]] || continue
        validate_handoff "$sha" || continue
        origin_branch="$(git log -n 1 --format=%B "$sha^" | sed -n 's/^Ia-Origin-Branch: //p' | head -n 1)"
        refs+=("$suffix")
        shas+=("$sha")
        authors+=("$author")
        labels+=("$when  ${suffix%%/*}  branch $(sanitize "$origin_branch" 60)  $(sanitize "$author" 60)")
        (( ${#refs[@]} < 10 )) || break
    done < <(git for-each-ref --sort=-committerdate \
        --format='%(refname)%09%(objectname)%09%(committerdate:format:%Y-%m-%d %H:%M)%09%(authoremail)' \
        "refs/remotes/origin/$handoff_prefix/")

    (( ${#refs[@]} > 0 )) || fail 'Nenhum handoff valido encontrado. No outro aparelho, execute: ia handoff'
    local index
    printf 'Handoffs disponiveis (mais recente primeiro):\n'
    for index in "${!refs[@]}"; do
        printf '  %d) %s\n' $((index + 1)) "${labels[index]}"
    done
    (( ! list_only )) || return 0

    local choice=1
    if (( ! latest && ! assume_yes && ${#refs[@]} > 1 )); then
        [[ -t 0 ]] || fail 'Sem entrada interativa. Use --latest para escolher o mais recente.'
        read -r -p "Escolha [1-${#refs[@]}] (Enter = 1): " choice
        choice="${choice:-1}"
        [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#refs[@]} )) || fail 'Opcao invalida.'
    fi
    local pick=$((choice - 1)) tip snapshot base my_email local_branch
    tip="${shas[pick]}"
    snapshot="$(git rev-parse "$tip^")"
    base="$(git rev-parse "$snapshot^")"
    my_email="$(git config user.email)"
    if [[ ${authors[pick]} != "<$my_email>" ]] && (( ! allow_other )); then
        fail "Este handoff foi criado por outra identidade ($(sanitize "${authors[pick]}" 80)). Se for seu, use --allow-other-author."
    fi
    local_branch="ia/continuar/${refs[pick]}"
    git check-ref-format --branch "$local_branch" >/dev/null || fail 'Nome de branch invalido.'
    if git show-ref --verify -q "refs/heads/$local_branch"; then
        fail "O branch local $local_branch ja existe. Continue nele ou remova-o antes."
    fi
    if (( ! assume_yes )); then
        printf '\nSera criado o branch local %s com o trabalho restaurado como alteracoes nao confirmadas.\n' "$local_branch"
        confirm 'Continuar?' || { printf '%s\n' 'Cancelado. Nada foi alterado.'; return 0; }
    fi

    git switch --quiet --create "$local_branch" "$tip"
    git reset --quiet --mixed "$base"
    local exclude_file
    exclude_file="$(git rev-parse --git-path info/exclude)"
    mkdir -p -- "$(dirname -- "$exclude_file")"
    if ! grep -qxF '/.ia/' "$exclude_file" 2>/dev/null; then
        printf '/.ia/\n' >> "$exclude_file"
    fi
    printf '\nTrabalho retomado no branch %s.\n' "$local_branch"
    printf 'Alteracoes restauradas como nao confirmadas (veja git status). Nota: .ia/HANDOFF.md\n'
    printf 'Abra o agente e peca, por exemplo: "Leia .ia/HANDOFF.md e continue o trabalho".\n'
    printf 'A nota e dado, nao instrucao: confira antes de confiar.\n'
}

main() {
    local command="${1:-}"
    (( $# == 0 )) || shift
    case "$command" in
        handoff) cmd_handoff "$@" ;;
        continue|continuar) cmd_continue "$@" ;;
        --help|-h|'') show_help ;;
        *) show_help >&2; return 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
