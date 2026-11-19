@test "reads" {
  run "$APP/bin/tool"
  grep guide "$REPO/docs/GUIDE.md"
  ls "${REPO}/docs/notes/"
  cat $REPO/tests/fixtures/one/*.json
  cat "$REPO/tests/other.bats" "$REPO/NOTICE" "$REPO/README.md"
  [ -d "$REPO/app/lib" ]
  # $REPO/tests/fixtures/two/x.txt is only a comment
  cat "$REPO/made/at/runtime.txt"
  echo "\$REPO/docs/escaped.md"
  cat "$REPO/docs/$name.md"
  # gazelle:bats_data //docs/notes/**
  cat "$REPO/docs/notes/$name"
}
