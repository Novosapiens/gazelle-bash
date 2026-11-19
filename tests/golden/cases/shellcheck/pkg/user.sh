# shellcheck source=lib/a.sh
source "$LIB_DIR/a.sh"
# shellcheck source=SCRIPTDIR/b.sh
source "$HERE/b.sh"
# shellcheck disable=SC1091 source=/dev/null
source "$HOME/.profile"
