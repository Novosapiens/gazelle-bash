#!/usr/bin/env bash
# A library written with a shebang: generated as sh_binary, still sourceable.
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
common_value() { echo "common+$(base_value)"; }
