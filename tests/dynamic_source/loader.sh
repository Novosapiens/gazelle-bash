# Library: sources a module chosen at runtime.
load_module() {
    local name="$1"
    source "$MODULE_DIR/$name.sh"
}
