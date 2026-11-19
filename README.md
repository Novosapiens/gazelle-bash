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

bazel_dep(name = "gazelle_bash", version = "0.2.0")
git_override(  # until gazelle_bash is on the Bazel Central Registry
    module_name = "gazelle_bash",
    remote = "https://github.com/Novosapiens/gazelle-bash.git",
    tag = "v0.2.0",
)
```

Root `BUILD.bazel`:

```starlark
load("@aspect_gazelle_prebuilt//:def.bzl", "aspect_gazelle")

aspect_gazelle(
    name = "gazelle",
    languages = [],  # or the built-in languages you already use, eg ["python"]
    extensions = ["@gazelle_bash//:shell.axl"],
    with_check = True,
)
```

Run it:

```sh
bazel run //:gazelle        # write BUILD files
bazel run //:gazelle.check  # CI: fail if any BUILD file is stale
```

`gazelle.check` prints the diff and exits 1, but doesn't say how to fix it. In CI, add the command:

```sh
bazel run //:gazelle.check || { echo "BUILD files are stale. Run: bazel run //:gazelle"; exit 1; }
```

## What it generates

One target per file:

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

Target names:

- A script is named after the file without its extension: `lib/log.sh` is `//lib:log`.
- If two files in a package would get the same name, the ones with an extension keep it (`foo_sh`,
  `foo_bats`).
- A script with no extension gets a `_bin` suffix (`bin/tool` is `//bin:tool_bin`), because a target can't
  have the same label as its source file.
- A data file's name has `.` and `/` replaced by `_` (`GUIDE.md` is `GUIDE_md`). A name without either
  gets a `_file` suffix (`NOTICE_file`).

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
`tags = ["manual"]`, survive regeneration. A hand-added entry in `data` does not, unless its line ends
with `# keep`; put shared entries in the macro instead.

## Settings

Set these as directives in a BUILD file. Subpackages inherit them.

| Directive | Default | Meaning |
| --- | --- | --- |
| `# gazelle:bash_dir_vars SCRIPT_DIR,HERE` | `SCRIPT_DIR` | Variable names that hold "this script's directory" |
| `# gazelle:bash_root_vars APP_ROOT=plugin,REPO=.` | none | Variables that hold a fixed directory, as `NAME=path` from the workspace root (`.` is the root) |
| `# gazelle:bash_path_dirs plugin/bin,tests/helpers` | none | Directories that tests put on `PATH`. A test depends on the commands it runs by bare name from them |
| `# gazelle:bash_data_files docs/**,*.md` | none | Non-script files tests may depend on, as globs from the workspace root. Each match gets a filegroup |
| `# gazelle:bash_shellcheck_relative_to script` | `workspace` | What a `shellcheck source=` path is relative to |
| `# gazelle:gazelle_bash disabled` | enabled | Turn the extension off for a subtree |

## Limits

- **Deleting or renaming a script leaves its old target behind.** `bazel build` then fails on the missing
  file. Delete the target by hand. Orion only removes targets an extension names, and it doesn't show
  extensions the existing BUILD file. The golden case `stale_target` pins this until Orion supports it.
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

Three checks, all run in CI:

```sh
bazel run //:gazelle.check   # the live fixtures' committed BUILD files are current
bazel test //...             # the live fixtures pass in the sandbox, plus the golden test
tests/corpus/run.sh          # 24 real open-source projects still give their recorded result
```

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

**Golden cases** (`tests/golden/cases/*`) are small workspaces that the real prebuilt Gazelle runs on.
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
| `stale_target` | Known limit: a target for a deleted file is kept |
| `data_refs` | References in tests: files, directories, wildcards, comments, escapes, paths made at run time; `bash_data_files` filegroups; a hand-written filegroup survives; the glob forms of the comment |
| `disabled` | `# gazelle:gazelle_bash disabled` turns it off for a subtree only |
| `path_dirs` | Commands run by bare name: after `run` and its options, `\|`, `&&`, `;`, `!`, `$( )`, assignments and `if`; a `.sh` command; two directories; not builtins, arguments, comments, system commands or libraries |
| `map_kind` | Generated tests use the mapped macro, a subpackage inherits it, and an existing mapped target keeps its hand-added `tags` |
| `bazel_symlinks` | Bazel's `bazel-bin`, `bazel-out`, `bazel-testlogs` and `bazel-<name>` links don't stop generation |
| `multiline_string` | Lines inside multi-line `"…"`, `'…'` and `$'…'` strings are not read; an apostrophe in a comment is not a quote; when the tracker loses count, every line is read |
| `ignore` | `# gazelle-bash: ignore` above a line or at its end, for `source`, `.` and `load` |
| `path_lookup` | `source name` with no slash: a dependency when the file is next to the script, skipped with a message when it isn't |
| `sourced_data_file` | A sourced non-script file resolves once `bash_data_files` names it |

```sh
bazel run //tests/golden:golden_test -- --update      # rewrite BUILD.out files from actual output
bazel run //tests/golden:golden_test -- heredoc       # run one case
```

Review the `git diff` after `--update`. It records whatever the plugin did, right or wrong.

**The corpus** ([tests/corpus](tests/corpus)) runs the plugin on 24 open-source shell projects pinned to
a commit, about 3,800 scripts and bats files. For each it checks that generation gives the recorded result
and that Bazel can analyse the generated targets. The projects' code is only read, never run.

`shell.axl` started as [aspect-starters/shell](https://github.com/aspect-starters/shell)
(Apache-2.0). Licence: Apache-2.0.
