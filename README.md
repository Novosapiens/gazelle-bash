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
| `*.sh` / `*.bash` without a shebang | `sh_library` (visible to `//:__subpackages__`) |
| `*.bats` | `bats_test` (from `@bazel_lib//lib:bats.bzl`) |

Targets are named after the file without its extension. If two files in a package would get the same
name, both keep the extension instead (`foo_sh`, `foo_bats`).

## Dependencies

| In the script | Becomes |
| --- | --- |
| `source path` or `. path` at the start of a line | `deps` (`data` for bats) |
| bats `load name` | `data`, pointing at `name.bash` |
| `# gazelle-bash: dep path` | `deps` (`data` for bats) |

Each path resolves to the label of the target that owns that script, in any package.

Before a path is resolved, any of these leading "directory of this script" idioms is stripped. Whatever
remains is then resolved against the script's own directory:

```
$(dirname "${BASH_SOURCE[0]}")/    ${BASH_SOURCE%/*}/    ${0%/*}/    $(dirname "$0")/
$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/    $BATS_TEST_DIRNAME/    $SCRIPT_DIR/
```

To treat more variable names as "this script's directory", add a directive to a BUILD file. Subpackages
inherit it:

```
# gazelle:bash_dir_vars SCRIPT_DIR,HERE
```

- **Literal path that matches no script:** generation fails, so a typo or a deleted library can't silently
  drop a dependency.
- **Path still containing `$`, a glob or a backtick:** it is skipped and the skip is printed. Declare it
  with the comment instead. A comment path is relative to the script's directory, or to the workspace root
  when it starts with `//`:

  ```bash
  # gazelle-bash: dep plugins/hello.sh
  for p in "$here"/plugins/*.sh; do source "$p"; done
  ```

## Limits

- **Commands on `PATH`** (`git`, `jq`, `gh`) are not tracked. Tests use whatever the machine has.
- **Matching is by regex at line start.** A `source` inside a heredoc that starts a line is read as a
  dependency. A `source` after `&&`, `;` or `then` on the same line is missed. Use the comment for those.
- **`bazel run` of an `sh_binary` that sources a sibling via `BASH_SOURCE` fails.** The deps are in its
  runfiles, but `bazel run` starts the binary from `bazel-bin/…`, not from inside the runfiles tree.
  `bazel test` is unaffected: tests start inside the runfiles tree. Binaries meant for `bazel run` should
  find their files with the [Bash runfiles library](https://github.com/bazelbuild/bazel/blob/master/tools/bash/runfiles/runfiles.bash).
  `realpath` and `readlink` on the script's own path fail the same way.

## Developing

`tests/` holds one fixture per behaviour, and its committed `BUILD.bazel` files are the expected output. To
change the generator:

```sh
bazel run //:gazelle      # regenerate the fixtures
git diff tests/           # review the change in output
bazel test //...          # the generated targets must still pass in the sandbox
```

| Fixture | Proves |
| --- | --- |
| `library_only` | Scripts without a shebang become one `sh_library` each |
| `binary_sources_lib` | A `source` / `.` line becomes a `deps` label |
| `bats_basic` | A `.bats` file becomes a `bats_test` that passes |
| `bats_load_helper` | `load helper` pulls in `helper.bash` |
| `cross_package` | Sourcing from another directory resolves to that package's label |
| `dynamic_source` | A runtime-built path is skipped and generation still succeeds |
| `comment_dep` | The comment adds a dependency the regex cannot see |

`shell.axl` started as [aspect-starters/shell](https://github.com/aspect-starters/shell)
(Apache-2.0). Licence: Apache-2.0.
