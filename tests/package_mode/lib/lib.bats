#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/words.sh"
}

@test "a test named after its package gets the package library and its sibling" {
    [ "$(shout hi)" = "HI" ]
}
