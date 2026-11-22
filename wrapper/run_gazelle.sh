#!/usr/bin/env bash
# Runs prune_stale.sh, then the aspect_gazelle runner it wraps, then bats_tags.sh and
# sort_rules.sh. A template: gazelle_bash() in //:defs.bzl fills in the @@...@@ values.
#
#   bazel run //:gazelle [-- gazelle args...]
#
# In check mode, all four still run, so the output shows the stale targets, the BUILD diff,
# the tags that differ and the rules out of order together; it fails if any finds something.

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

if [[ -z "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    echo "error: run this with bazel run" >&2
    exit 1
fi

mode="@@MODE@@"
buildozer="$(rlocation "@@BUILDOZER@@")"
runner="$(rlocation "@@RUNNER@@")"
prune="$(rlocation "@@PRUNE@@")"
sort_rules="$(rlocation "@@SORT@@")"
bats_tags="$(rlocation "@@TAGS@@")"

# Arguments that name a directory limit the other steps, as they limit Gazelle.
dirs=()
for arg in "$@"; do
    [[ "$arg" != -* && -d "$BUILD_WORKSPACE_DIRECTORY/$arg" ]] && dirs+=("$arg")
done

# step <script>: runs a step from the workspace root; prints its exit code.
step() {
    (
        cd "$BUILD_WORKSPACE_DIRECTORY" &&
            BUILD_WORKING_DIRECTORY="$BUILD_WORKSPACE_DIRECTORY" \
                "$1" "$buildozer" "$mode" ${dirs[@]+"${dirs[@]}"}
    )
}

set +e
step "$prune"
pruned=$?
set -e
if [[ $pruned -ne 0 && "$mode" == "fix" ]]; then
    exit $pruned
fi

# Gazelle runs from this script's runfiles directory, where the extensions' paths point.
set +e
"$runner" "$@"
generated=$?
set -e
if [[ $generated -ne 0 && "$mode" == "fix" ]]; then
    exit $generated
fi

set +e
step "$bats_tags"
tagged=$?
set -e
if [[ $tagged -ne 0 && "$mode" == "fix" ]]; then
    exit $tagged
fi

set +e
step "$sort_rules"
sorted=$?
set -e
((pruned == 0)) || exit $pruned
((generated == 0)) || exit $generated
((tagged == 0)) || exit $tagged
exit $sorted
