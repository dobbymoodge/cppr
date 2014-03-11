#!/bin/sh

bail () {
    echo "This script must be run from the cppr base directory"
    exit 1
}

test -f ./testenv.sh || exit 1

test -f ./git-cppr                && /bin/rm ./git-cppr               
test -f ./git-ppr                 && /bin/rm ./git-ppr                
test -f ./git-pcp                 && /bin/rm ./git-pcp                
test -f ./git-require-hub         && /bin/rm ./git-require-hub        
test -f ./git-cppr--github-helper && /bin/rm ./git-cppr--github-helper
