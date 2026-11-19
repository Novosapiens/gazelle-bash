# "a << b" is not a heredoc: it never closes, so the lines after it are still read.
echo "a << b"
source lib.sh
