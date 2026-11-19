# Library: no shebang.
upper() {
    printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'
}
