#!/usr/bin/env bats

@test "the macro supplies the setting" {
    [ "$SHARED_SETTING" = "on" ]
}
