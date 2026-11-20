#!/usr/bin/env bash
# Sorts, and in check mode only checks, the generated rules of each BUILD file by name.
#
#   sort_rules.sh <buildozer> fix|check [dir...]
#
# Run from the workspace root, after Gazelle. Gazelle adds a new rule at the end of its BUILD
# file, and Orion gives an extension no say in where, so two branches that each add a test to
# one directory both add a block at the same place and conflict when merged. Sorted by name, a
# new rule goes where its name puts it, and two new rules touch different parts of the file
# unless their names sort next to each other.
#
# The rules sorted are those of the kinds prune_stale.sh checks: sh_library, sh_test, bats_test
# and filegroup, and the kinds a `map_kind` maps them to. They swap places among themselves, by
# byte order of their names: every other line stays where it is, a load(), a comment block, a
# hand-written rule of another kind. A rule takes the comment lines directly above it along.
# A rule that holds `# keep`, or has it in a comment line directly above, stays where it is.
#
# Packages Gazelle skips are skipped, as in prune_stale.sh.
#
# Bash 3.2 compatible: macOS runs this with /bin/bash.
set -euo pipefail

buildozer="$1"
mode="$2"
shift 2

# shellcheck source=wrapper/packages.sh
source "$(dirname "${BASH_SOURCE[0]}")/packages.sh"

plan_out="$(list_build_files | sort | plan "$@")"
kinds="$(printf '%s\n' "$plan_out" | sed -n 's/^KIND //p' | sort | paste -sd, -)"
pkgs="$(printf '%s\n' "$plan_out" | sed -n 's/^PKG \(.*\) [^ ]*$/\1/p')"
[[ -n "$pkgs" ]] || exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

while IFS= read -r p; do
    printf 'print label startline endline|%s\n' "$(label_for "$p" '*')"
done <<<"$pkgs" >"$tmp/rules.cmd"
# buildozer exits 3 when a command changes nothing.
"$buildozer" -types "$kinds" -f "$tmp/rules.cmd" 2>/dev/null >"$tmp/rules" || true

# One "<dir>\t<start>\t<end>\t<name>" line per rule that may move, in file order.
while IFS= read -r line; do
    # A package or a name can hold a space; the line numbers can't.
    end="${line##* }"
    line="${line% *}"
    start="${line##* }"
    label="${line% *}"
    label="${label#//}"
    if [[ "$label" == *:* ]]; then
        pkg="${label%%:*}"
        name="${label#*:}"
    else  # buildozer prints `//lib` for `//lib:lib`
        pkg="$label"
        name="${label##*/}"
    fi
    dir="${pkg:-.}"
    file="$(build_file_of "$dir")"
    [[ -f "$file" && "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || continue
    has_keep "$file" "$start" "$end" && continue
    printf '%s\t%s\t%s\t%s\n' "$dir" "$start" "$end" "$name"
done <"$tmp/rules" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n >"$tmp/movable"

unsorted=0
while IFS= read -r dir; do
    file="$(build_file_of "$dir")"
    # "<index>\t<start>\t<end>\t<name>" per block, in file order.
    awk -F '\t' -v d="$dir" '$1 == d { print ++n "\t" $2 "\t" $3 "\t" $4 }' "$tmp/movable" >"$tmp/blocks"
    (($(wc -l <"$tmp/blocks") > 1)) || continue
    # The blocks' indexes in name order: the block each slot gets.
    LC_ALL=C sort -t "$(printf '\t')" -k4,4 "$tmp/blocks" | cut -f1 >"$tmp/order"
    status=0
    awk -F '\t' -v mode="$mode" -v file="$file" -v out="$tmp/new" '
        FILENAME == ARGV[1] { n++; start[n] = $2; end[n] = $3; name[n] = $4; next }
        FILENAME == ARGV[2] { order[++m] = $1; next }
        { line[++nl] = $0 }
        END {
            for (i = 1; i <= n; i++) {
                if (i > 1 && start[i] <= end[i - 1]) exit 0  # two rules on one line: leave it
                prev = (i > 1) ? end[i - 1] : 0
                while (start[i] - 1 > prev && line[start[i] - 1] ~ /^[ \t]*#/) start[i]--
            }
            for (i = 1; i <= n; i++) if (order[i] != i) break
            if (i > n) exit 0
            if (mode == "check") {
                printf "gazelle-bash: rules out of order in %s: %s goes before %s\n", \
                    file, name[order[i]], name[i] > "/dev/stderr"
                exit 11
            }
            s = 1
            for (l = 1; l <= nl; l++) {
                if (s <= n && l == start[s]) {
                    b = order[s]
                    for (k = start[b]; k <= end[b]; k++) print line[k] > out
                    l = end[s]
                    s++
                } else {
                    print line[l] > out
                }
            }
            exit 10
        }
    ' "$tmp/blocks" "$tmp/order" "$file" || status=$?
    case "$status" in
        0) ;;
        10) cat "$tmp/new" >"$file"; rm -f "$tmp/new"; echo "gazelle-bash: sorted the rules of $file" ;;
        11) unsorted=$((unsorted + 1)) ;;
        *) exit "$status" ;;
    esac
done < <(cut -f1 "$tmp/movable" | uniq)

if ((unsorted)); then
    echo "gazelle-bash: $unsorted BUILD file(s) with rules out of order. Run: bazel run //:gazelle" >&2
    exit 1
fi
