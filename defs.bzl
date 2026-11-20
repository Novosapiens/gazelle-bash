"""gazelle_bash(): Aspect's prebuilt Gazelle with shell.axl, plus removal of stale targets,
kind renames for `map_kind`, and rules sorted by name.

Orion doesn't show an extension the existing BUILD file, so shell.axl can't remove a target
whose file was deleted, or choose where a new rule goes. gazelle_bash() runs a prune step
before Gazelle, which removes them, and a sort step after it, which puts each rule at its
place by name.
"""

load("@aspect_gazelle_prebuilt//:def.bzl", "aspect_gazelle")

_AXL = Label("//:shell.axl")

def _rlocationpath(ctx, f):
    path = f.short_path
    return path[3:] if path.startswith("../") else ctx.workspace_name + "/" + path

def _runner_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    runner = ctx.attr.runner[DefaultInfo].files_to_run.executable
    buildozer = ctx.attr._buildozer[DefaultInfo].files_to_run.executable
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        is_executable = True,
        substitutions = {
            "@@MODE@@": ctx.attr.mode,
            "@@BUILDOZER@@": _rlocationpath(ctx, buildozer),
            "@@RUNNER@@": _rlocationpath(ctx, runner),
            "@@PRUNE@@": _rlocationpath(ctx, ctx.file._prune),
            "@@SORT@@": _rlocationpath(ctx, ctx.file._sort),
        },
    )
    files = [script, ctx.file._prune, ctx.file._sort, ctx.file._packages] + ctx.files._runfiles_lib
    runfiles = ctx.runfiles(files = files).merge_all([
        ctx.attr.runner[DefaultInfo].default_runfiles,
        ctx.attr._buildozer[DefaultInfo].default_runfiles,
    ])
    return [DefaultInfo(executable = script, runfiles = runfiles)]

_gazelle_bash_runner = rule(
    implementation = _runner_impl,
    executable = True,
    attrs = {
        "mode": attr.string(values = ["fix", "check"], mandatory = True),
        "runner": attr.label(executable = True, cfg = "target", mandatory = True),
        "_buildozer": attr.label(default = "@buildozer", executable = True, cfg = "target"),
        "_packages": attr.label(default = "//wrapper:packages.sh", allow_single_file = True),
        "_prune": attr.label(default = "//wrapper:prune_stale.sh", allow_single_file = True),
        "_runfiles_lib": attr.label(default = "@bazel_tools//tools/bash/runfiles"),
        "_sort": attr.label(default = "//wrapper:sort_rules.sh", allow_single_file = True),
        "_template": attr.label(default = "//wrapper:run_gazelle.sh", allow_single_file = True),
    },
)

def gazelle_bash(name = "gazelle", languages = [], extensions = [], with_check = False, visibility = None, **kwargs):
    """Creates `name` (fix BUILD files) and, with `with_check`, `name.check` (CI).

    Takes aspect_gazelle()'s arguments. shell.axl is always loaded; `extensions` adds others,
    and `languages` the built-in Gazelle languages, eg ["python"].

    Before Gazelle runs, targets whose files were all deleted are removed: rules of the kinds
    shell.axl generates (and the kinds `map_kind` maps them to) whose `srcs` lists only files
    of the package that no longer exist. A rule with `# keep` is never removed. Then each rule of
    a kind a `map_kind` maps in its package takes the mapped kind, so adding `map_kind` to a repo
    with generated targets works. `name.check` reports both and fails instead.

    After Gazelle runs, the rules of those kinds in each BUILD file are sorted by name, among
    the places they hold, so a new rule goes where its name puts it, not at the end. A rule
    with `# keep` stays where it is. `name.check` fails on a BUILD file whose rules are out of
    order.
    """
    exts = [_AXL] + [e for e in extensions if native.package_relative_label(e) != _AXL]
    inner = "_%s_orion" % name
    aspect_gazelle(
        name = inner,
        languages = languages,
        extensions = exts,
        with_check = with_check,
        visibility = ["//visibility:private"],
        **kwargs
    )
    _gazelle_bash_runner(
        name = name,
        mode = "fix",
        runner = ":" + inner,
        tags = ["manual"],
        visibility = visibility,
    )
    if with_check:
        _gazelle_bash_runner(
            name = name + ".check",
            mode = "check",
            runner = ":%s.check" % inner,
            tags = ["manual"],
            visibility = visibility,
        )
