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

bazel_dep(name = "gazelle_bash", version = "0.1.0")
git_override(  # until gazelle_bash is on the Bazel Central Registry
    module_name = "gazelle_bash",
    remote = "https://github.com/<owner>/gazelle-bash.git",
    commit = "<sha>",
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

## What it generates

One target per file:

| Input | Output |
| --- | --- |
| `*_test.sh` | `sh_test` |
| `*.sh` / `*.bash` starting with a `#!…sh` shebang | `sh_binary` |
| `*.sh` / `*.bash` without a shebang | `sh_library` |
| `*.bats` | `bats_test` (from `@bazel_lib//lib:bats.bzl`) |

Libraries and binaries are visible to `//:__subpackages__`, so any script in the repo can source them.
Targets are named after the file without its extension. If two files in a package would get the same name,
both keep the extension instead (`foo_sh`, `foo_bats`).

## Dependencies

Every dependency goes in `data`. `deps` would reject a sourced script that has a shebang, because that
script is an `sh_binary`. Both attributes put the file in the runfiles, including files sourced in turn.

| In the script | Becomes |
| --- | --- |
| `source path` or `. path` at the start of a line | `data` |
| bats `load name` | `data`, pointing at `name.bash` |
| `# gazelle-bash: dep path` | `data` |
| `# shellcheck source=path` | `data` |

Each path resolves to the label of the target that owns that script, in any package. Lines inside heredocs
are not read.

Before a path is resolved, any of these leading "directory of this script" idioms is stripped. Whatever
remains is then resolved against the script's own directory:

```
$(dirname "${BASH_SOURCE[0]}")/    ${BASH_SOURCE%/*}/    ${0%/*}/    $(dirname "$0")/
$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/    $BATS_TEST_DIRNAME/    $SCRIPT_DIR/
```

- **Literal path that matches no script:** generation fails, so a typo or a deleted library can't silently
  drop a dependency.
- **Path still containing `$`, a glob or a backtick:** it is skipped and the skip is printed. Declare it with
  a comment on the line above. No message is printed then.

```bash
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"

# gazelle-bash: dep plugins/hello.sh
for p in "$here"/plugins/*.sh; do source "$p"; done
```

A `gazelle-bash: dep` path is relative to the script's directory, or to the workspace root when it starts
with `//`. A `shellcheck source=` path is relative to the workspace root, as when ShellCheck runs from the
repo root. A path that starts with `SCRIPTDIR/` is relative to the script's directory. `source=/dev/null`
is ignored.

## Settings

Set these as directives in a BUILD file. Subpackages inherit them.

| Directive | Default | Meaning |
| --- | --- | --- |
| `# gazelle:bash_dir_vars SCRIPT_DIR,HERE` | `SCRIPT_DIR` | Variable names that hold "this script's directory" |
| `# gazelle:bash_shellcheck_relative_to script` | `workspace` | What a `shellcheck source=` path is relative to |
| `# gazelle:gazelle_bash disabled` | enabled | Turn the extension off for a subtree |

## Limits

- **Deleting or renaming a script leaves its old target behind.** `bazel build` then fails on the missing
  file. Delete the target by hand. Orion only removes targets an extension names, and it doesn't show
  extensions the existing BUILD file. The golden case `stale_target` pins this until Orion supports it.
- **Commands on `PATH`** (`git`, `jq`, `gh`) are not tracked. Tests use whatever the machine has.
- **Only lines that start with `source`, `.` or `load` are read.** A `source` after `then`, `&&` or `;` on
  the same line is missed. Use a comment for those.
- **`bazel run` of an `sh_binary` that sources a sibling via `BASH_SOURCE` fails.** The files are in its
  runfiles, but `bazel run` starts the binary from `bazel-bin/…`, not from inside the runfiles tree.
  `bazel test` is unaffected: tests start inside the runfiles tree. Binaries meant for `bazel run` should
  find their files with the [Bash runfiles library](https://github.com/bazelbuild/bazel/blob/master/tools/bash/runfiles/runfiles.bash).
  `realpath` and `readlink` on the script's own path fail the same way.

## Developing

Three checks, all run in CI:

```sh
bazel run //:gazelle.check   # the live fixtures' committed BUILD files are current
bazel test //...             # the live fixtures pass in the sandbox, plus the golden test
```

**Live fixtures** (`tests/*`, except `golden`) are generated in place and run as real tests. Passing proves
the declared dependencies are complete, because an undeclared file is not in the sandbox.

| Fixture | Proves |
| --- | --- |
| `library_only` | Scripts without a shebang become one `sh_library` each |
| `binary_sources_lib` | A `source` / `.` line becomes a dependency |
| `bats_basic` | A `.bats` file becomes a `bats_test` that passes |
| `bats_load_helper` | `load helper` pulls in `helper.bash` |
| `cross_package` | Sourcing from another directory resolves to that package's label |
| `dynamic_source` | A runtime-built path is skipped and generation still succeeds |
| `comment_dep` | The comment adds a dependency the parser cannot see |
| `shebang_lib` | Sourcing a script with a shebang works, through two levels of sourcing |

**Golden cases** (`tests/golden/cases/*`) are small workspaces that the real prebuilt Gazelle runs on.
They cover what a live fixture can't: generation errors, BUILD files that exist beforehand, and inputs
that would break the repo's own generation. Each case can hold:

- `BUILD.in`: the BUILD file before the run
- `BUILD.out`: the expected result
- `expected_exit_code`
- `expected_output`: lines that must appear in Gazelle's output

| Case | Pins |
| --- | --- |
| `heredoc` | `source` lines inside heredocs are ignored; `<<<`, `$((1 << 2))` and a stray `"a << b"` are not heredocs |
| `missing_literal` | A literal path to no script fails generation with a clear error |
| `path_forms` | Quoting, comments, `\|\|`/`;`, `. ./`, `dirname --`, `${VAR}`, `//` comments, `bash_dir_vars`, bats `load` forms, name collisions, skipped paths |
| `shellcheck` | `source=` (workspace- and script-relative), `SCRIPTDIR/`, `/dev/null`, combined directives |
| `source_shebang` | A sourced script with a shebang is referenced through `data` |
| `hand_edits` | Hand-added attributes and targets survive regeneration |
| `stale_target` | Known limit: a target for a deleted file is kept |
| `disabled` | `# gazelle:gazelle_bash disabled` turns it off for a subtree only |

```sh
bazel run //tests/golden:golden_test -- --update      # rewrite BUILD.out files from actual output
bazel run //tests/golden:golden_test -- heredoc       # run one case
```

Review the `git diff` after `--update`. It records whatever the plugin did, right or wrong.

`shell.axl` started as [aspect-starters/shell](https://github.com/aspect-starters/shell)
(Apache-2.0). Licence: Apache-2.0.
