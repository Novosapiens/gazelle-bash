#!/usr/bin/env bash
# Runs the plugin on real open-source shell projects, pinned in projects.txt, and checks each
# gives the recorded result. The projects' code is only read, never run.
#
#   tests/corpus/run.sh                  # all projects
#   tests/corpus/run.sh dokku/dokku      # some projects
#   CORPUS_ANALYSE=0 tests/corpus/run.sh # skip the Bazel analysis of generated targets (faster)
#   CORPUS_DIR=/tmp/corpus tests/corpus/run.sh   # keep the checkouts and logs there
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${CORPUS_DIR:-$(mktemp -d)}"
analyse="${CORPUS_ANALYSE:-1}"
mkdir -p "$work"

(cd "$root" && bazel build //:gazelle) || exit 2
gazelle="$root/bazel-bin/gazelle.sh"

wanted() {
    [[ $# -eq 1 ]] && return 0
    local repo="$1" arg
    shift
    for arg in "$@"; do [[ "$arg" == "$repo" ]] && return 0; done
    return 1
}

failed=0
fail() {
    failed=1
    echo "FAIL $1: $2"
    [[ -n "${3:-}" ]] && grep -iE 'error' "$3" | head -5 | cut -c1-300 | sed 's/^/     /'
}

while IFS='|' read -r repo sha expect; do
    case "$repo" in '' | '#'*) continue ;; esac
    wanted "$repo" "$@" || continue
    name="${repo//\//_}"
    dir="$work/$name"
    log="$work/$name.log"
    rm -rf "$dir"
    mkdir -p "$dir"
    if ! (cd "$dir" && git init -q && git fetch -q --depth 1 "https://github.com/$repo.git" "$sha" && git checkout -q FETCH_HEAD); then
        fail "$repo" "cannot fetch $sha"
        continue
    fi
    rm -rf "$dir/.git"
    # The project's own Bazel files would change what gazelle does.
    find "$dir" \( -name BUILD -o -name BUILD.bazel -o -name 'WORKSPACE*' -o -name MODULE.bazel \) -type f -delete
    # Orion stops on a symlink to a directory. A host repo excludes those with `# gazelle:exclude`.
    find "$dir" -type l | while IFS= read -r link; do
        if [[ -d "$link" ]]; then rm "$link"; fi
    done
    : > "$dir/MODULE.bazel"
    cp "$root/shell.axl" "$dir/shell.axl"

    (cd "$dir" && BUILD_WORKSPACE_DIRECTORY="$dir" "$gazelle" > "$log" 2>&1)
    code=$?

    if [[ "$expect" == ok ]]; then
        if [[ $code -ne 0 ]]; then
            fail "$repo" "generation failed, expected it to succeed" "$log"
            continue
        fi
        if [[ "$analyse" == 1 ]]; then
            grep -E 'name = "(rules_shell|bazel_lib)"' "$root/MODULE.bazel" > "$dir/MODULE.bazel"
            cp "$root/.bazelversion" "$dir/.bazelversion"
            if ! (cd "$dir" && bazel build --nobuild --keep_going //... > "$log.analysis" 2>&1); then
                (cd "$dir" && bazel shutdown > /dev/null 2>&1)
                fail "$repo" "Bazel cannot analyse the generated targets" "$log.analysis"
                continue
            fi
            (cd "$dir" && bazel shutdown > /dev/null 2>&1)
        fi
        echo "PASS $repo ($(find "$dir" -name BUILD.bazel | wc -l | tr -d ' ') BUILD files, $(grep -c 'skipped' "$log") skipped lines)"
    else
        text="${expect#fail:}"
        if [[ $code -eq 0 ]]; then
            fail "$repo" "generation now succeeds; set it to ok in projects.txt"
        elif ! grep -qF -- "$text" "$log"; then
            fail "$repo" "generation fails, but not with: $text" "$log"
        else
            echo "PASS $repo (stops as recorded: $text)"
        fi
    fi
done < "$here/projects.txt"

echo "logs: $work"
exit $failed
