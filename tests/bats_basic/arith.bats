#!/usr/bin/env bats

@test "addition works" {
    [ "$((1 + 2))" -eq 3 ]
}
