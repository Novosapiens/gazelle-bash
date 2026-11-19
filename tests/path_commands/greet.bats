#!/usr/bin/env bats

load helpers/common

@test "a command run by bare name is in the sandbox" {
    run greet-tool
    [ "$status" -eq 0 ]
    [ "$output" = "hello from PATH" ]
}
