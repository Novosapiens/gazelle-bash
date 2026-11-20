#!/usr/bin/env bash
# Before Gazelle runs: finds, and in fix mode deletes, generated targets whose files were all
# deleted, and gives an existing rule the kind a `map_kind` maps its kind to.
#
#   prune_stale.sh <buildozer> fix|check [dir...]
#
# Run from the workspace root. Orion doesn't show extensions the existing BUILD file, so
# shell.axl can't see a target whose file is gone; this runs before Gazelle and does what
# Gazelle's Go languages do for their own rules.
#
# A rule is stale when all of these hold:
#   - its kind is sh_library, sh_test, bats_test or filegroup, or one a `map_kind` maps
#     them to;
#   - `srcs` is a non-empty list of plain file names in the package: no label, no glob,
#     no path into a subdirectory;
#   - none of those files exists, and none is a rule name or output in the package;
#   - neither the rule nor a comment line directly above it holds `# keep`.
# Also stale, in a `bash_generation_mode package` directory: a test rule named like the
# package's library or filegroup (`lib` or `lib_files` in `lib/`). That was the test's name
# in `file` mode; shell.axl now generates the test as `lib_bats` and can't remove the old
# rule itself.
#
# A rule of a kind that a `map_kind` maps in its package takes the mapped kind, keeping its
# attributes. Orion fails on it otherwise ("a target of kind bats_test with the same name
# already exists").
#
# Packages Gazelle skips (`# gazelle:exclude`, `# gazelle:gazelle_bash disabled`) are skipped.
#
# Bash 3.2 compatible: macOS runs this with /bin/bash.
set -euo pipefail
set -f  # no pathname expansion when splitting a srcs list

buildozer="$1"
mode="$2"
shift 2

# shellcheck source=wrapper/packages.sh
source "$(dirname "${BASH_SOURCE[0]}")/packages.sh"

plan_out="$(list_build_files | sort | plan "$@")"
kinds="$(printf '%s\n' "$plan_out" | sed -n 's/^KIND //p' | sort | paste -sd, -)"
testkinds=" $(printf '%s\n' "$plan_out" | sed -n 's/^TESTKIND //p' | paste -sd' ' -) "
pkgs="$(printf '%s\n' "$plan_out" | sed -n 's/^PKG \(.*\) [^ ]*$/\1/p')"
package_mode=" $(printf '%s\n' "$plan_out" | sed -n 's/^PKG \(.*\) package$/\1/p' | paste -sd' ' -) "
[[ -n "$pkgs" ]] || exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# buildozer exits 3 when a command changes nothing; errors for rules without an attribute
# go to stderr.
bz() { "$buildozer" "$@" 2>/dev/null || [[ $? -eq 3 ]]; }

while IFS= read -r p; do
    printf 'print label kind startline endline srcs|%s\n' "$(label_for "$p" '*')"
done <<<"$pkgs" >"$tmp/candidates.cmd"
bz -types "$kinds" -f "$tmp/candidates.cmd" | full_labels >"$tmp/candidates" || true

# Every rule name, and every declared output, in the packages that have a candidate: a
# src that names one is a generated file, not a deleted one.
: >"$tmp/known.cmd"
sed -n 's|^//\([^:]*\):.*|\1|p' "$tmp/candidates" | sort -u | while IFS= read -r p; do
    printf 'print label outs out|//%s:*\n' "$p" >>"$tmp/known.cmd"
done
# One "<package>\t<name>" line per rule name and per declared output.
bz -f "$tmp/known.cmd" | full_labels | awk '{
    label = $1; sub(/^\/\//, "", label)
    split(label, part, ":")
    print part[1] "\t" part[2]
    for (i = 2; i <= NF; i++) {
        w = $i; gsub(/\[/, "", w); gsub(/\]/, "", w)
        if (w != "" && w != "(missing)") print part[1] "\t" w
    }
}' >"$tmp/known" || true

stale=()
while read -r label kind start end srcs; do
    pkg="${label#//}"
    pkg="${pkg%%:*}"
    name="${label##*:}"
    dir="${pkg:-.}"
    file="$(build_file_of "$dir")"
    if [[ "$package_mode" == *" $dir "* && "$testkinds" == *" $kind "* ]]; then
        base="${pkg##*/}"
        base="${base:-root}"
        if [[ "$name" == "$base" || "$name" == "${base}_files" ]]; then
            has_keep "$file" "$start" "$end" ||
                stale+=("$label package mode gives this name to the package target")
            continue
        fi
    fi
    [[ "$srcs" == \[*\] && "$srcs" != "[]" ]] || continue
    body="$(sed -n "${start},${end}p" "$file")"
    gone=()
    ok=1
    for src in ${srcs:1:${#srcs}-2}; do
        case "$src" in
            */* | *:* | *\$* | *\** | *\?* | *\[* | *\{*) ok=0; break ;;
        esac
        # buildozer prints a list without quotes; a name that isn't in the rule's text as a
        # quoted string held a space or an escape, so leave the rule alone.
        if ! grep -qF "\"$src\"" <<<"$body"; then ok=0; break; fi
        if [[ -e "$dir/$src" || -L "$dir/$src" ]]; then ok=0; break; fi
        if grep -qxF "${pkg}"$'\t'"${src}" "$tmp/known"; then ok=0; break; fi
        gone+=("$src")
    done
    ((ok)) && ((${#gone[@]})) || continue
    has_keep "$file" "$start" "$end" && continue
    stale+=("$label its files are gone: ${gone[*]}")
done <"$tmp/candidates"

# A rule of a kind that `map_kind` maps in its package gets the mapped kind, keeping its
# attributes, so Gazelle merges into it. Orion fails on it otherwise: it generates the mapped
# kind under the rule's name and won't replace a rule of another kind. Stale rules are
# deleted instead. A rule with `# keep` is renamed too: Gazelle leaves its attributes alone,
# but it can't keep a rule under a kind it no longer generates.
printf '%s\n' "$plan_out" | sed -n 's/^MAP //p' >"$tmp/maps"
renames=()
stale_labels=" "
for s in ${stale[@]+"${stale[@]}"}; do stale_labels+="${s%% *} "; done
while read -r label kind to; do
    [[ "$stale_labels" == *" $label "* ]] && continue
    renames+=("$label $kind $to")
done < <(awk 'NR == FNR { to[$1 " " $2] = $3; next }
    {
        pkg = $1; sub(/^\/\//, "", pkg); sub(/:.*/, "", pkg)
        if (pkg == "") pkg = "."
        if ((pkg " " $2) in to) print $1, $2, to[pkg " " $2]
    }' "$tmp/maps" "$tmp/candidates")

((${#stale[@]} + ${#renames[@]})) || exit 0

if [[ "$mode" == "check" ]]; then
    for s in ${stale[@]+"${stale[@]}"}; do
        echo "gazelle-bash: stale target ${s%% *}: ${s#* }" >&2
    done
    for r in ${renames[@]+"${renames[@]}"}; do
        set -- $r
        echo "gazelle-bash: $1 is a $2, but map_kind maps $2 to $3 there" >&2
    done
    echo "gazelle-bash: $((${#stale[@]} + ${#renames[@]})) target(s) to fix. Run: bazel run //:gazelle" >&2
    exit 1
fi

: >"$tmp/fix.cmd"
for s in ${stale[@]+"${stale[@]}"}; do
    printf 'delete|%s\n' "${s%% *}" >>"$tmp/fix.cmd"
    echo "gazelle-bash: removed ${s%% *}: ${s#* }"
done
for r in ${renames[@]+"${renames[@]}"}; do
    set -- $r
    printf 'set kind %s|%s\n' "$3" "$1" >>"$tmp/fix.cmd"
    echo "gazelle-bash: $1 is now a $3 (map_kind)"
done
bz -f "$tmp/fix.cmd" >/dev/null
