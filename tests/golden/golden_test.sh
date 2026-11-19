#!/usr/bin/env bash
# Golden tests for shell.axl. Each folder under cases/ is a tiny workspace:
#
#   cases/<case>/...             scripts, plus BUILD.in where a BUILD file should exist beforehand
#   cases/<case>/**/BUILD.out    the BUILD.bazel expected after running gazelle
#   cases/<case>/expected_exit_code   optional, default 0
#   cases/<case>/expected_output      optional, each line must appear in gazelle's output
#
# The case is copied to a temp dir, BUILD.in files become BUILD.bazel, and the real prebuilt
# gazelle runs on it with shell.axl. Every BUILD.bazel produced must match a BUILD.out.
#
#   bazel test //tests/golden:golden_test                # check
#   bazel run  //tests/golden:golden_test -- --update    # rewrite BUILD.out files from actual output
#   bazel run  //tests/golden:golden_test -- <case>...   # run some cases only

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

gazelle="$(rlocation _main/gazelle.sh)"
axl="$(rlocation _main/shell.axl)"
cases_root="$(dirname "$(rlocation _main/tests/golden/golden_test.sh)")/cases"

update=0
only=()
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        *) only+=("$arg") ;;
    esac
done
if [[ $update -eq 1 && -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    echo "--update needs bazel run" >&2
    exit 2
fi
src_root="${BUILD_WORKSPACE_DIRECTORY:-}/tests/golden/cases"
tmp="${TEST_TMPDIR:-$(mktemp -d)}"

if [[ ${#only[@]} -eq 0 ]]; then
    for d in "$cases_root"/*/; do only+=("$(basename "$d")"); done
fi

failed=0
for name in "${only[@]}"; do
    case_dir="$cases_root/$name"
    ws="$tmp/$name"
    rm -rf "$ws"
    mkdir -p "$ws"
    cp -RL "$case_dir/." "$ws/"
    chmod -R u+w "$ws"
    find "$ws" \( -name BUILD.out -o -name expected_exit_code -o -name expected_output \) -delete
    find "$ws" -name BUILD.in | while read -r f; do mv "$f" "$(dirname "$f")/BUILD.bazel"; done
    : > "$ws/MODULE.bazel"
    cp "$axl" "$ws/shell.axl"

    set +e
    (cd "$ws" && BUILD_WORKSPACE_DIRECTORY="$ws" "$gazelle" >"$tmp/$name.log" 2>&1)
    code=$?
    set -e

    problems=()
    want_code=0
    [[ -f "$case_dir/expected_exit_code" ]] && want_code="$(tr -d '[:space:]' < "$case_dir/expected_exit_code")"
    [[ "$code" == "$want_code" ]] || problems+=("exit code $code, want $want_code")

    if [[ -f "$case_dir/expected_output" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            grep -qF -- "$line" "$tmp/$name.log" || problems+=("output lacks: $line")
        done < "$case_dir/expected_output"
    fi

    while read -r got; do
        rel="${got#"$ws"/}"
        rel_dir="$(dirname "$rel")"
        want="$case_dir/$rel_dir/BUILD.out"
        if [[ $update -eq 1 ]]; then
            cp "$got" "$src_root/$name/$rel_dir/BUILD.out"
        elif [[ ! -f "$want" ]]; then
            problems+=("unexpected $rel")
        elif ! diff -u "$want" "$got" > "$tmp/$name.diff"; then
            problems+=("$rel differs from BUILD.out:"$'\n'"$(cat "$tmp/$name.diff")")
        fi
    done < <(find "$ws" -name BUILD.bazel | sort)

    if [[ ${#problems[@]} -eq 0 ]]; then
        echo "PASS $name"
    else
        failed=1
        echo "FAIL $name"
        printf '  %s\n' "${problems[@]}"
        echo "  --- gazelle output:"
        sed 's/^/  /' "$tmp/$name.log"
    fi
done
exit $failed
