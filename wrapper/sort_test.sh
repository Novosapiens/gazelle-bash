#!/usr/bin/env bash
# Tests sort_rules.sh on its own: what the golden cases, which run it in fix mode through
# //:gazelle, don't cover.

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
set +e  # check mode exits 1 on purpose

sort_rules="$(rlocation "$SORT")"
buildozer="$(rlocation "$BUILDOZER")"
failed=0

fail() { echo "FAIL: $*"; failed=1; }

# new_ws <dir>: an empty workspace; write BUILD files into it afterwards.
new_ws() { rm -rf "$1"; mkdir -p "$1"; : >"$1/MODULE.bazel"; }

rule() {  # <BUILD file> <kind> <name> [extra line]
    mkdir -p "$(dirname "$1")"
    printf '%s(\n    name = "%s",\n%s)\n\n' "$2" "$3" "${4:+    $4
}" >>"$1"
}

run() {  # <workspace> <mode> [dir...]: sets out and code
    local ws="$1"
    shift
    out="$(cd "$ws" && BUILD_WORKING_DIRECTORY="$ws" "$sort_rules" "$buildozer" "$@" 2>&1)"
    code=$?
}

names() { grep -o 'name = "[^"]*"' "$1" | sed 's/name = //; s/"//g' | paste -sd' ' -; }

# Out of order, with what must stay put: a load(), a comment block, a hand-written rule of
# another kind, a rule with `# keep`; and a comment that belongs to the rule it is above.
ws="$TEST_TMPDIR/order"
new_ws "$ws"
b="$ws/a/BUILD.bazel"
mkdir -p "$ws/a"
printf 'load("@rules_shell//shell:sh_library.bzl", "sh_library")\n\n# A header.\n\n' >"$b"
rule "$b" sh_library m
rule "$b" sh_binary tool
rule "$b" sh_library z '# keep'
rule "$b" sh_library c
printf '# The test of b.\n' >>"$b"
rule "$b" bats_test b 'srcs = ["b.bats"],'
before="$(cat "$b")"
run "$ws" check
[[ $code -eq 1 ]] || fail "check: exit $code, want 1: $out"
[[ "$out" == *"rules out of order in a/BUILD.bazel: b goes before m"* ]] || fail "check: output lacks the file: $out"
[[ "$(cat "$b")" == "$before" ]] || fail "check: changed the BUILD file"

run "$ws" fix
[[ $code -eq 0 ]] || fail "fix: exit $code: $out"
[[ "$(names "$b")" == "b tool z c m" ]] || fail "fix: want b tool z c m, got $(names "$b")"
head -4 "$b" | grep -q '^# A header.$' || fail "fix: the header moved"
grep -B1 'bats_test(' "$b" | grep -q '^# The test of b.$' || fail "fix: the comment above b didn't move with it"
grep -q '"b.bats"' "$b" || fail "fix: b lost its srcs"
run "$ws" check
[[ $code -eq 0 ]] || fail "check after fix: exit $code: $out"
after="$(cat "$b")"
run "$ws" fix
[[ "$(cat "$b")" == "$after" && -z "$out" ]] || fail "a second fix changed something: $out"

# Byte order: a space and `-` sort before `_` and letters, as in a sorted srcs list; a name
# can hold a space.
ws="$TEST_TMPDIR/bytes"
new_ws "$ws"
rule "$ws/BUILD.bazel" bats_test run_files
rule "$ws/BUILD.bazel" bats_test run-check
rule "$ws/BUILD.bazel" bats_test "run b"
rule "$ws/BUILD.bazel" bats_test run
run "$ws" fix
[[ $code -eq 0 ]] || fail "bytes: exit $code: $out"
[[ "$(names "$ws/BUILD.bazel")" == "run run b run-check run_files" ]] || fail "bytes: got $(names "$ws/BUILD.bazel")"

# A package whose path holds a space, and a rule named after its package (buildozer prints
# `//pkg` for `//pkg:pkg`), as nvm's tests have.
ws="$TEST_TMPDIR/spaces"
new_ws "$ws"
rule "$ws/Unit tests/BUILD.bazel" sh_library "Unit tests"
rule "$ws/Unit tests/BUILD.bazel" sh_library "A b"
rule "$ws/lib/BUILD.bazel" sh_library lib
rule "$ws/lib/BUILD.bazel" sh_library b
run "$ws" fix
[[ $code -eq 0 ]] || fail "spaces: exit $code: $out"
[[ "$(names "$ws/lib/BUILD.bazel")" == "b lib" ]] || fail "spaces: //lib: got $(names "$ws/lib/BUILD.bazel")"
[[ "$(names "$ws/Unit tests/BUILD.bazel")" == "A b Unit tests" ]] ||
    fail "spaces: //Unit tests: got $(names "$ws/Unit tests/BUILD.bazel")"

# A mapped kind is sorted; directory arguments limit the step.
ws="$TEST_TMPDIR/dirs"
new_ws "$ws"
printf '# gazelle:map_kind bats_test my_test //:defs.bzl\n\n' >"$ws/BUILD.bazel"
rule "$ws/a/BUILD.bazel" my_test y
rule "$ws/a/BUILD.bazel" my_test x
rule "$ws/b/BUILD.bazel" sh_library y
rule "$ws/b/BUILD.bazel" sh_library x
run "$ws" fix a
[[ "$(names "$ws/a/BUILD.bazel")" == "x y" ]] || fail "dirs: //a not sorted: $(names "$ws/a/BUILD.bazel")"
[[ "$(names "$ws/b/BUILD.bazel")" == "y x" ]] || fail "dirs: //b was sorted"

# Disabled packages are left alone.
ws="$TEST_TMPDIR/disabled"
new_ws "$ws"
printf '# gazelle:gazelle_bash disabled\n\n' >"$ws/BUILD.bazel"
rule "$ws/BUILD.bazel" sh_library y
rule "$ws/BUILD.bazel" sh_library x
run "$ws" check
[[ $code -eq 0 ]] || fail "disabled: exit $code: $out"

((failed == 0)) && echo PASS
exit $failed
