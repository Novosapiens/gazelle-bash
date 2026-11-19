# The tracker miscounts the quotes on the next line. A string is then still open at the end
# of the file, so the tracker's result is dropped and every line is read.
x="$(echo ")")"
source lib.sh
