# Text inside multi-line strings is not a command.
EXPECTED="binary failed
source intentionally failed"
words='install keep
            source unhold unmarkauto
. also_not_a_dep.sh'
fish=$'switch
source (pyenv init|psub)
it\'s still a string
'
echo "it's fine" # an apostrophe: it's a comment
source lib.sh
