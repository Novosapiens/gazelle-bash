# The packages gazelle_bash()'s steps work on, and the rule kinds they touch. Sourced by
# prune_stale.sh and sort_rules.sh, which run from the workspace root.
#
#   list_build_files | sort | plan [dir...]
#
# Bash 3.2 compatible: macOS runs this with /bin/bash.

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

# Reads BUILD file paths and prints "KIND <kind>" for each kind shell.axl generates or a
# `map_kind` maps one to, "TESTKIND <kind>" for the test kinds among them, then
# "PKG <dir> <generation mode>" for each package Gazelle would visit with gazelle_bash enabled
# ("." for the root), each followed by "MAP <dir> <kind> <mapped kind>" for each kind a
# `map_kind` maps there. Packages Gazelle skips (`# gazelle:exclude`,
# `# gazelle:gazelle_bash disabled`) are left out, and so are those outside the [dir...] given.
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

# The BUILD file of package directory <dir>.
build_file_of() {
    local prefix="$1/"
    [[ "$1" == "." ]] && prefix=""
    if [[ -f "${prefix}BUILD.bazel" ]]; then printf '%sBUILD.bazel' "$prefix"; else printf '%sBUILD' "$prefix"; fi
}

# full_labels: buildozer prints `//lib` for `//lib:lib`; spell every label out.
full_labels() { awk '$1 !~ /:/ { n = split($1, part, "/"); sub(/^[^ ]+/, $1 ":" part[n]) } { print }'; }

# has_keep <build file> <start line> <end line>: the rule, or a comment line directly above it,
# holds `# keep`.
has_keep() {
    local file="$1" start="$2" end="$3" top="$2"
    while ((top > 1)) && sed -n "$((top - 1))p" "$file" | grep -q '^[[:space:]]*#'; do
        top=$((top - 1))
    done
    sed -n "${top},${end}p" "$file" | grep -qE '#[[:space:]]*keep([^[:alnum:]_]|$)'
}
