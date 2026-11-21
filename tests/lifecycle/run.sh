#!/usr/bin/env bash
# Takes a host repo in create mode (`# gazelle:generation_mode create_and_update`, package
# mode) through a folder's life: added, renamed, deleted, and excluded. After each step it runs
# //:gazelle, then checks that `gazelle.check` and `bazel build //...` pass in the host repo and
# that its targets and labels are what the step should leave.
#
#   bazel run //tests/lifecycle:run                          # all steps
#   bazel run //tests/lifecycle:run -- /tmp/lifecycle        # keep the repo and logs there
#
# The golden cases pin the BUILD files each step writes; this proves Bazel accepts them.

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---
runfiles_export_envvars
set +e

# From the BUILD file's env, so this also runs as @gazelle_bash//tests/lifecycle:run.
gazelle="$(rlocation "$GAZELLE")"
check="$(rlocation "$CHECK")"
axl="$(rlocation "$AXL")"
module="$(rlocation "$MODULE")"
work="${1:-$(mktemp -d)}"
mkdir -p "$work"

repo="$work/repo"
log="$work/log"
rm -rf "$repo"
mkdir -p "$repo"
cd "$repo" || exit 2
git init -q
git config user.email lifecycle@example.invalid
git config user.name lifecycle
grep -E 'name = "(rules_shell|bazel_lib)"' "$module" >MODULE.bazel
# The Bazel that runs this one.
[[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" && -f "$BUILD_WORKSPACE_DIRECTORY/.bazelversion" ]] &&
    cp "$BUILD_WORKSPACE_DIRECTORY/.bazelversion" .bazelversion
cp "$axl" shell.axl
cat >BUILD.bazel <<'EOF'
# gazelle:generation_mode create_and_update
# gazelle:bash_generation_mode package
# gazelle:bash_root_vars REPO=.
# gazelle:bash_data_files **/*.txt
# gazelle:exclude vendor
EOF
trap 'cd "$repo" && bazel shutdown >/dev/null 2>&1' EXIT

failed=0
problems=()
problem() { problems+=("$1"); }

# regenerate: runs //:gazelle, then both checks.
regenerate() {
    BUILD_WORKSPACE_DIRECTORY="$repo" "$gazelle" >"$log" 2>&1 ||
        problem "gazelle failed with exit code $?: $(tail -3 "$log")"
    BUILD_WORKSPACE_DIRECTORY="$repo" "$check" >"$log.check" 2>&1 ||
        problem "gazelle.check failed with exit code $?: $(tail -5 "$log.check")"    bazel build //... >"$log.build" 2>&1 || problem "bazel build //... failed: $(grep -m3 ERROR "$log.build")"
}

# The rules of a kind in a package, one label per line.
rules() { bazel query --output=label "kind($1, $2)" 2>/dev/null | sort; }
# Every label in the data of the rules under //..., one per line.
data_labels() { bazel query --output=label 'labels(data, //...)' 2>/dev/null | sort -u; }

want_build() { [[ -f "$1/BUILD.bazel" ]] || problem "$1 has no BUILD file"; }
want_no_build() { [[ ! -e "$1/BUILD.bazel" ]] || problem "$1 has a BUILD file: $(head -3 "$1/BUILD.bazel")"; }
want_eq() { [[ "$2" == "$3" ]] || problem "$1: got [$(echo $2)], want [$(echo $3)]"; }
want_label() { data_labels | grep -qxF "$1" || problem "no rule depends on $1"; }
want_no_label() {
    local left
    left="$(data_labels | grep -E "^$1(:|$)")"
    [[ -z "$left" ]] || problem "labels still point at $1: $(echo $left)"
}

report() {
    if [[ ${#problems[@]} -eq 0 ]]; then
        echo "PASS $1"
    else
        failed=1
        echo "FAIL $1"
        printf '  %s\n' "${problems[@]}"
    fi
    problems=()
    git add -A && git commit -qm "$1" >/dev/null || true
}

# --- A new folder with a script gets a BUILD file -------------------------------------------
mkdir -p lib app vendor
printf 'log() { cat "$(dirname "${BASH_SOURCE[0]}")/notes.txt"; }\n# gazelle-bash: dep notes.txt\n' >lib/log.sh
printf 'notes\n' >lib/notes.txt
printf 'setup() {\n    source "$BATS_TEST_DIRNAME/log.sh"\n}\n\n@test "logs" {\n    log\n}\n' >lib/lib.bats
printf 'source "$(dirname "${BASH_SOURCE[0]}")/../lib/log.sh"\n' >app/run.sh
printf 'source "$(dirname "$0")/run.sh"\ncat "$REPO/lib/notes.txt"\n' >app/run_test.sh
printf 'source ./not_checked_out.sh\n' >vendor/tool.sh
chmod +x app/run_test.sh
regenerate
want_build lib
want_build app
want_eq "libraries in //lib" "$(rules sh_library //lib:all)" "//lib:lib"
want_eq "filegroups in //lib" "$(rules filegroup //lib:all)" "//lib:lib_files"
want_label //lib:lib
want_label //lib:lib_files
report "a new folder with a script gets a BUILD file"

# --- An excluded folder gets no BUILD file ---------------------------------------------------
want_no_build vendor
report "an excluded folder gets no BUILD file"

# --- A renamed folder's targets and the labels pointing at them follow the new name ---------
git mv lib util
printf 'source "$(dirname "${BASH_SOURCE[0]}")/../util/log.sh"\n' >app/run.sh
printf 'source "$(dirname "$0")/run.sh"\ncat "$REPO/util/notes.txt"\n' >app/run_test.sh
regenerate
want_eq "libraries in //util" "$(rules sh_library //util:all)" "//util:util"
want_eq "filegroups in //util" "$(rules filegroup //util:all)" "//util:util_files"
want_eq "tests in //util" "$(rules bats_test //util:all)" "//util:lib"
want_label //util:util
want_label //util:util_files
want_no_label //lib
report "a renamed folder's targets and labels follow the new name"

# --- A deleted folder leaves no BUILD file or label behind ----------------------------------
# Its files go one by one; its BUILD file is all that is left of it.
rm util/log.sh util/notes.txt util/lib.bats
printf 'echo run\n' >app/run.sh
regenerate
want_no_build util
want_no_label //util
want_eq "packages" "$(bazel query --output=package //... 2>/dev/null | sort | paste -sd' ' -)" "app"
report "a deleted folder leaves no BUILD file or label behind"

echo "repo and logs: $work"
exit $failed
