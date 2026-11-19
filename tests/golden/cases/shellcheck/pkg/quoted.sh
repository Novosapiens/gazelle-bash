# shellcheck source="./lib/my lib.sh"
source "$LIB_DIR/my lib.sh"
# shellcheck disable=SC1090 source=../lib/a.sh
source "$UP/lib/a.sh"
