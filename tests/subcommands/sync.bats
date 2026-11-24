#!/usr/bin/env bats

setup() {
    PATH="$BATS_TEST_DIRNAME/bin:$PATH"
}

@test "a test of one subcommand has it and the dispatcher in the sandbox" {
    run tool sync --dry-run
    [ "$status" -eq 0 ]
    [ "$output" = "synced --dry-run" ]
}

@test "and not the other subcommands" {
    [ ! -e "$BATS_TEST_DIRNAME/libexec/tool-start" ]
}
