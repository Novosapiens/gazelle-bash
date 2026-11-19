"""A house macro for bats tests: every test gets the same extra settings."""

load("@bazel_lib//lib:bats.bzl", "bats_test")

def env_bats_test(name, env = {}, **kwargs):
    bats_test(
        name = name,
        env = dict(env, SHARED_SETTING = "on"),
        **kwargs
    )
