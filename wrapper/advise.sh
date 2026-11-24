#!/usr/bin/env bash
# Says how to fix what Gazelle couldn't read, after gazelle_bash() runs it. Run from the workspace
# root by run_gazelle.sh, with the files Gazelle's stdout and stderr were copied to:
#
#   advise.sh <stdout file> <stderr file>
#
# For each "Import ... is an unknown dependency" error, it prints one line of advice, picked by
# what the path is: a file with no target, a path in a submodule that isn't checked out, or a
# missing path. Then it sums up the skipped lines by the variable they start with, for the
# lines a `bash_root_vars` entry would make readable. It prints to stderr and never fails.
set -uo pipefail

out=$1
err=$2

# submodule_of <path>: the submodule of .gitmodules that holds <path>, if it isn't checked out.
submodule_of() {
    local p=$1 sub
    [[ -f .gitmodules ]] || return 1
    while read -r _ sub; do
        if [[ "$p" == "$sub"/* && -z "$(ls -A "$sub" 2>/dev/null)" ]]; then
            echo "$sub"
            return 0
        fi
    done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    return 1
}

# data_glob <path>: a bash_data_files glob that covers <path>: every file with its extension,
# or the path itself when it has none.
data_glob() {
    local base=${1##*/}
    if [[ "$base" == *.* && "$base" != .* ]]; then
        echo "**/*.${base##*.}"
    else
        echo "$1"
    fi
}

advise_unknown() {
    local id=$1 provider=$2 from=$3 file line text sub what
    file=${from%:*}
    line=${from##*:}
    [[ "$line" =~ ^[0-9]+$ ]] || { file=$from; line=""; }
    what="$from needs $id"
    [[ "$provider" == shell_tree ]] && what="$from needs everything under $id/"
    text=""
    [[ -n "$line" && -f "$file" ]] && text=$(sed -n "${line}p" "$file")
    if [[ "$provider" != shell_tree && -f "$id" ]]; then
        echo "gazelle-bash: $what, which isn't a script, so it has no target. To depend on it, add # gazelle:bash_data_files $(data_glob "$id") to the root BUILD file." >&2
    elif sub=$(submodule_of "$id"); then
        echo "gazelle-bash: $what, in the submodule $sub, which isn't checked out. Run git submodule update --init $sub, or add # gazelle-bash: ignore above that line." >&2
    elif [[ "$text" =~ ^[[:space:]]*# ]]; then
        echo "gazelle-bash: $what, which the comment on that line names, and it doesn't exist. Fix the path in the comment, or remove the comment." >&2
    else
        local dir exclude=""
        dir=$(dirname "$file")
        [[ "$dir" != . ]] && exclude=", or # gazelle:exclude $dir if that folder holds fixtures"
        echo "gazelle-bash: $what, which doesn't exist. If the file is made at run time or missing on purpose, add # gazelle-bash: ignore above that line$exclude." >&2
    fi
}

if [[ -s "$err" ]]; then
    sed -nE 's/.*Import "([^"]*)" \(provider "([^"]*)"\) from "([^"]*)" is an unknown dependency.*/\1	\2	\3/p' "$err" |
        while IFS=$'\t' read -r id provider from; do
            advise_unknown "$id" "$provider" "$from"
        done
fi

# guess_dir <var>: the directory <var> holds, if one file sets it to its own directory (or one
# above) with the cd-and-pwd idiom. Prints "<dir>\t<file>".
guess_dir() {
    local var=$1 hits file ups dir
    hits=$(grep -rElI --exclude-dir='bazel-*' --exclude-dir=.git \
        "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?${var}=[\"']?\\\$\\(cd (-- )?[\"']?(\\\$\\(dirname (-- )?[\"']?\\\$\\{?(BASH_SOURCE(\\[0\\])?|0)\\}?[\"']?\\)|\\\$\\{(BASH_SOURCE(\\[0\\])?|0)%/\\*\\})(/\\.\\.)*[\"']? *&& *pwd( -P)?\\)" . 2>/dev/null | head -2)
    [[ -n "$hits" && $(printf '%s\n' "$hits" | wc -l) -eq 1 ]] || return 1
    file=${hits#./}
    ups=$(grep -E "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?${var}=" "$file" | head -1 | grep -oE '(\)|\})(/\.\.)+' | grep -oE '\.\.' | wc -l | tr -d ' ')
    dir=$(dirname "$file")
    for ((i = 0; i < ups; i++)); do
        [[ "$dir" == . ]] && return 1
        dir=$(dirname "$dir")
    done
    printf '%s\t%s\n' "$dir" "$file"
}

[[ -s "$out" ]] || exit 0
# One line per variable: count, name, first location. Only paths that are `$VAR/rest` with no
# other expansion in rest: those a bash_root_vars entry would read.
summary=$(sed -nE 's/.*gazelle-bash: ([^ ]+): skipped [a-z]+ path that cannot be read statically: (.*)$/\1	\2/p' "$out" |
    awk -F'\t' '{
        p = $2
        gsub(/["\047]/, "", p)
        if (match(p, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\//) == 0) next
        head = substr(p, 1, RLENGTH)
        rest = substr(p, RLENGTH + 1)
        if (rest ~ /[$`*?]/ || rest == "") next
        name = head
        gsub(/[${}\/]/, "", name)
        if (name ~ /^(HOME|PWD|OLDPWD|TMPDIR|TMP|TEMP|USER|SHELL|PATH|PREFIX|XDG_[A-Z_]+)$/) next
        if (!(name in n)) first[name] = $1
        n[name]++
    }
    END { for (v in n) print n[v] "\t" v "\t" first[v] }' | sort -t$'\t' -k1,1nr -k2,2 | head -5)
[[ -n "$summary" ]] || exit 0
while IFS=$'\t' read -r count var first; do
    lines="lines start"
    [[ "$count" -eq 1 ]] && lines="line starts"
    if guess=$(guess_dir "$var"); then
        echo "gazelle-bash: $count skipped $lines with \$$var (first: $first). $(cut -f2 <<<"$guess") sets it to $(cut -f1 <<<"$guess"): add # gazelle:bash_root_vars $var=$(cut -f1 <<<"$guess") to read them." >&2
    else
        echo "gazelle-bash: $count skipped $lines with \$$var (first: $first). If it holds a fixed directory of this repo, add # gazelle:bash_root_vars $var=<that directory, from the root> to read them." >&2
    fi
done <<<"$summary"
exit 0
