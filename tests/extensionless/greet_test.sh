#!/usr/bin/env bash
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
# The command is run, not sourced, so the dependency is declared by hand.
# gazelle-bash: dep greet
[[ "$("$here/greet" world)" == "hello world" ]]
