#!/usr/bin/env bash
# Gives each bats test target the `tags` its test file asks for, and in check mode only checks.
#
#   bats_tags.sh <buildozer> fix|check [dir...]
#
# Run from the workspace root, after Gazelle, so a target Gazelle just created gets its tags in
# the same run. Gazelle can't do this itself: an attribute is either merged, and then every
# hand-written tag is deleted, or left alone, and then a tag is never added to or removed from
# a target that already has `tags`. This step owns only the tags a directive names.
#
#   # gazelle:bats_tags structure=manual+structure,requires-network
#
# Each entry is a bats tag, and after `=` the Bazel tags it becomes, joined by `+`; with no
# `=`, the tag of the same name. The directive applies to its package and those below it. One
# in a package below replaces it, and one with no value switches it off there.
#
# A test file has a bats tag when a `# bats file_tags=` or `# bats test_tags=` line names it:
# bats tags a test and Bazel a whole file, so one tagged test tags the target.
#
# For each rule of kind bats_test, or a kind `map_kind` maps it to, whose `srcs` lists `.bats`
# files of the package:
#   - a Bazel tag a bats tag of the file maps to is added;
#   - a Bazel tag the directive names that no bats tag of the file maps to is removed;
#   - every other tag is left alone.
# Nothing is changed in a rule with `# keep` on its first line or in a comment line directly
# above, or whose `tags` line holds `# keep`; a single tag with `# keep` on its line is never
# removed.
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
kinds="$(printf '%s\n' "$plan_out" | sed -n 's/^BATSKIND //p' | sort | paste -sd, -)"
tagged="$(printf '%s\n' "$plan_out" | sed -n 's/^TAGS //p')"
[[ -n "$tagged" ]] || exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# "<dir>\t<BUILD file>\t<mapping>" per package, and the rules to look at.
while IFS= read -r line; do
    p="${line% *}"
    printf '%s\t%s\t%s\n' "$p" "$(build_file_of "$p")" "${line##* }" >>"$tmp/pkgs"
    printf 'print label startline endline srcs tags|%s\n' "$(label_for "$p" '*')" >>"$tmp/rules.cmd"
done <<<"$tagged"
# buildozer exits 3 when a command changes nothing; a rule without `tags` is reported on stderr.
"$buildozer" -types "$kinds" -f "$tmp/rules.cmd" 2>/dev/null >"$tmp/rules" || true

# Prints "<add|remove>\t<label>\t<tags, space separated>\t<test files>" per change to make.
awk -F '\t' '
    function keep(s) { return s ~ /#[ \t]*keep([^A-Za-z0-9_]|$)/ }
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    # Reads `file` into text[file, 1..n]; returns n.
    function slurp(file,    n, l) {
        if (file in size) return size[file]
        n = 0
        while ((getline l < file) > 0) text[file, ++n] = l
        close(file)
        return size[file] = n
    }
    function exists(file,    l, r) {
        r = (getline l < file)
        close(file)
        return r >= 0
    }
    # Sets has[tag] for each bats tag a tag line of `file` names.
    function bats_tags(file, has,    n, i, l, m, j, part) {
        n = slurp(file)
        for (i = 1; i <= n; i++) {
            l = text[file, i]
            if (l !~ /^[ \t]*#[ \t]*bats[ \t]+(file|test)_tags[ \t]*=/) continue
            sub(/^[^=]*=/, "", l)
            m = split(l, part, ",")
            for (j = 1; j <= m; j++) if (trim(part[j]) != "") has[trim(part[j])] = 1
        }
    }
    FILENAME == ARGV[1] { build[$1] = $2; mapping[$1] = $3; next }
    {
        # "<label> <start> <end> <srcs> <tags>": a label can hold a space, so read from the end.
        if (!match($0, / [0-9]+ [0-9]+ (\[[^]]*\]|\(missing\)) (\[[^]]*\]|\(missing\))$/)) next
        label = substr($0, 1, RSTART - 1)
        rest = substr($0, RSTART + 1)
        split(rest, num, " ")
        start = num[1]; end = num[2]
        sub(/^[0-9]+ [0-9]+ /, "", rest)
        if (rest ~ /^\(missing\)/) next
        srcs = substr(rest, 2, index(rest, "]") - 2)
        cur = substr(rest, index(rest, "]") + 2)
        cur = (cur == "(missing)") ? "" : substr(cur, 2, length(cur) - 2)

        dir = label; sub(/^\/\//, "", dir)
        if (dir ~ /:/) sub(/:[^:]*$/, "", dir)
        else { n = split(dir, part, "/"); label = label ":" part[n] }  # `//lib` is `//lib:lib`
        if (dir == "") dir = "."
        if (!(dir in build)) next
        prefix = (dir == ".") ? "" : dir "/"

        # The test files: one name, which can hold a space, or several without.
        nfiles = 0
        if (srcs ~ /\.bats$/ && srcs !~ /[\/:]/ && exists(prefix srcs)) files[++nfiles] = srcs
        else {
            n = split(srcs, part, " ")
            for (i = 1; i <= n; i++)
                if (part[i] ~ /\.bats$/ && part[i] !~ /[\/:]/ && exists(prefix part[i])) files[++nfiles] = part[i]
        }
        if (!nfiles) next

        # `# keep` on the rule, on `tags`, or on single tags.
        file = build[dir]
        slurp(file)
        if (keep(text[file, start])) next
        for (i = start - 1; i >= 1 && text[file, i] ~ /^[ \t]*#/; i--) if (keep(text[file, i])) next
        split("", kept)
        for (i = start + 1; i <= end; i++) {
            if (text[file, i] !~ /^[ \t]*tags[ \t]*=/) continue
            if (keep(text[file, i])) next
            for (i++; i <= end && text[file, i] !~ /^[ \t]*\]/; i++) {
                l = text[file, i]
                if (keep(l) && match(l, /"[^"]*"/)) kept[substr(l, RSTART + 1, RLENGTH - 2)] = 1
            }
            break
        }

        split("", has); split("", want); split("", is); split("", seen)
        names = ""
        for (i = 1; i <= nfiles; i++) {
            bats_tags(prefix files[i], has)
            names = names (i > 1 ? ", " : "") files[i]
        }
        n = split(cur, part, " ")
        for (i = 1; i <= n; i++) is[part[i]] = 1

        # Each entry is `<bats tag>` or `<bats tag>=<tag>+<tag>`.
        nent = split(mapping[dir], entry, ",")
        for (i = 1; i <= nent; i++) {
            from = entry[i]; to = entry[i]
            if (index(from, "=")) { to = substr(from, index(from, "=") + 1); from = substr(from, 1, index(from, "=") - 1) }
            nto[i] = split(to, part, "+")
            for (j = 1; j <= nto[i]; j++) {
                out[i, j] = part[j]
                if (from in has) want[part[j]] = 1
            }
        }
        add = ""; remove = ""
        for (i = 1; i <= nent; i++) for (j = 1; j <= nto[i]; j++) {
            t = out[i, j]
            if (t == "" || (t in seen)) continue
            seen[t] = 1
            if ((t in want) && !(t in is)) add = add (add == "" ? "" : " ") t
            if (!(t in want) && (t in is) && !(t in kept)) remove = remove (remove == "" ? "" : " ") t
        }
        if (add != "") print "add\t" label "\t" add "\t" names
        if (remove != "") print "remove\t" label "\t" remove "\t" names
    }
' "$tmp/pkgs" "$tmp/rules" >"$tmp/changes"

[[ -s "$tmp/changes" ]] || exit 0

# list <tags>: "the tag a" or "the tags a, b".
list() {
    local word="tag"
    [[ "$1" == *" "* ]] && word="tags"
    printf 'the %s %s' "$word" "${1// /, }"
}

if [[ "$mode" == "check" ]]; then
    while IFS=$'\t' read -r what label tags files; do
        if [[ "$what" == "add" ]]; then
            echo "gazelle-bash: $label lacks $(list "$tags"), which the bats tags of $files ask for (bats_tags)" >&2
        else
            echo "gazelle-bash: $label has $(list "$tags"), which no bats tag of $files asks for (bats_tags)" >&2
        fi
    done <"$tmp/changes"
    count="$(cut -f2 "$tmp/changes" | sort -u | wc -l | tr -d ' ')"
    echo "gazelle-bash: $count target(s) whose tags differ from their bats tags. Run: bazel run //:gazelle" >&2
    exit 1
fi

while IFS=$'\t' read -r what label tags files; do
    printf '%s tags %s|%s\n' "$what" "$tags" "$label" >>"$tmp/fix.cmd"
    if [[ "$what" == "add" ]]; then
        echo "gazelle-bash: $label gets $(list "$tags") from the bats tags of $files (bats_tags)"
    else
        echo "gazelle-bash: $label loses $(list "$tags"), which no bats tag of $files asks for (bats_tags)"
    fi
done <"$tmp/changes"
"$buildozer" -f "$tmp/fix.cmd" >/dev/null 2>&1 || [[ $? -eq 3 ]]
