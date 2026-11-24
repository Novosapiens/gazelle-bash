#!/usr/bin/env bats

setup() {
    PATH="$BATS_TEST_DIRNAME/bin:$PATH"
}

@test "a subcommand no file runs falls back to the whole dispatcher" {
    run tool nonsense
    [ "$status" -eq 1 ]
    [ "$output" = "tool: no such command: nonsense" ]
    [ -e "$BATS_TEST_DIRNAME/libexec/tool-start" ]
}
