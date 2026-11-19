#!/usr/bin/env bats

load helper

@test "helper is loaded" {
    run double 21
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}
