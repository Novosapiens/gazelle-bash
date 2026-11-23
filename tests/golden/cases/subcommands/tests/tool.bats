@test "sync" {
  run tool sync --dry-run
}

@test "a dashed subcommand" {
  run tool version-file extra
}
