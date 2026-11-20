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

# BUILD files, parents before children. In a git repo, files git ignores are skipped, as
# Gazelle skips them.
list_build_files() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -co --exclude-standard -- 'BUILD' 'BUILD.bazel' '**/BUILD' '**/BUILD.bazel' |
            while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
    else
        find . \( -name 'bazel-*' -o -name '.git' \) -prune -o \
            \( -name BUILD -o -name BUILD.bazel \) -type f -print | sed 's|^\./||'
    fi
}

# Reads BUILD file paths and prints "KIND <kind>" for each kind to check, "TESTKIND <kind>"
# for the test kinds among them, then "PKG <dir> <generation mode>" for each package Gazelle
# would visit with gazelle_bash enabled ("." for the root), each followed by
# "MAP <dir> <kind> <mapped kind>" for each kind a `map_kind` maps there.
plan() {
    awk -v dirs="$*" '
        function dir_of(f) { return (f ~ /\//) ? substr(f, 1, match(f, /\/[^\/]*$/) - 1) : "." }
        # A Gazelle exclude glob as a regex: `**` spans directories, `*` and `?` do not.
        function glob_re(g,    r, i, c) {
            r = ""
            for (i = 1; i <= length(g); i++) {
                c = substr(g, i, 1)
                if (c == "*" && substr(g, i + 1, 1) == "*") { r = r ".*"; i++ }
                else if (c == "*") r = r "[^/]*"
                else if (c == "?") r = r "[^/]"
                else if (c == "^" || c == "\\") r = r "\\" c
                else if (index(".+$()|{}[]", c)) r = r "[" c "]"
                else r = r c
            }
            return "^" r "$"
        }
        function excluded(p,    i, prefix, n, parts) {
            n = split(p, parts, "/")
            prefix = ""
            for (i = 1; i <= n; i++) {
                prefix = (i == 1) ? parts[1] : prefix "/" parts[i]
                for (k = 1; k <= nexcl; k++) if (prefix ~ excl[k]) return 1
            }
            return 0
        }
        function parent(p) { return (p ~ /\//) ? substr(p, 1, match(p, /\/[^\/]*$/) - 1) : "." }
        function enabled(p) {
            while (1) {
                if (p in state) return state[p] != "disabled"
                if (p == ".") return 1
                p = parent(p)
            }
        }
        function mode_of(p) {
            while (1) {
                if (p in gen) return gen[p]
                if (p == ".") return "file"
                p = parent(p)
            }
        }
        # The kind map_kind maps base kind k to in package p, or "" if none.
        function mapping(p, k) {
            while (1) {
                if ((p, k) in mapped) return mapped[p, k]
                if (p == ".") return ""
                p = parent(p)
            }
        }
        function wanted(p,    i, n, d) {
            if (dirs == "") return 1
            n = split(dirs, d, " ")
            for (i = 1; i <= n; i++) {
                sub(/\/+$/, "", d[i]); sub(/^\.\//, "", d[i])
                if (d[i] == "" || d[i] == "." || p == d[i] || index(p, d[i] "/") == 1) return 1
            }
            return 0
        }
        BEGIN {
            base["sh_library"] = base["sh_test"] = base["bats_test"] = base["filegroup"] = 1
            for (k in base) kinds[k] = 1
            tests["sh_test"] = tests["bats_test"] = 1
        }
        {
            f = $0
            p = dir_of(f)
            if (p in seen) next  # BUILD.bazel and BUILD in one directory: one package
            seen[p] = 1
            order[++npkg] = p
            while ((getline line < f) > 0) {
                if (line !~ /^[ \t]*#[ \t]*gazelle:/) continue
                sub(/^[ \t]*#[ \t]*gazelle:/, "", line)
                n = split(line, w, /[ \t]+/)
                if (w[1] == "exclude" && n >= 2) excl[++nexcl] = glob_re(p == "." ? w[2] : p "/" w[2])
                else if (w[1] == "gazelle_bash" && n >= 2) state[p] = w[2]
                else if (w[1] == "bash_generation_mode" && n >= 2) gen[p] = w[2]
                else if (w[1] == "map_kind" && n >= 3 && (w[2] in base)) {
                    kinds[w[3]] = 1
                    if (w[2] in tests) tests[w[3]] = 1
                    mapped[p, w[2]] = w[3]
                }
            }
            close(f)
        }
        END {
            for (k in kinds) print "KIND " k
            for (k in tests) print "TESTKIND " k
            for (i = 1; i <= npkg; i++) {
                p = order[i]
                if (p != "." && excluded(p)) continue
                if (!enabled(p) || !wanted(p)) continue
                print "PKG " p " " mode_of(p)
                for (k in base) {
                    to = mapping(p, k)
                    if (to != "" && to != k) print "MAP " p " " k " " to
                }
            }
        }
    '
}

label_for() { [[ "$1" == "." ]] && printf '//:%s' "$2" || printf '//%s:%s' "$1" "$2"; }

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

# buildozer prints `//lib` for `//lib:lib`; spell every label out.
full_labels() { awk '$1 !~ /:/ { n = split($1, part, "/"); sub(/^[^ ]+/, $1 ":" part[n]) } { print }'; }

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

has_keep() {  # <build file> <start line> <end line>
    local file="$1" start="$2" end="$3" top="$2"
    while ((top > 1)) && sed -n "$((top - 1))p" "$file" | grep -q '^[[:space:]]*#'; do
        top=$((top - 1))
    done
    sed -n "${top},${end}p" "$file" | grep -qE '#[[:space:]]*keep([^[:alnum:]_]|$)'
}

stale=()
while read -r label kind start end srcs; do
    pkg="${label#//}"
    pkg="${pkg%%:*}"
    name="${label##*:}"
    dir="${pkg:-.}"
    file="$dir/BUILD.bazel"
    [[ -f "$file" ]] || file="$dir/BUILD"
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
