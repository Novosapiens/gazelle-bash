#!/usr/bin/env bats

setup() {
    DR="$BATS_TEST_DIRNAME"
}

@test "a command with no extension runs, with the library it sources" {
    run "$DR/bin/hello" world
    [ "$status" -eq 0 ]
    [ "$output" = "say world" ]
}

@test "a named file is present" {
    grep -q guide "$DR/docs/guide.md"
}

@test "a named directory is present, with its subdirectories" {
    [ "$(cat "$DR/docs/more/"*.txt)" = "extra" ]
}
