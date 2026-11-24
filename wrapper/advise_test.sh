#!/usr/bin/env bash
# Tests advise.sh on Gazelle output written by hand: each kind of advice for an unknown
# dependency, and the summary of skipped lines.

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

advise="$(rlocation "$ADVISE")"
failed=0

fail() { echo "FAIL: $*"; failed=1; }

ws="$TEST_TMPDIR/ws"
rm -rf "$ws"
mkdir -p "$ws/examples" "$ws/vendor/lib" "$ws/tests/fixtures" "$ws/tools"
cd "$ws" || exit 1

# A data file with no target, a submodule that isn't checked out, a comment naming a missing
# path, a missing file in a folder, and a missing tree.
printf 'math\n' > examples/math.inc
printf 'source "$(dirname "$0")/math.inc"\n' > examples/math_test.sh
printf '[submodule "vendor/lib"]\n\tpath = vendor/lib\n\turl = https://example.com/lib\n' > .gitmodules
printf '#!/usr/bin/env bash\nload ../vendor/lib/load\n' > tests/a.bats
printf '#!/usr/bin/env bash\n# gazelle-bash: dep ../gone.sh\n' > tests/b.sh
printf 'load missing\n' > tests/fixtures/c.bats
printf 'x\n' > top.sh

err="$TEST_TMPDIR/err"
cat > "$err" <<'EOF'
aspect-gazelle: Error running gazelle: Resolution Error: Import "examples/math.inc" (provider "shell") from "examples/math_test.sh:1" is an unknown dependency
Import "vendor/lib/load.bash" (provider "shell") from "tests/a.bats:2" is an unknown dependency
Import "gone.sh" (provider "shell") from "tests/b.sh:2" is an unknown dependency
Import "tests/fixtures/missing.bash" (provider "shell") from "tests/fixtures/c.bats:1" is an unknown dependency
Import "nowhere" (provider "shell_tree") from "top.sh:1" is an unknown dependency
EOF

# Skipped lines: two variables, one set by a script to its own parent directory, one a system
# variable, and lines a root variable wouldn't make readable.
printf 'APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n' > tools/env.sh
out="$TEST_TMPDIR/out"
cat > "$out" <<'EOF'
AspectConfigure-gazelle_bash: gazelle-bash: a.sh:3: skipped source path that cannot be read statically: "$APP_ROOT/lib/a.sh"
AspectConfigure-gazelle_bash: gazelle-bash: b.sh:4: skipped source path that cannot be read statically: "${APP_ROOT}/lib/b.sh"
AspectConfigure-gazelle_bash: gazelle-bash: c.sh:5: skipped source path that cannot be read statically: "$PLUGINS/core/x.sh"
AspectConfigure-gazelle_bash: gazelle-bash: c.sh:6: skipped source path that cannot be read statically: "$PLUGINS/$name/x.sh"
AspectConfigure-gazelle_bash: gazelle-bash: d.sh:1: skipped source path that cannot be read statically: "$HOME/.bashrc"
AspectConfigure-gazelle_bash: gazelle-bash: d.sh:2: skipped source path that cannot be read statically: "$1"
AspectConfigure-gazelle_bash: gazelle-bash: e.sh:1: skipped source of x.sh: no such file next to the script, so Bash finds it on PATH
EOF

said="$("$advise" "$out" "$err" 2>&1)"
code=$?
[[ $code -eq 0 ]] || fail "exit $code, want 0"

want() {  # <text>: a line of the output must hold it
    [[ "$said" == *"$1"* ]] || fail "output lacks: $1"
}
want "examples/math_test.sh:1 needs examples/math.inc, which isn't a script, so it has no target. To depend on it, add # gazelle:bash_data_files **/*.inc to the root BUILD file."
want "tests/a.bats:2 needs vendor/lib/load.bash, in the submodule vendor/lib, which isn't checked out. Run git submodule update --init vendor/lib"
want "tests/b.sh:2 needs gone.sh, which the comment on that line names, and it doesn't exist. Fix the path in the comment, or remove the comment."
want "tests/fixtures/c.bats:1 needs tests/fixtures/missing.bash, which doesn't exist. If the file is made at run time or missing on purpose, add # gazelle-bash: ignore above that line, or # gazelle:exclude tests/fixtures if that folder holds fixtures."
want "top.sh:1 needs everything under nowhere/, which doesn't exist. If the file is made at run time or missing on purpose, add # gazelle-bash: ignore above that line."
want "2 skipped lines start with \$APP_ROOT (first: a.sh:3). tools/env.sh sets it to .: add # gazelle:bash_root_vars APP_ROOT=. to read them."
want "1 skipped line starts with \$PLUGINS (first: c.sh:5). If it holds a fixed directory of this repo, add # gazelle:bash_root_vars PLUGINS=<that directory, from the root> to read them."
[[ "$said" != *'$HOME'* ]] || fail "suggested a system variable: $said"
[[ "$said" != *'$1'* ]] || fail "suggested a positional parameter: $said"
# APP_ROOT comes first: more lines.
[[ "$(grep -n 'APP_ROOT (first' <<<"$said" | cut -d: -f1)" -lt "$(grep -n 'PLUGINS (first' <<<"$said" | cut -d: -f1)" ]] || fail "summary not sorted by count: $said"

# Nothing to say: no output.
: > "$TEST_TMPDIR/empty"
said="$("$advise" "$TEST_TMPDIR/empty" "$TEST_TMPDIR/empty" 2>&1)"
[[ -z "$said" ]] || fail "said something about clean output: $said"

if [[ $failed -ne 0 ]]; then
    exit 1
fi
echo "PASS"
