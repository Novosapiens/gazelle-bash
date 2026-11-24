#!/usr/bin/env bash
# Runs prune_stale.sh, then the aspect_gazelle runner it wraps, then advise.sh on what the
# runner printed, then bats_tags.sh and sort_rules.sh. A template: gazelle_bash() in //:defs.bzl fills in the @@...@@ values.
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
advise="$(rlocation "@@ADVISE@@")"

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

# Gazelle runs from this script's runfiles directory, where the extensions' paths point. Its
# stdout and stderr are copied, each to its own stream and file, for advise.sh. The pipes keep
# both copies whole by the time the runner's exit code is read, in bash 3.2 too.
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT
set +e
{ { "$runner" "$@"; echo $? > "$logs/code"; } 2>&1 1>&3 3>&- | tee "$logs/err" >&2 3>&-; } 3>&1 | tee "$logs/out"
generated="$(cat "$logs/code" 2>/dev/null || echo 1)"
(cd "$BUILD_WORKSPACE_DIRECTORY" && "$advise" "$logs/out" "$logs/err")
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
