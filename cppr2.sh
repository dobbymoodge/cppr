#!/bin/sh

. /usr/libexec/git-core/git-sh-setup
. /usr/libexec/git-core/git-sh-i18n


state_dir=$GIT_DIR/cppr_state
#$state_dir/remaining_targets
#: ose1
#: ose2
#NOT: $state_dir/complete_targets
#NOT: $state_dir/topic_target
#NOT: $state_dir/pulling_branch
#NOT: $state_dir/pulling_branch_pushed
#NOT: $state_dir/pulled_branches
#NOT: $state_dir/pull_target
# $state_dir/my_remote
# #: jolamb
# $state_dir/our_remote
# #: enterprise
# $state_dir/prefix
# #: bugfix
# $state_dir/commits
#: origin-server/feature_branch


target_branches=

# prefix for naming topic branch(es)
prefix=
# name of remote to push topic branch(es) onto
my_remote=
# git fork for my_remote (derived)
my_fork=
# name of remote to stage PR against
our_remote=
# git fork for our_remote (derived)
our_fork=
# List of commits to build PR from
commits=
# File with list of target branches for which topic branch has been created
complete_targets=
# File with name of target branch currently being used for topic branch creation
topic_target=
# File with name of current topic branch, when creating pull request
pulling_branch=
# File with list of topic branches which have successfully been pushed to $my_remote
pulling_branch_pushed=
# File with list of topic branches which have successfully been turned into pull requests
pulled_branches=
# Current target branch for which a pull request is being created
pull_target=



resolvemsg="
$(gettext 'When you have resolved this problem, run "cppr2 --continue".
If you prefer to skip this target branch, run "cppr2 --skip" instead.
To check out the original branch and stop creating pull requests, run "cppr2 --abort".')
"

get_fork () {
    fork=$(git config --get remote.${1}.pushurl ||
           git config --get remote.${1}.url | 
               awk '{gsub(/(^.+github.com.|\.git$)/, "", $1); print $1;}')
    if test -z "$fork"; then
        die $(gettext "Could not resolve fork for remote ${1}")
    fi
    echo $fork
}

resolve_forks () {
    my_fork=$(get_fork $my_remote)
    our_fork=$(get_fork $our_remote)
}

read_state () {
    test -f "$state_dir/prefix" &&
    prefix=$(cat $state_dir/prefix) &&
    test -f "$state_dir/my_remote" &&
    my_remote=$(cat $state_dir/my_remote) &&
    test -f "$state_dir/our_remote" &&
    our_remote=$(cat $state_dir/our_remote) &&
    test -f "$state_dir/commits" &&
    commits=$(cat $state_dir/commits)

    test -f "$state_dir/complete_targets" &&
    complete_targets=t

    test -f "$state_dir/topic_target" &&
    topic_target=$(cat $state_dir/topic_target)

    test -f "$state_dir/pulling_branch" &&
    pulling_branch=$(cat $state_dir/pulling_branch)

    test -f "$state_dir/pulling_branch_pushed" &&
    pulling_branch_pushed=t

    test -f "$state_dir/pulled_branches" &&
    pulled_branches=t

    test -f "$state_dir/pull_target" &&
    pull_target=$(cat $state_dir/pull_target)
}

total_argc=$#
while test $# != 0
do
	case "$1" in
        --target_branch|-t)
            test 2 -le "$#" || usage
            test -n "${target_branches}" &&
            target_branches="${target_branches} ${2}" ||
            target_branches="${2}"
            shift
            ;;
        --my_remote|-u)
            test -z "${my_remote}" && test 2 -le "$#" || usage
            my_remote=$2
            shift
            ;;
        --our_remote|-o)
            test -z "${our_remote}" && test 2 -le "$#" || usage
            our_remote=$2
            shift
            ;;
        --prefix|-p)
            test -z "${prefix}" && test 2 -le "$#" || usage
            prefix=$2
            shift
            ;;
	    --continue|--skip|--abort)
		    test $total_argc -eq 2 || usage
		    action=${1##--}
		    ;;
        [^-]*)
            break
            ;;
    esac
    shift
done
test $# -ge 1 || usage
commits="$@"

test -n "$target_branches" &&
test -n "$my_remote" &&
test -n "$our_remote" &&
test -n "$prefix" || usage

resolve_forks

# read_state
# no state
# write_state
if ! test -d $state_dir ; then
    # unless continue/abort/etc.
    mkdir -p "$state_dir"
fi

for target in $target_branches; do
    echo $target >> $state_dir/remaining_targets
done

while ( test -f $state_dir/remaining_targets ) ; do
    topic_target=$(head --lines=1 $state_dir/remaining_targets)
    # Move topic_target from remaining_targets:
    echo $topic_target > $state_dir/topic_target
    sed --in-place --expression='1d' $state_dir/remaining_targets
    # Verify no temp branches collide with existing branches at start
    temp_branch=$prefix-$topic_target
    git checkout -b $temp_branch $topic_target # Handle failure
    git cherry-pick $commits || die $resolvemsg
    # This is a reentry point (--continue)
    #   remaining_targets
    #   topic_target
    /bin/rm $state_dir/topic_target
    echo $topic_target >> $state_dir/complete_targets
    test -z "$(cat $state_dir/remaining_targets)" && /bin/rm $state_dir/remaining_targets
done
while ( test -f $state_dir/complete_targets ) ; do
    # MAKE PRs
    pull_target=$(head --lines=1 $state_dir/complete_targets)
    # Move pull_target from complete_targets:
    echo $pull_target > $state_dir/pull_target
    sed --in-place --expression='1d' $state_dir/complete_targets
    pulling_branch=$prefix-$pull_target
    git checkout $pulling_branch || die $resolvemsg
    # This is a reentry point (--continue)
    #   complete_targets
    #   pull_target
    #   
    echo $pulling_branch > $state_dir/pulling_branch
    git push $my_remote $pulling_branch || die $resolvemsg
    # This is a reentry point (--continue)
    #   complete_targets
    #   pull_target
    #   pulling_branch
    echo $pulling_branch > $state_dir/pulling_branch_pushed
    pr_message="cppr: ${prefix} - Pull request from ${commits}"
    if ! hub pull-request -m "${pr_message}" -b "${our_fork}:${pull_target}" -h "${my_fork}:${pulling_branch}" ; then
       die $resolvemsg
       # This is a reentry point (--continue)
       #   complete_targets
       #   pull_target
       #   pulling_branch
       #   pulling_branch_pushed
    fi
    echo $pulling_branch >> $state_dir/pulled_branches
    /bin/rm $state_dir/pulling_branch
    /bin/rm $state_dir/pulling_branch_pushed
    test -z "$(cat $state_dir/complete_targets)" && /bin/rm $state_dir/complete_targets
done
