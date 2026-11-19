#!/usr/bin/env bats

@test "a subpackage inherits the mapping" {
    [ "$SHARED_SETTING" = "on" ]
}
