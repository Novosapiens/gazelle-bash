#!/usr/bin/env bash
# Tests prune_stale.sh on its own: what the golden cases, which run it in fix mode through
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

prune="$(rlocation "$PRUNE")"
buildozer="$(rlocation "$BUILDOZER")"
failed=0

fail() { echo "FAIL: $*"; failed=1; }

# new_ws <dir>: an empty workspace; write BUILD files into it afterwards.
new_ws() { rm -rf "$1"; mkdir -p "$1"; : >"$1/MODULE.bazel"; }

stale_lib() {  # <BUILD file> <name> <src>
    mkdir -p "$(dirname "$1")"
    printf 'sh_library(\n    name = "%s",\n    srcs = ["%s"],\n)\n\n' "$2" "$3" >>"$1"
}

run() {  # <workspace> <mode> [dir...]: sets out and code
    local ws="$1"
    shift
    out="$(cd "$ws" && BUILD_WORKING_DIRECTORY="$ws" "$prune" "$buildozer" "$@" 2>&1)"
    code=$?
}

ws="$TEST_TMPDIR/check"
new_ws "$ws"
stale_lib "$ws/a/BUILD.bazel" gone gone.sh
before="$(cat "$ws/a/BUILD.bazel")"
run "$ws" check
[[ $code -eq 1 ]] || fail "check: exit $code, want 1"
[[ "$out" == *"stale target //a:gone: its files are gone: gone.sh"* ]] || fail "check: output lacks the target: $out"
[[ "$(cat "$ws/a/BUILD.bazel")" == "$before" ]] || fail "check: changed the BUILD file"

run "$ws" fix
[[ $code -eq 0 ]] || fail "fix: exit $code: $out"
grep -q '"gone"' "$ws/a/BUILD.bazel" && fail "fix: //a:gone is still there"
run "$ws" check
[[ $code -eq 0 ]] || fail "check after fix: exit $code: $out"

ws="$TEST_TMPDIR/dirs"
new_ws "$ws"
stale_lib "$ws/a/BUILD.bazel" gone gone.sh
stale_lib "$ws/b/BUILD.bazel" gone gone.sh
run "$ws" check a
[[ "$out" == *"//a:gone"* && "$out" != *"//b:gone"* ]] || fail "dirs: want only //a:gone, got: $out"

ws="$TEST_TMPDIR/spaces"
new_ws "$ws"
mkdir -p "$ws/a"
: >"$ws/a/my file.sh"
stale_lib "$ws/a/BUILD.bazel" spaced "my file.sh"
stale_lib "$ws/a/BUILD.bazel" spaced_gone "other file.sh"
run "$ws" check
[[ $code -eq 0 ]] || fail "spaces: a name with a space must never count as stale: $out"

ws="$TEST_TMPDIR/map_kind"
new_ws "$ws"
printf '# gazelle:map_kind sh_library my_lib //:defs.bzl\n' >"$ws/BUILD.bazel"
mkdir -p "$ws/a" "$ws/off"
: >"$ws/a/x.sh"
: >"$ws/off/x.sh"
stale_lib "$ws/a/BUILD.bazel" x x.sh
printf '# gazelle:map_kind sh_library sh_library @rules_shell//shell:sh_library.bzl\n' >"$ws/off/BUILD.bazel"
stale_lib "$ws/off/BUILD.bazel" x x.sh
run "$ws" check
[[ $code -eq 1 && "$out" == *"//a:x is a sh_library, but map_kind maps sh_library to my_lib there"* ]] ||
    fail "map_kind check: exit $code: $out"
[[ "$out" != *"//off:x"* ]] || fail "map_kind check: a subpackage maps the kind back, yet: $out"
grep -q '^sh_library' "$ws/a/BUILD.bazel" || fail "map_kind check: changed the BUILD file"
run "$ws" fix
[[ $code -eq 0 ]] && grep -q '^my_lib(' "$ws/a/BUILD.bazel" || fail "map_kind fix: exit $code: $out"
grep -q '^sh_library(' "$ws/off/BUILD.bazel" || fail "map_kind fix: renamed //off:x"
run "$ws" check
[[ $code -eq 0 ]] || fail "map_kind check after fix: exit $code: $out"

ws="$TEST_TMPDIR/deleted_dir"
new_ws "$ws"
stale_lib "$ws/gone/BUILD.bazel" gone gone.sh
stale_lib "$ws/other/BUILD.bazel" gone gone.sh
: >"$ws/other/README.md"
mkdir -p "$ws/directive"
printf '# gazelle:bash_generation_mode file\n' >"$ws/directive/BUILD.bazel"
run "$ws" check
[[ $code -eq 1 && "$out" == *"stale BUILD file gone/BUILD.bazel: nothing else is left in its directory"* ]] ||
    fail "deleted_dir check: exit $code: $out"
[[ "$out" != *"stale BUILD file other/"* && "$out" != *"stale BUILD file directive/"* ]] ||
    fail "deleted_dir check: a directory with another file, or a directive, is not deleted: $out"
[[ -f "$ws/gone/BUILD.bazel" ]] || fail "deleted_dir check: removed the BUILD file"
run "$ws" fix
[[ $code -eq 0 && ! -e "$ws/gone" ]] || fail "deleted_dir fix: gone/ is still there, exit $code: $out"
[[ -f "$ws/other/BUILD.bazel" && -f "$ws/directive/BUILD.bazel" ]] || fail "deleted_dir fix: removed a BUILD file it should keep"
run "$ws" check
[[ $code -eq 0 ]] || fail "deleted_dir check after fix: exit $code: $out"

ws="$TEST_TMPDIR/renamed_dir"
new_ws "$ws"
printf '# gazelle:bash_generation_mode package\n' >"$ws/BUILD.bazel"
mkdir -p "$ws/util"
: >"$ws/util/log.sh"
: >"$ws/util/notes.txt"
: >"$ws/util/lib.bats"
: >"$ws/util/util.bats"
stale_lib "$ws/util/BUILD.bazel" lib log.sh
printf 'filegroup(\n    name = "lib_files",\n    srcs = ["notes.txt"],\n)\n\n' >>"$ws/util/BUILD.bazel"
printf 'bats_test(\n    name = "lib_bats",\n    srcs = ["lib.bats"],\n)\n\n' >>"$ws/util/BUILD.bazel"
printf 'bats_test(\n    name = "util_bats",\n    srcs = ["util.bats"],\n)\n\n' >>"$ws/util/BUILD.bazel"
printf '# keep\n' >>"$ws/util/BUILD.bazel"
stale_lib "$ws/util/BUILD.bazel" pinned log.sh
run "$ws" check
for t in lib lib_files lib_bats; do
    [[ "$out" == *"stale target //util:$t: package mode names this directory's targets after util"* ]] ||
        fail "renamed_dir check: want //util:$t stale: $out"
done
[[ "$out" != *"//util:util_bats"* && "$out" != *"//util:pinned"* ]] ||
    fail "renamed_dir check: a test named after its own directory, or a rule with # keep, is not stale: $out"

if command -v git >/dev/null; then
    ws="$TEST_TMPDIR/git"
    new_ws "$ws"
    stale_lib "$ws/a/BUILD.bazel" gone gone.sh
    stale_lib "$ws/ignored/BUILD.bazel" gone gone.sh
    stale_lib "$ws/z/BUILD.bazel" gone gone.sh
    echo ignored/ >"$ws/.gitignore"
    git -C "$ws" init -q
    git -C "$ws" add z/BUILD.bazel
    rm -r "$ws/z"  # tracked, then deleted: git still lists it, last
    run "$ws" check
    [[ "$out" == *"//a:gone"* && "$out" != *"//ignored:gone"* && "$out" != *"//z:gone"* ]] ||
        fail "git: want only //a:gone, got exit $code: $out"
fi

((failed == 0)) && echo PASS
exit $failed
