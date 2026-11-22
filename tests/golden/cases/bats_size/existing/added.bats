#!/usr/bin/env bats
# bats file_tags=size:small

@test "adds" {
    [ "$((1 + 1))" -eq 2 ]
}
