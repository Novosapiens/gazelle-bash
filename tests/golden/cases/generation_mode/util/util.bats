setup() {
    source "$BATS_TEST_DIRNAME/a.sh"
}

@test "reads notes" {
    # gazelle-bash: dep notes.txt
    cat "$BATS_TEST_DIRNAME/notes.txt"
}
