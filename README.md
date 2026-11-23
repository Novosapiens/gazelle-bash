# gazelle_bash

A [Gazelle](https://github.com/bazel-contrib/bazel-gazelle) extension that writes Bazel BUILD targets for
Bash scripts and [bats](https://github.com/bats-core/bats-core) tests, so `bazel test` runs only the tests a
change can affect.

It is a single Starlark file, [`shell.axl`](shell.axl), run by Aspect's prebuilt Gazelle
([Orion](https://github.com/aspect-build/aspect-gazelle/blob/main/language/orion/README.md)). You don't need a
Go toolchain.

## Use it in your repo

`MODULE.bazel`:

```starlark
bazel_dep(name = "aspect_gazelle_prebuilt", version = "0.0.29")
bazel_dep(name = "rules_shell", version = "0.10.0")
bazel_dep(name = "bazel_lib", version = "3.8.0")

bazel_dep(name = "gazelle_bash", version = "0.7.0")
git_override(  # until gazelle_bash is on the Bazel Central Registry
    module_name = "gazelle_bash",
    remote = "https://github.com/Novosapiens/gazelle-bash.git",
    tag = "v0.7.0",
)
```

Root `BUILD.bazel`:

```starlark
load("@gazelle_bash//:defs.bzl", "gazelle_bash")

gazelle_bash(
    name = "gazelle",
    languages = [],  # or the built-in languages you already use, eg ["python"]
    with_check = True,
)
```

`gazelle_bash()` is Aspect's `aspect_gazelle()` with `shell.axl` loaded, plus a step before it that
removes the targets of deleted files (see "Deleted and renamed files") and two after it: one writes a
bats test's `tags` from its bats tags (see "Tags from bats tags"), the other sorts each BUILD file's
rules by name (see "Rule order"). It takes the same arguments: add other Orion extensions
with `extensions`.

Run it:

```sh
bazel run //:gazelle        # write BUILD files
bazel run //:gazelle.check  # CI: fail if any BUILD file is stale
```

`aspect_gazelle(extensions = ["@gazelle_bash//:shell.axl"])` still works, without removing stale targets
or sorting rules.

`gazelle.check` prints the diff and exits 1, but doesn't say how to fix it. In CI, add the command:

```sh
bazel run //:gazelle.check || { echo "BUILD files are stale. Run: bazel run //:gazelle"; exit 1; }
```

## What it generates

One target per file, by default (see "One target per directory" for the other mode):

| Input | Output |
| --- | --- |
| `*_test.sh` | `sh_test` |
| Any other `*.sh` / `*.bash` | `sh_library` |
| No extension, first line a `sh` or `bash` shebang (also through `env`) | `sh_library` |
| `*.bats` | `bats_test` (from `@bazel_lib//lib:bats.bzl`) |
| A file matching `bash_data_files` | `filegroup` |

A command is an `sh_library`, not an `sh_binary`. `bats_test` gives a test the files of its `data` targets
but not their runfiles, and only `sh_library` passes on the files of what it depends on. With an
`sh_binary` in the chain, a bats test that runs a command would not get the libraries the command sources.
To `bazel run` a script, write an `sh_binary` for it by hand.

Libraries and filegroups are visible to `//:__subpackages__`, so any script in the repo can use them.
Tests get no visibility: nothing depends on a test. To narrow who may depend on a package's targets,
see "Visibility".

Target names:

- A script is named after the file without its extension: `lib/log.sh` is `//lib:log`.
- If two files in a package would get the same name, the ones with an extension keep it (`foo_sh`,
  `foo_bats`).
- A script with no extension gets a `_bin` suffix (`bin/tool` is `//bin:tool_bin`), because a target can't
  have the same label as its source file.
- A data file's name has `.` and `/` replaced by `_` (`GUIDE.md` is `GUIDE_md`). A name without either
  gets a `_file` suffix (`NOTICE_file`).

### One target per directory

One target per file is the default, because Bazel can then skip every test a change cannot reach. The
cost is a BUILD file that grows one rule block per script. Through `gazelle_bash()` a new block goes at
its place by name (see "Rule order"), so two branches that each add a script to the same directory
conflict only when the scripts' names sort next to each other; without it, every new block goes at the
end of the file, and they always conflict.

To get one target per directory instead, as Go's `go_library` and rules_python's
`python_generation_mode package` do, set:

```starlark
# gazelle:bash_generation_mode package
```

In that package and the packages below it:

| Input | Output |
| --- | --- |
| Every library and command in the directory | One `sh_library`, named after the directory, with the files in a sorted `srcs` |
| Every file matching `bash_data_files` | One `filegroup`, named `<directory>_files` |
| Each `*_test.sh` and `*.bats` | One test target each, as before |

```starlark
sh_library(
    name = "lib",                   # //tools/lib
    srcs = ["log.sh", "strings.sh", "tool"],
    data = ["//:root", "//tools/lib/plugins"],
)

bats_test(
    name = "lib_bats",              # lib.bats; renamed so it doesn't clash with the library
    srcs = ["lib.bats"],
    data = [":lib"],
)
```

- Adding a library then adds one line to `srcs` instead of a new block. Two branches conflict only when
  their file names sort next to each other.
- The library's `data` is everything any of its files sources, runs and reads. A file in the same target
  isn't listed.
- At the workspace root, which has no directory name, the library is named `root` (`root_files` for the
  filegroup).
- A test whose name would clash with the library or the filegroup folds its extension in: `lib.bats` is
  `lib_bats` and `lib_test.sh` stays `lib_test`.
- Set `# gazelle:bash_generation_mode file` in a subpackage to switch back for that subtree.

The trade-offs:

- **Tests rerun more often.** A change to any file in the directory reruns every test that depends on
  its target, and a test gets the files its target's siblings need as well as the ones it uses.
- **Directories that hold mostly tests barely change.** Tests keep one target each, so adding one still
  adds a block. Folding tests together would make Bazel rerun all of them on every change.
- **Coarser targets can form a cycle.** If `a/x.sh` sources `b/y.sh` and `b/z.sh` sources `a/w.sh`, the
  files don't form a cycle but the two directory targets do, and Bazel rejects it. Move a file or put
  `# gazelle-bash: ignore` on one direction.

Switching an existing directory to `package` removes its per-file targets in the same run, unless they
have `# keep`.

### A BUILD file per folder

Under Gazelle's default `# gazelle:generation_mode create_and_update`, each run writes a BUILD file in
every folder that holds a script, a test or a `bash_data_files` match, and keeps it as folders change:

| The folder is | Through `gazelle_bash()`, the next run |
| --- | --- |
| Added | Writes its BUILD file. A folder with nothing to build, or one under `# gazelle:exclude`, gets none |
| Renamed (`git mv lib util`) | Removes the moved BUILD file's `lib`, `lib_files` and `lib_bats` and generates `util`, `util_files` and `lib` for the same files; every generated `data` that pointed at `//lib` now points at `//util` |
| Deleted, with its BUILD file | Drops the generated `data` labels that pointed into it |
| Deleted, but its BUILD file is left | Also removes that BUILD file, and the folder, once all its rules are stale |

A source line that still names a script of the old folder fails generation, as any path to a missing
script does: update it, and the label follows. Under `update_only`, Gazelle never writes a BUILD file,
so a new folder's scripts belong to no target until one is added.

## Deleted and renamed files

Before Gazelle runs, `gazelle_bash()` removes a target whose files are all gone. A rule is removed when:

- its kind is one this extension generates (`sh_library`, `sh_test`, `bats_test`, `filegroup`), or one
  a `# gazelle:map_kind` maps them to;
- its `srcs` is a list of plain file names in its own package, and none of those files exists;
- no rule in the package is named after one of those files or lists it in `outs`, so a genrule's output
  is not mistaken for a deleted file;
- neither the rule nor a comment line directly above it says `# keep`.

A rule with a `glob()`, a label or a subdirectory path in `srcs` is never removed, nor is a rule of any
other kind, such as a hand-written `sh_binary`. Directories Gazelle skips (`# gazelle:exclude`, files
git ignores, `# gazelle:gazelle_bash disabled`) are skipped too. Each removal is printed:

```
gazelle-bash: removed //tools:old: its files are gone: old.sh
```

`gazelle.check` doesn't change anything: it lists the stale targets and fails, so CI catches a deleted
script before `bazel build` does. `bazel run //:gazelle -- some/dir` limits the step to that directory, as
it limits Gazelle.

A rule left with only some of its files is not removed: Gazelle updates its `srcs`.

Two more cases are removed, for folders (see "A BUILD file per folder"):

- In a `package` mode directory, a rule whose files all exist but whose name belongs to another
  directory's package targets: a library not named after the directory, a `*_files` filegroup not
  named `<directory>_files`, and a test folded to `<file>_<ext>` though it clashes with nothing. The
  directory was renamed. This also removes a hand-written `sh_library` there; add `# keep` to keep it.
- A BUILD file that is the only file left in its directory, when every rule in it is stale, and it has
  no `# gazelle:` directive and no `# keep`. The directory goes with it:

```
gazelle-bash: removed lib/BUILD.bazel: nothing else is left in its directory
```

## Rule order

Gazelle adds a new rule at the end of its BUILD file. Two branches that each add a test to one directory
then both add a block at the same place, and a merge conflicts. After Gazelle runs, `gazelle_bash()` sorts
each BUILD file's rules by name, so a new rule goes where its name puts it:

- The rules sorted are those of the kinds this extension generates, and of the kinds a
  `# gazelle:map_kind` maps them to, hand-written ones included.
- They swap places among themselves, in byte order of their names (`run`, `run-check`, `run_files`): a
  `load()`, a comment block between rules and a rule of another kind, such as a hand-written `sh_binary`,
  stay where they are. A rule takes the comment lines directly above it along.
- A rule with `# keep`, or with it in a comment line directly above, stays where it is.
- The first run after upgrading reorders an existing BUILD file once; later runs only place new rules.

`gazelle.check` doesn't change anything: it names each BUILD file whose rules are out of order and fails.

Two branches that add tests whose names sort next to each other still both add a block at the same place.
Git's text merge reports a conflict there. Don't give such a BUILD file git's `merge=union` driver: it
keeps the lines the two new blocks share (`)`, the blank line, the kind's opening line) once, and merges
them into one rule with two `name`s, which Bazel can't load.

## Dependencies

Every dependency goes in `data`. It accepts scripts and plain files alike, and it is the only dependency
attribute `bats_test` has.

| In the file | Becomes |
| --- | --- |
| `source path` or `. path` at the start of a line | `data` |
| bats `load name` | `data`, pointing at `name.bash` |
| In a test, any `$VAR/path` whose `VAR` is in `bash_root_vars` | `data` |
| In a test, a command run by bare name that is a file in a `bash_path_dirs` directory | `data` |
| `# gazelle-bash: dep path` | `data` |
| `# shellcheck source=path` | `data` |

Each path resolves to the label of the target that owns that script, in any package. Heredoc bodies and
multi-line quoted strings are not read.

Before a path is resolved, any of these leading "directory of this script" idioms is stripped. Whatever
remains is then resolved against the script's own directory:

```
$(dirname "${BASH_SOURCE[0]}")/    ${BASH_SOURCE%/*}/    ${0%/*}/    $(dirname "$0")/
$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/    $BATS_TEST_DIRNAME/    $SCRIPT_DIR/
```

`$(cd DIR && pwd)/` is read as `DIR/`, so `$(cd "$(dirname "$0")/.." && pwd)/lib/x.sh` resolves to
`../lib/x.sh` from the script.

A path that starts with a variable listed in `bash_root_vars` resolves from that variable's directory
instead. With `# gazelle:bash_root_vars APP_ROOT=plugin`, `. "$APP_ROOT/lib/x.sh"` means `plugin/lib/x.sh`
in every script.

- **Literal path that matches no script:** generation fails, so a typo or a deleted library can't silently
  drop a dependency.
- **Path still containing `$`, a glob or a backtick:** it is skipped and the skip is printed with its file and
  line. Declare it with a comment on the line above. No message is printed then.
- **`source name` with no slash, and no such file next to the script:** it is skipped and printed. Bash
  looks up a bare name on `PATH` first, so this is a tool's own library such as `virtualenvwrapper.sh`.
- **A line the plugin should not read:** put `# gazelle-bash: ignore` on the line above, or at the end of
  the line. Use it for a file made at run time, vendored code that isn't checked out, or a path that is
  missing on purpose. To skip a whole directory, use Gazelle's own `# gazelle:exclude path`.

```bash
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"

# gazelle-bash: dep plugins/*.sh
for p in "$here"/plugins/*.sh; do source "$p"; done

# gazelle-bash: ignore
source ./generated_at_install.sh
```

A `gazelle-bash: dep` path is relative to the script's directory. It is relative to the workspace root when
it starts with `//`, and to a `bash_root_vars` directory when it starts with that variable. A path that ends
in `/` or holds a wildcard means every dependable file under that directory, subdirectories included: the
wildcard itself is not applied, so `plugins/*.sh` and `plugins/` mean the same. The comment can also be
written `# gazelle:sh_dynamic_dep path` or `# gazelle:bats_data path`; all three do the same thing.

A `shellcheck source=` path is relative to the workspace root, as when ShellCheck runs from the repo root.
A path that starts with `SCRIPTDIR/` or `../` is relative to the script's directory. The path can be quoted
and can hold spaces. `source=/dev/null` is ignored.

A sourced file that is not a script, such as `math.inc` or a config file, needs a target before it can be
depended on. List it in `bash_data_files`, for example `# gazelle:bash_data_files **/*.inc`.

### What a test reads

Sourcing is not the only way a test depends on a file: it runs commands and reads documents. Tell the
extension which variables hold a fixed directory, and which non-script files tests may read:

```starlark
# gazelle:bash_root_vars APP_ROOT=plugin,REPO=.
# gazelle:bash_data_files docs/**,*.md,tests/fixtures/**
```

Then in every `.bats` and `*_test.sh` file, each `$APP_ROOT/...` or `${REPO}/...` becomes a dependency:

| In the test | Becomes |
| --- | --- |
| `"$APP_ROOT/bin/tool"` | That command's target, which brings the libraries it sources |
| `"$REPO/docs/GUIDE.md"` | That file's filegroup |
| `"$REPO/docs/notes/"`, `$REPO/docs/notes/*.md` or the directory without a `/` | Every dependable file under `docs/notes` |

These references are read anywhere on a line, including strings and heredocs, but not in full-line
comments. Unlike a `source` line, one that matches nothing is dropped without a message: a test may name a
path it creates itself. A test that reads a file it didn't declare fails in the sandbox, which is the check.
A reference with a `$` later in the path is printed as skipped, like a `source` line.

Only tests have their references read. In a library or command, a mention of another command would often
make a dependency cycle, so declare those with a comment.

### Commands a test runs by name

Tests often put a `bin/` directory on `PATH` and run its commands by bare name. Tell the extension which
directories those are:

```starlark
# gazelle:bash_path_dirs plugin/bin,tests/helpers
```

Then in every `.bats` and `*_test.sh` file, a word in command position that names a file in one of those
directories becomes a dependency on that file's target:

```bash
run gh-board issues       # after `run`, also `run -0 …` and `run ! …`
gh-board | grep open      # at the start of a line, and after | && || ; !
count="$(gh-board count)" # inside $( ) and backticks
DEBUG=1 gh-board          # after assignments, and after if, then, do, exec, command, env, …
```

- A word that matches no file is dropped without a message. Most are system commands such as `git`.
- Bash builtins and keywords (`echo`, `test`, `cd`, …) are never matched, because Bash runs its own.
- If two listed directories hold the same name, the test depends on both files. The extension can't see
  which one `PATH` would pick.
- A command named only inside a quoted string, such as `bash -c "gh-board x"`, is not seen. Declare it
  with a comment.
- A word that isn't really a command, such as a `case` label, can add a dependency the test doesn't need.
  That costs an extra test run, never a wrong build.

A file can only be depended on if it has a target: a script, or a file that matches `bash_data_files`. Each
directory holding such files gets a BUILD file.

## Shared settings for tests

To give every test the same extra settings, such as an `env` value, a tool in `data` or a `size`, write a
macro and map the generated kind to it with Gazelle's own `map_kind` directive:

```starlark
# gazelle:map_kind bats_test my_bats_test //tests:defs.bzl
# gazelle:map_kind sh_test my_sh_test //tests:defs.bzl
```

```starlark
# tests/defs.bzl
load("@bazel_lib//lib:bats.bzl", "bats_test")

def my_bats_test(name, data = [], env = {}, **kwargs):
    bats_test(
        name = name,
        data = data + ["@jq"],
        env = dict(env, JQ = "$(rlocationpath @jq)"),
        **kwargs
    )
```

The directive applies to its own package and every package below it. The macro must accept what the
extension writes: `name`, `srcs` and `data`. Attributes added by hand to one target, such as
`size = "small"` or `tags = ["exclusive"]`, survive regeneration. A hand-added entry in `data` does not,
unless its line ends with `# keep`; put shared entries in the macro instead.

A hand-added attribute lasts only as long as its target. Once the target is created again, after its
BUILD file was deleted or a merge kept the side without it, the attribute is gone and nothing reports it.
For a tag a test needs, declare it in the test file instead: see "Tags from bats tags".

Adding `map_kind` to a repo that already has generated targets works in one run with `gazelle_bash()`.
Before Gazelle runs, each existing rule of the mapped kind in the directive's packages takes the new
kind and keeps its attributes and comments, and Gazelle replaces the old `load()` with the macro's:

```
gazelle-bash: //tests:a is now a my_bats_test (map_kind)
```

Hand-written rules of that kind, and rules with `# keep`, are renamed too: Gazelle can't keep a rule
under a kind it no longer generates. `gazelle.check` lists the rules to rename and fails.

Removing `map_kind` again is not undone for you, because nothing then says `my_bats_test` was once a
`bats_test`. Rename the rules back before running Gazelle:

```sh
bazel run @buildozer -- 'set kind bats_test' //...:%my_bats_test
```

## Tags from bats tags

A test that must not run everywhere needs a Bazel tag, such as `manual` or `requires-network`. bats has
tags of its own, written in the test file. `bats_tags` names the bats tags that become Bazel `tags` on
the test's target, so the tag is declared once, next to the test, and comes back when the target is
created again:

```starlark
# gazelle:bats_tags structure=manual+structure,requires-network
```

```bash
# tests/layout.bats
# bats file_tags=structure

@test "every plugin has a manifest" { … }
```

```starlark
bats_test(
    name = "layout",
    srcs = ["layout.bats"],
    tags = [
        "manual",
        "structure",
    ],
)
```

- Each entry is a bats tag. After `=` come the Bazel tags it becomes, joined by `+`; with no `=`, it
  becomes the tag of the same name.
- A bats tag the directive doesn't name is not carried over: most bats tags, such as `issue:123`, mean
  nothing to Bazel.
- A file has a bats tag when a `# bats file_tags=` or a `# bats test_tags=` line names it. bats tags one
  test and Bazel a whole file, so one tagged test tags the target.
- The directive applies to its package and those below it. One in a package below replaces it, and
  `# gazelle:bats_tags` with no value switches it off there.

The Bazel tags the directive names are then written from the test files alone, on every `bats_test`
there, and on the kind a `map_kind` maps it to:

| On the target | In the test file | After `bazel run //:gazelle` |
| --- | --- | --- |
| no `requires-network` | a bats tag that maps to it | added |
| `requires-network` | no bats tag that maps to it | removed |
| a tag the directive doesn't name, such as `exclusive` | anything | left alone |

So with the directive above, `manual` on a bats test comes only from the bats tag `structure`: written
by hand on another bats test, it is removed. To keep one by hand, end its line with `# keep`:

```starlark
    tags = [
        "manual",  # keep
    ],
```

A rule with `# keep` on its first line or in a comment line directly above, and a `tags` line that ends
with `# keep`, are left alone entirely.

Each change is reported:

```
gazelle-bash: //tests:layout gets the tags manual, structure from the bats tags of layout.bats (bats_tags)
gazelle-bash: //tests:fetch loses the tag requires-network, which no bats tag of fetch.bats asks for (bats_tags)
```

`gazelle.check` doesn't change anything: it names each target whose tags differ and fails.

Before adding the directive to a repo that already has tags written by hand, add the matching bats tag
to each test file, or the first run removes the tags the directive names from the targets whose files
lack it. `gazelle.check` lists them first.

## Visibility

Visibility says who may depend on a target. By default every library and filegroup gazelle-bash writes
is visible to `//:__subpackages__`, the whole repo. To let only some packages depend on a package's
targets, name them:

```starlark
# gazelle:bash_visibility //tests/repo:__pkg__,//ci:__subpackages__
```

- Each entry is a label, as in a rule's `visibility`.
- The directive applies to its package and those below it. One in a package below replaces it, so
  `# gazelle:bash_visibility //:__subpackages__` there restores the default.
- Every library and filegroup there gets it: new ones, and ones already in the BUILD file, whose
  `visibility` is replaced. So `gazelle.check` fails on a generated rule whose visibility differs.
- Tests keep no visibility.

`visibility` is generated like `srcs`, also with no directive: a visibility set by hand on a generated
library or filegroup is replaced by the default. To keep one, end its line with `# keep`:

```starlark
    visibility = ["//tools:__pkg__"],  # keep
```

## Settings

Set these as directives in a BUILD file. Subpackages inherit them.

| Directive | Default | Meaning |
| --- | --- | --- |
| `# gazelle:bash_dir_vars SCRIPT_DIR,HERE` | `SCRIPT_DIR` | Variable names that hold "this script's directory" |
| `# gazelle:bash_root_vars APP_ROOT=plugin,REPO=.` | none | Variables that hold a fixed directory, as `NAME=path` from the workspace root (`.` is the root) |
| `# gazelle:bash_path_dirs plugin/bin,tests/helpers` | none | Directories that tests put on `PATH`. A test depends on the commands it runs by bare name from them |
| `# gazelle:bash_data_files docs/**,*.md` | none | Non-script files tests may depend on, as globs from the workspace root. Each match gets a filegroup |
| `# gazelle:bash_shellcheck_relative_to script` | `workspace` | What a `shellcheck source=` path is relative to |
| `# gazelle:bash_generation_mode package` | `file` | `file`: one target per script. `package`: one library and one filegroup per directory, one target per test. See "One target per directory" |
| `# gazelle:bats_tags structure=manual+structure,requires-network` | none | bats tags that become Bazel `tags` on a bats test, as `NAME` or `NAME=tag+tag`. A directive below replaces the one above. See "Tags from bats tags" |
| `# gazelle:bash_visibility //tests:__subpackages__` | `//:__subpackages__` | Who may depend on the libraries and filegroups gazelle-bash writes, as labels. A directive below replaces the one above. See "Visibility" |
| `# gazelle:gazelle_bash disabled` | enabled | Turn the extension off for a subtree |

## Limits

- **Stale targets are removed, tags written from bats tags, and rules sorted, only through
  `gazelle_bash()`.** Orion doesn't show an extension the existing BUILD file or let it choose where a
  rule goes, and Gazelle's merge can't own some values of a `tags` list, so these run as separate steps
  before and after Gazelle, using [buildozer](https://github.com/bazelbuild/buildtools/tree/main/buildozer).
  With plain `aspect_gazelle()`, delete the target of a deleted script by hand.
- **With plain `aspect_gazelle()`, adding `map_kind` fails** with "a target of kind bats_test with the
  same name already exists", because Orion won't replace a rule of another kind. Rename the existing
  rules first: `bazel run @buildozer -- 'set kind my_bats_test' //...:%bats_test`.
- **A deleted file whose name holds a space, quote or backslash keeps its target.** buildozer prints a
  `srcs` list without quotes, so such a name can't be told apart reliably; the step leaves the rule alone.
- **A hand-written `filegroup` (or other generated kind) whose listed files are all gone is removed.**
  Bazel couldn't build it anyway. Add `# keep` to keep it.
- **Commands on `PATH`** (`git`, `jq`, `gh`) are not tracked. Tests use whatever the machine has.
- **Only lines that start with `source`, `.` or `load` are read.** A `source` after `then`, `&&` or `;` on
  the same line is missed. Use a comment for those.
- **Two scripts that source each other make a dependency cycle**, which Bazel rejects. Put
  `# gazelle-bash: ignore` on one direction. The other direction still brings both files to a test.
- **A symlink that points at a directory stops generation** with "is a directory". This is Orion reading
  the link as a file. Exclude it with `# gazelle:exclude path/to/link`. Bazel's own `bazel-*` links at the
  workspace root are already skipped.
- **Scripts that find their own directory with `realpath` or `readlink` fail under Bazel.** Tests run in a
  runfiles tree of symlinks, so the real path points outside the sandbox. Sourcing relative to
  `BASH_SOURCE` or `$0` works.
- **A reference in a test body that matches nothing is dropped silently.** See "What a test reads".
- **A wildcard in a declared path selects the whole directory tree**, not only the files the wildcard
  matches.
- **Every file with no extension is read** to check its first line, and with `bash_data_files` set, every
  file is. On a large repo this slows generation.

## Developing

Four checks, all run in CI:

```sh
bazel run //:gazelle.check        # the live fixtures' committed BUILD files are current
bazel test //...                  # the live fixtures pass in the sandbox, plus the golden test
bazel run //tests/lifecycle:run   # a folder added, renamed, deleted and excluded, in a host repo
tests/corpus/run.sh               # 24 real open-source projects still give their recorded result
```

**The lifecycle run** builds a host repo in `create_and_update` and `package` mode and takes a folder
through its life. After each step it runs `//:gazelle`, then `gazelle.check` and `bazel build //...`
in the host repo, and queries its targets and `data` labels:

| Step | Checks |
| --- | --- |
| A new folder with a script | It gets a BUILD file with its library and filegroup, and another folder's test depends on them |
| An excluded folder | It gets no BUILD file, though its script sources a file that isn't there |
| `git mv lib util` | `//util` holds `util` and `util_files`, and no label points at `//lib` |
| The folder's files deleted, its BUILD file left | The BUILD file is gone, no label points at `//util`, and only `//app` is left |

It runs Bazel itself, so it is a `bazel run` target and not part of `bazel test //...`. Pass a
directory to keep the host repo and its logs: `bazel run //tests/lifecycle:run -- /tmp/lifecycle`.

**Live fixtures** (`tests/*`, except `golden`) are generated in place and run as real tests. Passing proves
the declared dependencies are complete, because an undeclared file is not in the sandbox.

| Fixture | Proves |
| --- | --- |
| `library_only` | Scripts without a shebang become one `sh_library` each |
| `binary_sources_lib` | A `source` / `.` line becomes a dependency |
| `data_refs` | A bats test gets the command it runs (with the library that command sources), a file it names and a directory it names |
| `bats_basic` | A `.bats` file becomes a `bats_test` that passes |
| `bats_load_helper` | `load helper` pulls in `helper.bash` |
| `cross_package` | Sourcing from another directory resolves to that package's label |
| `dynamic_source` | A runtime-built path is skipped and generation still succeeds |
| `comment_dep` | The comment adds a dependency the parser cannot see |
| `extensionless` | A command with no file extension gets a target a test can depend on |
| `shebang_lib` | Sourcing a script with a shebang works, through two levels of sourcing |
| `path_commands` | A bats test runs a command by bare name, with `bin/` put on `PATH` by a helper, and gets the command and the library it sources |
| `shared_settings` | `map_kind` sends bats tests through a macro that supplies an env value, in the package and below it |
| `package_mode` | With `bash_generation_mode package`, one library target holds a script and the sibling it sources, and tests inside and outside the package pass with only that target |

**Golden cases** (`tests/golden/cases/*`) are small workspaces that the real prebuilt Gazelle runs on,
through `//:gazelle`, so the stale-target step runs first and the tags and sort steps last.
They cover what a live fixture can't: generation errors, BUILD files that exist beforehand, and inputs
that would break the repo's own generation. Each case can hold:

- `BUILD.in`: the BUILD file before the run
- `BUILD.out`: the expected result
- `expected_exit_code`
- `expected_output`: lines that must appear in Gazelle's output
- `make_symlinks`: symlinks to create in the copy, as `<link> <target>` lines

| Case | Pins |
| --- | --- |
| `extensionless` | Files with no extension: `sh`, `bash` and `env` shebangs get a target; Python, a late shebang and plain text don't; the `_bin` name, also next to `dup.sh` and `clash_bin.sh` |
| `heredoc` | `source` lines inside heredocs are ignored; `<<<`, `$((1 << 2))` and a stray `"a << b"` are not heredocs |
| `missing_literal` | A literal path to no script fails generation with a clear error |
| `path_forms` | Quoting, comments, `\|\|`/`;`, `. ./`, `dirname --`, `${VAR}`, `//` comments, `bash_dir_vars` (comma list), bats `load` forms, name collisions, skipped paths |
| `root_vars` | `bash_root_vars` in `$VAR` and `${VAR}` form, `$(cd … && pwd)/` with `..` and redirections, the line number in a skip message |
| `shellcheck` | `source=` (workspace- and script-relative), `SCRIPTDIR/`, `../`, a quoted path with a space, `/dev/null`, combined directives |
| `source_shebang` | A sourced script with a shebang is an `sh_library` referenced through `data` |
| `hand_edits` | Hand-added attributes and targets survive regeneration |
| `stale_target` | Targets of deleted and renamed files are removed: `sh_library`, `bats_test`, a data `filegroup`, a mapped kind. A hand-written `sh_binary`, `# keep`, a `glob()`, a label and a genrule's output survive, and so do excluded and disabled directories |
| `data_refs` | References in tests: files, directories, wildcards, comments, escapes, paths made at run time; `bash_data_files` filegroups; a hand-written filegroup survives; the glob forms of the comment |
| `disabled` | `# gazelle:gazelle_bash disabled` turns it off for a subtree only |
| `path_dirs` | Commands run by bare name: after `run` and its options, `\|`, `&&`, `;`, `!`, `$( )`, assignments and `if`; a `.sh` command; two directories; not builtins, arguments, comments, system commands or libraries |
| `map_kind` | Generated tests use the mapped macro, a subpackage inherits it, and an existing mapped target keeps its hand-added `tags` |
| `map_kind_added` | `map_kind` added to existing generated targets: each takes the mapped kind with its `tags`, `size` and comments, including one with `# keep` and one in a subpackage; a stale one is removed instead; a hand-written `sh_binary` is untouched |
| `bats_tags` | `bats_tags`: a new target gets its tags from `test_tags` on one test and from `file_tags`, one bats tag becoming two; an unnamed bats tag is not carried over; on an existing target a mapped tag is added and removed, a hand-added tag and one with `# keep` stay; a directive with no value switches it off in a subpackage |
| `visibility` | `bash_visibility`: a new library, filegroup and package-mode target get the named labels and a test gets none; an existing rule's visibility is replaced unless the line has `# keep`; a subpackage inherits it, and one with its own directive gets that one; no directive gives `//:__subpackages__` |
| `visibility_invalid` | A `bash_visibility` entry that is not a label fails generation with a clear error |
| `bazel_symlinks` | Bazel's `bazel-bin`, `bazel-out`, `bazel-testlogs` and `bazel-<name>` links don't stop generation |
| `multiline_string` | Lines inside multi-line `"…"`, `'…'` and `$'…'` strings are not read; an apostrophe in a comment is not a quote; when the tracker loses count, every line is read |
| `ignore` | `# gazelle-bash: ignore` above a line or at its end, for `source`, `.` and `load` |
| `path_lookup` | `source name` with no slash: a dependency when the file is next to the script, skipped with a message when it isn't |
| `sourced_data_file` | A sourced non-script file resolves once `bash_data_files` names it |
| `generation_mode` | `bash_generation_mode package`: one library and one filegroup per directory; no self-dependency from a sibling `source` or a `dep ./`; a test named after its directory; `root` at the workspace root; inherited by a subpackage; `file` in a subpackage restores per-file targets |
| `generation_mode_add` | In `package` mode, a new file adds one line to the existing target's `srcs`, and hand-added attributes survive |
| `generation_mode_switch` | Switching a directory to `package` mode removes its per-file targets, keeps one with `# keep` and a hand-written `sh_binary`, and replaces a test that held the package's name |
| `generation_mode_invalid` | An unknown `bash_generation_mode` value fails generation with a clear error |
| `folder_created` | Under `create_and_update`, a new folder and a nested one each get a BUILD file; an excluded folder and one with no script get none |
| `folder_renamed` | A `package` mode folder moved with its BUILD file: its targets take the new folder's names, and the labels in another folder follow; a rule with `# keep` and a hand-written `sh_binary` stay |
| `folder_deleted` | A BUILD file left alone in a deleted folder is removed, and so is the label that pointed into it; one with a directive, or a rule of another kind, stays |

```sh
bazel run //tests/golden:golden_test -- --update      # rewrite BUILD.out files from actual output
bazel run //tests/golden:golden_test -- heredoc       # run one case
```

Review the `git diff` after `--update`. It records whatever the plugin did, right or wrong.

**The stale-target step on its own** is tested by `//wrapper:prune_test`: check mode reports without
changing anything, a second run finds nothing, directory arguments limit it, git-ignored directories are
skipped, a tracked BUILD file that was deleted doesn't stop it, a file name with a space never counts as
deleted, a BUILD file left alone in a deleted directory goes, and a renamed directory's targets are found.

**The sort step on its own** is tested by `//wrapper:sort_test`: check mode reports without changing
anything; a `load()`, a header comment, a rule of another kind and a rule with `# keep` stay put while a
rule's own comment moves with it; byte order and names with a space; mapped kinds; directory arguments;
disabled packages; and a second run changes nothing.

**The tags step on its own** is tested by `//wrapper:bats_tags_test`: check mode reports a missing and
a left-over tag without changing anything, and a second run finds nothing; `file_tags`, several tags on
a line and one bats tag that becomes two; the last tag removed leaves no empty `tags`; `# keep` on a
rule, above it, on `tags` and on one tag; a subpackage that inherits, replaces or switches off the
directive; mapped kinds; directory arguments; excluded packages; names with a space; and no directive.

These tests, and the golden test, also run from a host repo with `gazelle_bash` overridden to a local
checkout, eg `bazel test @gazelle_bash//wrapper:all --override_module=gazelle_bash=../gazelle-bash`.

**The corpus** ([tests/corpus](tests/corpus)) runs the plugin on 24 open-source shell projects pinned to
a commit, about 3,800 scripts and bats files. For each it checks that generation gives the recorded result
and that Bazel can analyse the generated targets. The projects' code is only read, never run.

`shell.axl` started as [aspect-starters/shell](https://github.com/aspect-starters/shell)
(Apache-2.0). Licence: Apache-2.0.
