#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE%/*}/strings.sh"
[[ "$(upper abc)" == "ABC" ]] || { echo "upper failed" >&2; exit 1; }
