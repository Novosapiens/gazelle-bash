@test "fallbacks" {
  run tool
  run tool --help
  run tool "$cmd"
  run tool nonsense
}
