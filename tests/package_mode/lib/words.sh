# shellcheck shell=bash
# Sources a sibling: inside one package target, so no dependency is written.
. "${BASH_SOURCE%/*}/case.sh"
shout() { upper "$1"; }
