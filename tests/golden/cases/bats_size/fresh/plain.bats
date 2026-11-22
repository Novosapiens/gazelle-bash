#!/usr/bin/env bats

# bats test_tags=weight:large, issue:12
@test "adds" {
    [ "$((1 + 1))" -eq 2 ]
}
