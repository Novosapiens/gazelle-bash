#!/usr/bin/env bats

@test "adds" {
    [ "$((1 + 1))" -eq 2 ]
}

# bats test_tags=requires-network, issue:12
@test "fetches" {
    true
}
