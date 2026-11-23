@test "a declared subcommand" {
  run board next
}

@test "a subcommand named by its file" {
  board sync | grep sync
}
