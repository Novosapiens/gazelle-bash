# Real-project corpus

`run.sh` runs the plugin, with no configuration, on the open-source shell projects pinned in
`projects.txt`. It checks that each one still gives the recorded result. CI runs it on every push. The
projects' code is only read; nothing from them is executed.

- **`ok`**: generation succeeds, and Bazel can load and analyse every generated target.
- **`fail:<text>`**: generation stops with `<text>` in its output. These are not plugin bugs. Each project
  needs one setting or comment that a no-configuration run doesn't have, and the advice `gazelle_bash()`
  prints after the error names it:

| Project | Why it stops | What the project would add |
| --- | --- | --- |
| Bash-it | A vendored project's own test loads helpers from its upstream repo | `# gazelle:exclude vendor` |
| git-extras | Sources vendored code that isn't checked out (a submodule) | Check out the submodule, or `# gazelle-bash: ignore` |
| pi-hole | Loads bats helper libraries that its test setup downloads | `# gazelle-bash: ignore` on those `load` lines |
| bats-core | Test files that load a missing file on purpose | `# gazelle:exclude test/fixtures` |
| shunit2 | Sources `math.inc`, which is not a script target | `# gazelle:bash_data_files **/*.inc` |
| shellspec | Sources a path relative to the working directory | `# gazelle-bash: ignore` |

If a change to the plugin flips a result, the run fails and names the project. Update `projects.txt` only
when the new result is the right one.

To add a project, append `owner/repo|<full commit sha>|ok`, run `tests/corpus/run.sh owner/repo`, and
record what it does.
