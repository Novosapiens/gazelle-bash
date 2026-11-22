#!/usr/bin/env bash
# Gives each bats test target the `tags`, `size` and `timeout` its test file asks for, and in
# check mode only checks.
#
#   bats_tags.sh <buildozer> fix|check [dir...]
#
# Run from the workspace root, after Gazelle, so a target Gazelle just created gets them in
# the same run. Gazelle can't do this itself: an attribute is either merged, and then every
# hand-written tag is deleted, or left alone, and then a tag is never added to or removed from
# a target that already has `tags`. This step owns only what a directive names.
#
#   # gazelle:bats_tags structure=manual+structure,requires-network
#
# Each entry is a bats tag, and after `=` the Bazel tags it becomes, joined by `+`; with no
# `=`, the tag of the same name.
#
#   # gazelle:bats_size size
#   # gazelle:bats_timeout timeout
#
# The value is the first part of a bats tag: with these, the bats tag `size:small` sets
# `size = "small"` and `timeout:short` sets `timeout = "short"`.
#
# A directive applies to its package and those below it. One in a package below replaces it,
# and one with no value switches it off there.
#
# A test file has a bats tag when a `# bats file_tags=` or `# bats test_tags=` line names it:
# bats tags a test and Bazel a whole file, so one tagged test tags the target. When the tests
# of a file name several sizes or timeouts, the target gets the largest.
#
# For each rule of kind bats_test, or a kind `map_kind` maps it to, whose `srcs` lists `.bats`
# files of the package:
#   - a Bazel tag a bats tag of the file maps to is added;
#   - a Bazel tag the directive names that no bats tag of the file maps to is removed;
#   - every other tag is left alone;
#   - with `bats_size`, `size` is set to what the file asks for, and removed when it asks for
#     none; `bats_timeout` does the same for `timeout`.
# Nothing is changed in a rule with `# keep` on its first line or in a comment line directly
# above; a `tags`, `size` or `timeout` line that holds `# keep` is left alone; a single tag
# with `# keep` on its line is never removed.
#
# A bats tag that names no size or timeout Bazel has, such as `size:tiny`, stops the step with
# an error in both modes.
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
# "<dir>\t<tags mapping>\t<size prefix>\t<timeout prefix>" per package a directive applies to.
# A directory name can hold a space, so it is what lies between the first word and the last.
directed="$(printf '%s\n' "$plan_out" | awk '
    /^(TAGS|SIZE|TIMEOUT) / {
        dir = $0
        sub(/^[A-Z]+ /, "", dir)
        sub(/ [^ ]*$/, "", dir)
        if (!(dir in seen)) { seen[dir] = 1; order[++n] = dir }
        value[dir, $1] = $NF
    }
    END {
        for (i = 1; i <= n; i++) {
            d = order[i]
            printf "%s\t%s\t%s\t%s\n", d, value[d, "TAGS"], value[d, "SIZE"], value[d, "TIMEOUT"]
        }
    }
')"
[[ -n "$directed" ]] || exit 0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# "<dir>\t<BUILD file>\t<tags mapping>\t<size prefix>\t<timeout prefix>" per package, and the
# rules to look at.
while IFS= read -r line; do
    p="${line%%$'\t'*}"
    printf '%s\t%s\t%s\n' "$p" "$(build_file_of "$p")" "${line#*$'\t'}" >>"$tmp/pkgs"
    printf 'print label startline endline srcs tags size timeout|%s\n' "$(label_for "$p" '*')" >>"$tmp/rules.cmd"
done <<<"$directed"
# buildozer exits 3 when a command changes nothing; a rule without an attribute is reported on
# stderr, and prints `(missing)` for it.
"$buildozer" -types "$kinds" -f "$tmp/rules.cmd" 2>/dev/null >"$tmp/rules" || true

# Prints "<add|remove|set|unset|error>\t<label>\t<attribute>\t<value>\t<test files>" per change
# to make: for `tags` the value is the tags, space separated; for `unset` it is the value the
# rule has now; for `error` it is the bats tag that names no size or timeout.
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
    # Where value v stands among the sizes or timeouts Bazel has, smallest first; 0 if nowhere.
    function rank(attr, v) {
        if (v == "" || v ~ / /) return 0
        return index(attr == "size" ? " small medium large enormous " : " short moderate long eternal ", " " v " ")
    }
    # The largest value the bats tags `<prefix>:<value>` in has[] ask for, "" if none.
    function asked(attr, prefix, has,    t, v, best) {
        best = ""
        for (t in has) {
            if (index(t, prefix ":") != 1) continue
            v = substr(t, length(prefix) + 2)
            if (!rank(attr, v)) { print "error\t" label "\t" attr "\t" t "\t" names; continue }
            if (best == "" || rank(attr, v) > rank(attr, best)) best = v
        }
        return best
    }
    FILENAME == ARGV[1] { build[$1] = $2; mapping[$1] = $3; prefix_of[$1, "size"] = $4; prefix_of[$1, "timeout"] = $5; next }
    {
        # "<label> <start> <end> <srcs> <tags> <size> <timeout>": a label can hold a space, so
        # read from the end.
        if (!match($0, / [0-9]+ [0-9]+ (\[[^]]*\]|\(missing\)) (\[[^]]*\]|\(missing\)) [^ ]+ [^ ]+$/)) next
        label = substr($0, 1, RSTART - 1)
        rest = substr($0, RSTART + 1)
        split(rest, num, " ")
        start = num[1]; end = num[2]
        sub(/^[0-9]+ [0-9]+ /, "", rest)
        n = split(rest, part, " ")
        now["size"] = (part[n - 1] == "(missing)") ? "" : part[n - 1]
        now["timeout"] = (part[n] == "(missing)") ? "" : part[n]
        sub(/ [^ ]+ [^ ]+$/, "", rest)
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

        # `# keep` on the rule, on an attribute, or on single tags.
        file = build[dir]
        slurp(file)
        if (keep(text[file, start])) next
        for (i = start - 1; i >= 1 && text[file, i] ~ /^[ \t]*#/; i--) if (keep(text[file, i])) next
        split("", kept); split("", kept_attr)
        for (i = start + 1; i <= end; i++) {
            l = text[file, i]
            if (l ~ /^[ \t]*size[ \t]*=/ && keep(l)) kept_attr["size"] = 1
            if (l ~ /^[ \t]*timeout[ \t]*=/ && keep(l)) kept_attr["timeout"] = 1
        }
        for (i = start + 1; i <= end; i++) {
            if (text[file, i] !~ /^[ \t]*tags[ \t]*=/) continue
            if (keep(text[file, i])) { kept_attr["tags"] = 1; break }
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
        nent = ("tags" in kept_attr) ? 0 : split(mapping[dir], entry, ",")
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
        if (add != "") print "add\t" label "\ttags\t" add "\t" names
        if (remove != "") print "remove\t" label "\ttags\t" remove "\t" names

        for (k = 1; k <= 2; k++) {
            attr = (k == 1) ? "size" : "timeout"
            if (prefix_of[dir, attr] == "" || (attr in kept_attr)) continue
            value = asked(attr, prefix_of[dir, attr], has)
            if (value != "" && value != now[attr]) print "set\t" label "\t" attr "\t" value "\t" names
            if (value == "" && now[attr] != "") print "unset\t" label "\t" attr "\t" now[attr] "\t" names
        }
    }
' "$tmp/pkgs" "$tmp/rules" >"$tmp/changes"

[[ -s "$tmp/changes" ]] || exit 0

# A bats tag that names no size or timeout: nothing is changed.
if grep -q '^error'$'\t' "$tmp/changes"; then
    while IFS=$'\t' read -r what label attr value files; do
        [[ "$what" == "error" ]] || continue
        if [[ "$attr" == "size" ]]; then
            echo "gazelle-bash: $label: the bats tag $value in $files names no size Bazel has: small, medium, large or enormous (bats_size)" >&2
        else
            echo "gazelle-bash: $label: the bats tag $value in $files names no timeout Bazel has: short, moderate, long or eternal (bats_timeout)" >&2
        fi
    done <"$tmp/changes"
    exit 1
fi

# list <tags>: "the tag a" or "the tags a, b".
list() {
    local word="tag"
    [[ "$1" == *" "* ]] && word="tags"
    printf 'the %s %s' "$word" "${1// /, }"
}

if [[ "$mode" == "check" ]]; then
    while IFS=$'\t' read -r what label attr value files; do
        case "$what" in
            add) echo "gazelle-bash: $label lacks $(list "$value"), which the bats tags of $files ask for (bats_tags)" >&2 ;;
            remove) echo "gazelle-bash: $label has $(list "$value"), which no bats tag of $files asks for (bats_tags)" >&2 ;;
            set) echo "gazelle-bash: $label lacks the $attr $value, which the bats tags of $files ask for (bats_$attr)" >&2 ;;
            unset) echo "gazelle-bash: $label has the $attr $value, which no bats tag of $files asks for (bats_$attr)" >&2 ;;
        esac
    done <"$tmp/changes"
    count="$(cut -f2 "$tmp/changes" | sort -u | wc -l | tr -d ' ')"
    echo "gazelle-bash: $count target(s) that differ from their bats tags. Run: bazel run //:gazelle" >&2
    exit 1
fi

while IFS=$'\t' read -r what label attr value files; do
    case "$what" in
        add | remove) printf '%s tags %s|%s\n' "$what" "$value" "$label" >>"$tmp/fix.cmd" ;;
        set) printf 'set %s %s|%s\n' "$attr" "$value" "$label" >>"$tmp/fix.cmd" ;;
        unset) printf 'remove %s|%s\n' "$attr" "$label" >>"$tmp/fix.cmd" ;;
    esac
    case "$what" in
        add) echo "gazelle-bash: $label gets $(list "$value") from the bats tags of $files (bats_tags)" ;;
        remove) echo "gazelle-bash: $label loses $(list "$value"), which no bats tag of $files asks for (bats_tags)" ;;
        set) echo "gazelle-bash: $label gets the $attr $value from the bats tags of $files (bats_$attr)" ;;
        unset) echo "gazelle-bash: $label loses the $attr $value, which no bats tag of $files asks for (bats_$attr)" ;;
    esac
done <"$tmp/changes"
"$buildozer" -f "$tmp/fix.cmd" >/dev/null 2>&1 || [[ $? -eq 3 ]]
