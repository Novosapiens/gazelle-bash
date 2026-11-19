# shellcheck shell=bash
upper() { printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'; }
