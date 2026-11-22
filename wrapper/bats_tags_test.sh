#!/usr/bin/env bash
# Tests bats_tags.sh on its own: what the golden cases, which run it in fix mode through
# //:gazelle, don't cover. Issue: #11

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

bats_tags="$(rlocation "$TAGS")"
buildozer="$(rlocation "$BUILDOZER")"
failed=0

fail() { echo "FAIL: $*"; failed=1; }

# new_ws <dir> [directive value]: a workspace whose root BUILD file holds the directive.
new_ws() {
    rm -rf "$1"
    mkdir -p "$1"
    : >"$1/MODULE.bazel"
    printf '# gazelle:bats_tags %s\n' "${2:-structure=manual+structure,requires-network}" >"$1/BUILD.bazel"
}

# bats <workspace> <dir> <name> <tag line> [rule line]: <dir>/<name>.bats with the tag line,
# and its rule, with the extra line if given.
bats() {
    mkdir -p "$1/$2"
    printf '%s\n@test "x" { true; }\n' "$4" >"$1/$2/$3.bats"
    printf 'bats_test(\n    name = "%s",\n    srcs = ["%s.bats"],\n%s)\n\n' "$3" "$3" "${5:+    $5
}" >>"$1/$2/BUILD.bazel"
}

# tags_of <workspace> <label>: the rule's tags as buildozer prints them.
tags_of() { (cd "$1" && BUILD_WORKING_DIRECTORY="$1" "$buildozer" 'print tags' "$2" 2>/dev/null); }

run() {  # <workspace> <mode> [dir...]: sets out and code
    local ws="$1"
    shift
    out="$(cd "$ws" && BUILD_WORKING_DIRECTORY="$ws" "$bats_tags" "$buildozer" "$@" 2>&1)"
    code=$?
}

# Check mode reports a missing and a left-over tag and changes nothing; fix mode makes both
# changes, and a second run finds nothing.
ws="$TEST_TMPDIR/check"
new_ws "$ws"
bats "$ws" t net '# bats test_tags=requires-network' 'tags = ["external"],'
bats "$ws" t plain '' 'tags = ["external", "requires-network"],'
bats "$ws" t same '# bats test_tags=requires-network' 'tags = ["requires-network"],'
before="$(cat "$ws/t/BUILD.bazel")"
run "$ws" check
[[ $code -eq 1 ]] || fail "check: exit $code, want 1: $out"
[[ "$out" == *"//t:net lacks the tag requires-network, which the bats tags of net.bats ask for"* ]] ||
    fail "check: output lacks the missing tag: $out"
[[ "$out" == *"//t:plain has the tag requires-network, which no bats tag of plain.bats asks for"* ]] ||
    fail "check: output lacks the left-over tag: $out"
[[ "$out" == *"2 target(s) whose tags differ"* && "$out" != *"//t:same"* ]] || fail "check: wrong count: $out"
[[ "$(cat "$ws/t/BUILD.bazel")" == "$before" ]] || fail "check: changed the BUILD file"
run "$ws" fix
[[ $code -eq 0 ]] || fail "fix: exit $code: $out"
[[ "$(tags_of "$ws" //t:net)" == "[external requires-network]" ]] || fail "fix: //t:net has $(tags_of "$ws" //t:net)"
[[ "$(tags_of "$ws" //t:plain)" == "[external]" ]] || fail "fix: //t:plain has $(tags_of "$ws" //t:plain)"
run "$ws" check
[[ $code -eq 0 && -z "$out" ]] || fail "check after fix: exit $code: $out"

# One bats tag becomes two tags; file_tags counts like test_tags; several tags on a line,
# with spaces; a bats tag the directive doesn't name is not carried over.
ws="$TEST_TMPDIR/mapping"
new_ws "$ws"
bats "$ws" t file '# bats file_tags=structure'
bats "$ws" t many '# bats test_tags= issue:12 , requires-network,focus'
bats "$ws" t none '# bats test_tags=issue:12'
bats "$ws" t last '# bats test_tags=structure' 'tags = ["manual", "structure"],'
printf '%s\n@test "x" { true; }\n' '# bats test_tags=issue:12' >"$ws/t/last.bats"
run "$ws" fix
[[ $code -eq 0 ]] || fail "mapping: exit $code: $out"
[[ "$(tags_of "$ws" //t:file)" == "[manual structure]" ]] || fail "mapping: //t:file has $(tags_of "$ws" //t:file)"
[[ "$(tags_of "$ws" //t:many)" == "[requires-network]" ]] || fail "mapping: //t:many has $(tags_of "$ws" //t:many)"
[[ "$(tags_of "$ws" //t:none)" == "(missing)" ]] || fail "mapping: //t:none has $(tags_of "$ws" //t:none)"
# The last mapped tags removed: no empty `tags = []` is left behind.
[[ "$(tags_of "$ws" //t:last)" == "(missing)" ]] || fail "mapping: //t:last has $(tags_of "$ws" //t:last)"

# `# keep` on the rule, above it, on `tags` and on one tag.
ws="$TEST_TMPDIR/keep"
new_ws "$ws"
mkdir -p "$ws/t"
for n in on_rule above on_attr on_tag; do printf '@test "x" { true; }\n' >"$ws/t/$n.bats"; done
cat >"$ws/t/BUILD.bazel" <<'BUILD'
bats_test(  # keep
    name = "on_rule",
    srcs = ["on_rule.bats"],
    tags = ["manual"],
)

# keep
bats_test(
    name = "above",
    srcs = ["above.bats"],
    tags = ["manual"],
)

bats_test(
    name = "on_attr",
    srcs = ["on_attr.bats"],
    tags = ["manual"],  # keep
)

bats_test(
    name = "on_tag",
    srcs = ["on_tag.bats"],
    tags = [
        "manual",  # keep
        "requires-network",
    ],
)
BUILD
run "$ws" fix
[[ $code -eq 0 ]] || fail "keep: exit $code: $out"
for n in on_rule above on_attr on_tag; do
    [[ "$(tags_of "$ws" "//t:$n")" == "[manual]" ]] || fail "keep: //t:$n has $(tags_of "$ws" "//t:$n")"
done
[[ "$out" == *"//t:on_tag loses the tag requires-network"* && "$out" != *"manual"* ]] || fail "keep: output: $out"

# A subpackage inherits the directive, replaces it, or switches it off; a directory argument
# limits the step; a mapped kind counts as bats_test; sh_test is never touched.
ws="$TEST_TMPDIR/packages"
new_ws "$ws"
printf '# gazelle:map_kind bats_test my_bats_test //:defs.bzl\n' >>"$ws/BUILD.bazel"
for d in in in/sub other off excluded; do bats "$ws" "$d" a '# bats test_tags=requires-network,slow'; done
printf '# gazelle:bats_tags slow=exclusive\n%s\n' "$(cat "$ws/other/BUILD.bazel")" >"$ws/other/BUILD.bazel"
printf '# gazelle:bats_tags\n%s\n' "$(cat "$ws/off/BUILD.bazel")" >"$ws/off/BUILD.bazel"
printf '# gazelle:exclude excluded\n' >>"$ws/BUILD.bazel"
sed -i.bak 's/^bats_test(/my_bats_test(/' "$ws/in/sub/BUILD.bazel" && rm "$ws/in/sub/BUILD.bazel.bak"
printf 'sh_test(\n    name = "b",\n    srcs = ["a.bats"],\n)\n' >>"$ws/in/BUILD.bazel"
run "$ws" check in
[[ "$out" == *"//in:a lacks"* && "$out" == *"//in/sub:a lacks"* && "$out" != *"//other:a"* ]] ||
    fail "packages: a directory argument limits the step: $out"
run "$ws" fix
[[ $code -eq 0 ]] || fail "packages: exit $code: $out"
[[ "$(tags_of "$ws" //in:a)" == "[requires-network]" ]] || fail "packages: //in:a has $(tags_of "$ws" //in:a)"
[[ "$(tags_of "$ws" //in/sub:a)" == "[requires-network]" ]] || fail "packages: //in/sub:a has $(tags_of "$ws" //in/sub:a)"
[[ "$(tags_of "$ws" //other:a)" == "[exclusive]" ]] || fail "packages: //other:a has $(tags_of "$ws" //other:a)"
for l in //off:a //excluded:a //in:b; do
    [[ "$(tags_of "$ws" "$l")" == "(missing)" ]] || fail "packages: $l has $(tags_of "$ws" "$l")"
done

# A package and a test file whose names hold a space; a rule named after its package.
ws="$TEST_TMPDIR/spaces"
new_ws "$ws"
bats "$ws" "my tests" "my test" '# bats file_tags=requires-network'
bats "$ws" lib lib '# bats file_tags=requires-network'
run "$ws" fix
[[ $code -eq 0 ]] || fail "spaces: exit $code: $out"
[[ "$(tags_of "$ws" "//my tests:my test")" == "[requires-network]" ]] || fail "spaces: got $(tags_of "$ws" "//my tests:my test"): $out"
[[ "$(tags_of "$ws" //lib:lib)" == "[requires-network]" ]] || fail "spaces: //lib:lib has $(tags_of "$ws" //lib:lib)"

# No directive: nothing is read or changed.
ws="$TEST_TMPDIR/no_directive"
new_ws "$ws"
: >"$ws/BUILD.bazel"
bats "$ws" t a '# bats test_tags=requires-network' 'tags = ["manual"],'
run "$ws" check
[[ $code -eq 0 && -z "$out" ]] || fail "no directive: exit $code: $out"

((failed == 0)) && echo PASS
exit $failed
