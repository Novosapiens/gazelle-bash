#!/usr/bin/env bats

# bats test_tags=timeout:short, issue:12
@test "adds" {
    [ "$((1 + 1))" -eq 2 ]
}

# bats test_tags=timeout:long
@test "waits" {
    true
}
