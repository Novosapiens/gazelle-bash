#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE%/*}/lib/words.sh"
[[ "$(shout abc)" == "ABC" ]] || { echo "shout failed" >&2; exit 1; }
