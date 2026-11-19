#!/usr/bin/env bash
# gazelle-bash: dep plugins/hello.sh
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
for p in "$here"/plugins/*.sh; do
    source "$p"
done
[[ "$(plugin_hello)" == "hello plugin" ]] || { echo "plugin not loaded" >&2; exit 1; }
