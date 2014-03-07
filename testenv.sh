#!/bin/sh

bail () {
    echo "This env script must be sourced from the cppr base directory"
    exit 1
}

no_perms () {
    echo "Write permissions to ${PWD} are needed for this env script to work"
    exit 1
}

test -f ./testenv.sh &&
test -f ./git-cppr.sh &&
test -f ./git-pcp.sh &&
test -f ./git-require-hub.sh &&
test -f ./git-pcp--pr-commits.rb &&
test -f ./git-ppr.sh || bail

for jj in "/usr/libexec/git-core/" "$PWD"
do
    pathset=

    for ii in $(echo $PATH | tr ':' ' ')
    do
        test "$(readlink -f ${ii})" = "$(readlink -f ${jj})" && pathset=True
    done

    test -z "${pathset}" && export PATH=$PATH:$jj
done

cp ./git-cppr.sh ./git-cppr || no_perms
cp ./git-ppr.sh ./git-ppr || no_perms
cp ./git-pcp.sh ./git-pcp || no_perms
cp ./git-pcp--pr-commits.rb ./git-pcp--pr-commits || no_perms
cp ./git-require-hub.sh ./git-require-hub || no_perms
