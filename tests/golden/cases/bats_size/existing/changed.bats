#!/usr/bin/env bats

# bats test_tags=timeout:short
@test "adds" {
    [ "$((1 + 1))" -eq 2 ]
}
