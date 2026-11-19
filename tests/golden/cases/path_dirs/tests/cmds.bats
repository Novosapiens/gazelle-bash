# in-comment is only named in this comment
@test "forms" {
  run tool issues
  run -0 other-tool
  piped | grep x
  x="$(subst)"
  ! negated
  if prefixed; then true; fi
  FOO=1 BAR=2 assigned arg
  with-ext.sh
  second-dir
  shared
  git status
  echo argument
  run ! tool
}
