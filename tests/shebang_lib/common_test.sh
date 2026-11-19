#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "$(common_value)" == "common+base" ]] || { echo "transitive source failed" >&2; exit 1; }
