#!/bin/sh

SUBDIRECTORY_OK=Yes
OPTIONS_KEEPDASHDASH=
OPTIONS_SPEC="\
cppr --target_branch <branch> [--target_branch <another branch> ...] --my_remote <remote> --our_remote <remote> --prefix <temp branch prefix> <commit(s)>
cppr --continue | --abort | --skip
--
 Available options are
t,target_branch=!   branch to create pull request against
u,my_remote=!       remote to push topic branches to, from which pull requests will be made
o,our_remote=!      remote against which pull requests will be created
p,prefix=!          prefix to use when creating topic branches
 Actions:
continue!          continue
abort!             abort and check out the original branch
skip!              skip current cherry-pick or pull request and continue
"

. /usr/libexec/git-core/git-sh-setup
. /usr/libexec/git-core/git-sh-i18n
set_reflog_action cppr
require_work_tree_exists
cd_to_toplevel

state_dir=$GIT_DIR/cppr_state
editmsg_file=$GIT_DIR/PULLREQ_EDITMSG
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
    if test -z "$fork"
    then
        die $(gettext "Could not resolve fork for remote ${1}")
    fi
    echo $fork
}

resolve_forks () {
    my_fork=$(get_fork $my_remote)
    our_fork=$(get_fork $our_remote)
}

write_state () {
    echo "$target_branches" > $state_dir/opt_target_branches
    echo "$my_remote" > $state_dir/opt_my_remote
    echo "$our_remote" > $state_dir/opt_our_remote
    echo "$my_fork" > $state_dir/opt_my_fork
    echo "$our_fork" > $state_dir/opt_our_fork
    echo "$prefix" > $state_dir/opt_prefix
    echo "$commits" > $state_dir/opt_commits
    echo "$current_branch" > $state_dir/current_branch
}

initialize_cppr () {
    resolve_forks

    conflicting_branches=
    conflicting_remote_branches=
    for target in $target_branches
    do
        chk_target="${prefix}-${target}"
        # if git branch --no-color | cut -b3- | grep -q "^${chk_target}$"
        if git rev-parse --verify --quiet "$chk_target" > /dev/null
        then
            test -n "$conflicting_branches" &&
            conflicting_branches="${conflicting_branches} ${chk_target}" ||
            conflicting_branches="${chk_target}"
        fi
        chk_target="${my_remote}/${prefix}-${target}"
        if git rev-parse --verify --quiet "$chk_target" > /dev/null
        then
            test -n "$conflicting_remote_branches" &&
            conflicting_remote_branches="${conflicting_remote_branches} ${chk_target}" ||
            conflicting_remote_branches="${chk_target}"
        fi
    done

    # Check if our temp branches already exist
    if ! test -d $state_dir
    then
        if test -n "$conflicting_branches"
        then
            echo "$(gettext 'The following local branches conflict with the branch names generated using the prefix you provided; please remove the existing branches or select a different prefix: ')"
            for br in $conflicting_branches
            do
                echo "    ${br}"
            done
            test -z "$conflicting_remote_branches" && exit 1
        fi

        if test -n "$conflicting_remote_branches"
        then
            echo "$(gettext 'The following remote branches conflict with the branch names generated using the prefix you provided; please remove the existing branches or select a different prefix: ')"
            for br in $conflicting_remote_branches
            do
                echo "    ${br}"
            done
            exit 1
        fi
    fi

    if ! test -d $state_dir
    then
        # unless continue/abort/etc.
        mkdir -p "$state_dir"
    fi

    current_branch="$(git rev-parse --abbrev-ref HEAD)"

    write_state

    for target in $target_branches
    do
        echo $target >> $state_dir/remaining_targets
    done
}

read_state () {
    test -f $state_dir/opt_target_branches &&
    target_branches="$(cat $state_dir/opt_target_branches)" &&
    test -f $state_dir/opt_my_remote &&
    my_remote="$(cat $state_dir/opt_my_remote)" &&
    test -f $state_dir/opt_our_remote &&
    our_remote="$(cat $state_dir/opt_our_remote)" &&
    test -f $state_dir/opt_my_fork &&
    my_fork="$(cat $state_dir/opt_my_fork)" &&
    test -f $state_dir/opt_our_fork &&
    our_fork="$(cat $state_dir/opt_our_fork)" &&
    test -f $state_dir/opt_prefix &&
    prefix="$(cat $state_dir/opt_prefix)" &&
    test -f $state_dir/opt_commits &&
    commits="$(cat $state_dir/opt_commits)" &&
    test -f $state_dir/current_branch &&
    current_branch="$(cat $state_dir/current_branch)"
}

switch_to_safe_branch () {
    local safe_branch=
    if test -z "$current_branch" || git rev-parse --verify --quiet "$current_branch" > /dev/null
    then
        git rev-parse --verify --quiet "master" > /dev/null && safe_branch="master"
    else
        safe_branch="$current_branch"
    fi

    test -n "$safe_branch" && git checkout "$safe_branch"
}

remove_target_branch () {
    test -z "$1" && return
    local new_target_branches=
    for branch in $target_branches
    do
        if test "$1" != "$branch"
        then
            test -n "${new_target_branches}" &&
            new_target_branches="${new_target_branches} ${branch}" ||
            new_target_branches="${branch}"
        fi
    done
    target_branches="$new_target_branches"
    write_state
}

abort_cppr () {
    test -d $state_dir || die "$(gettext 'No cppr operation is in progress')"
    read_state
    if test -f "${GIT_DIR}/CHERRY_PICK_HEAD"
    then
        git cherry-pick --abort
    fi

    switch_to_safe_branch

    if test -n "$prefix" && test -f $state_dir/complete_targets
    then
        test -f $state_dir/topic_target && topic_target="$(cat $state_dir/topic_target)"
        for branch in $(cat $state_dir/complete_targets) $topic_target
        do
            temp_branch="${prefix}-${branch}"
            git rev-parse --verify --quiet "$temp_branch" > /dev/null &&
            git branch -D "$temp_branch"
        done
    fi
    test -f $state_dir/pulling_branch && pulling_branch="$(cat $state_dir/pulling_branch)"
    test -f $state_dir/from_pr && from_pr="$(cat $state_dir/from_pr)"
    for branch in $pulling_branch $from_pr
    do
        git rev-parse --verify --quiet "$branch" > /dev/null &&
        git branch -D "$branch"
    done
    /bin/rm -rf $state_dir
}

skip_remaining_targets () {
    test -f $state_dir/topic_target && topic_target="$(cat $state_dir/topic_target)" || return
    test -n "${topic_target}" && temp_branch="${prefix}-${topic_target}"
    if test "$(git rev-parse --abbrev-ref HEAD)" = "${temp_branch}"
    then
        test -f "${GIT_DIR}/CHERRY_PICK_HEAD" && git cherry-pick --abort
    fi
    switch_to_safe_branch
    if git rev-parse --verify --quiet "$temp_branch" > /dev/null
    then
        git branch -D "$temp_branch"
    fi
    remove_target_branch "$topic_target"
    /bin/rm $state_dir/topic_target
    test -f $state_dir/pre_cp_ref && /bin/rm $state_dir/pre_cp_ref
}

cleanup_complete_targets () {
    echo $pulling_branch >> $state_dir/pulled_branches
    test -f $state_dir/pulling_branch && /bin/rm $state_dir/pulling_branch
    test -f $state_dir/pulling_branch_pushed && /bin/rm $state_dir/pulling_branch_pushed
    test -f $state_dir/pull_target && /bin/rm $state_dir/pull_target
    test -z "$(cat $state_dir/complete_targets)" && /bin/rm $state_dir/complete_targets
}

skip_complete_targets () {
    test -f $state_dir/pull_target && pull_target="$(cat $state_dir/pull_target)" || return
    if test -f $state_dir/pulling_branch
    then
        pulling_branch="$(cat $state_dir/pulling_branch)"
    else
        test -n "${pull_target}" && pulling_branch="${prefix}-${pull_target}"
    fi
    switch_to_safe_branch
    if ! test -f $state_dir/pulled_branches || ! grep -q "^${pulling_branch}$" $state_dir/pulled_branches
    then
        git rev-parse --verify --quiet "$pulling_branch" > /dev/null &&
        git branch -D "$pulling_branch"
        if test -f $state_dir/pulling_branch_pushed 
        then
            git rev-parse --verify --quiet "${my_remote}/${pulling_branch}" > /dev/null &&
            git push "$my_remote" ":${pulling_branch}"
        fi
    fi
    cleanup_complete_targets
}

skip_branch () {
    test -d $state_dir || die "$(gettext 'No cppr operation is in progress')"
    read_state
    if test -f $state_dir/remaining_targets
    then
        skip_remaining_targets
    elif test -f $state_dir/complete_targets
    then
        skip_complete_targets
    fi

}

# echo "========="
# echo "Args: $@"
# echo "========="

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

if test -z "$action"
then
    if test -d $state_dir
    then
        # Stolen haphazardly from git-rebase.sh
        state_dir_base=${state_dir##*/}
	    cmd_live_cppr="cppr (--continue | --abort | --skip)"
	    cmd_clear_stale_cppr="rm -fr \"$state_dir\""
        die "
$(eval_gettext 'It seems that there is already a $state_dir_base directory, and
I wonder if you are in the middle of another cppr run. If that is the case, please try
	$cmd_live_cppr
If that is not the case, please
	$cmd_clear_stale_cppr
and run me again.  I am stopping in case you still have something
valuable there.')"
    else
        test -n "$target_branches" &&
        test -n "$my_remote" &&
        test -n "$our_remote" &&
        test -n "$prefix" || usage
    fi
    test $# -ge "1" || usage
    commits="$@"
    initialize_cppr
elif test -n "$action"
then
    if ! test -d $state_dir
    then
        die "$(gettext 'No cppr run in progress?')"
    elif test -n "${target_branches}${my_remote}${our_remote}${prefix}${commits}"
    then
        die "$(eval_gettext '$action cannot be used with other arguments')"
    fi
    test $# -eq "0" || usage
fi

case "$action" in
    continue)
        # Again stolen from git-rebase.sh
        # Sanity check
	    git rev-parse --verify HEAD >/dev/null ||
		die "$(gettext 'Cannot read HEAD')"
	    git update-index --ignore-submodules --refresh &&
	    git diff-files --quiet --ignore-submodules || {
		    echo "$(gettext "You must edit all merge conflicts and then
mark them as resolved using git add")"
		    exit 1
	    }
        test -f "${GIT_DIR}/CHERRY_PICK_HEAD" &&
        die "$(gettext 'Resolved cherry-picks must be committed using git commit')"
        read_state || die "
$(eval_gettext 'Could not read cppr state from $state_dir. Please verify
permissions on the directory and try again')"
        ;;
    abort)
        abort_cppr
        exit 0
        ;;
    skip)
        skip_branch
        ;;
esac

bare_state () {
    test -f $state_dir/remaining_targets &&
    ! test -f $state_dir/topic_target
}

checkout_state () {
    test -f $state_dir/remaining_targets &&
    test -f $state_dir/topic_target &&
    ! test "$(git rev-parse --abbrev-ref HEAD)" = "${temp_branch}"
}

cherry_pick_state () {
    test -f $state_dir/remaining_targets &&
    test -f $state_dir/topic_target &&
    test "$(git rev-parse --abbrev-ref HEAD)" = "${temp_branch}"
}

while ( test -f $state_dir/remaining_targets ) ; do
    if bare_state
    then
        topic_target=$(head --lines=1 $state_dir/remaining_targets)
        # Move topic_target from remaining_targets:
        echo $topic_target > $state_dir/topic_target
        sed --in-place --expression='1d' $state_dir/remaining_targets
    else
        topic_target="$(cat $state_dir/topic_target)"
    fi
    temp_branch=$prefix-$topic_target

    if checkout_state
    then
        git checkout -b $temp_branch $topic_target || die $resolvemsg
        # This is a reentry point (--continue)
        #   ! ( git branch | grep -q "^\s*${temp_branch}$" )
        #   remaining_targets
        #   topic_target
    fi
    
    if cherry_pick_state
    then
        if test -f $state_dir/pre_cp_ref
        then
            pre_cp_ref="$(cat $state_dir/pre_cp_ref)"
        else
            pre_cp_ref="$(git rev-parse HEAD)"
            echo "$pre_cp_ref" > $state_dir/pre_cp_ref
            git cherry-pick $commits || die $resolvemsg
        fi
        test "$pre_cp_ref" = "$(git rev-parse HEAD)" &&
        die "
$(gettext 'It looks like the cherry-pick failed, and the branch
is unmodified. Please fix this issue and resume with --continue
or skip this branch with --skip')"
        # This is a reentry point (--continue)
        #   ( git branch | grep -q "^\s*${temp_branch}$" )
        #   remaining_targets
        #   topic_target
        git log "${pre_cp_ref}"..HEAD > "${state_dir}/pr_msg_${temp_branch}"
        /bin/rm $state_dir/topic_target
        /bin/rm $state_dir/pre_cp_ref
        echo $topic_target >> $state_dir/complete_targets
        test -z "$(cat $state_dir/remaining_targets)" && /bin/rm $state_dir/remaining_targets
    fi
done

pull_target_state () {
    test -f $state_dir/complete_targets &&
    ! test -f $state_dir/pull_target
}

checkout_pulling_branch_state () {
    test -f $state_dir/complete_targets &&
    test -f $state_dir/pull_target &&
    ! test -f $state_dir/pulling_branch
}

push_state () {
    test -f $state_dir/complete_targets &&
    test -f $state_dir/pull_target &&
    test -f $state_dir/pulling_branch &&
    ! test -f $state_dir/pulling_branch_pushed
}

pull_request_state () {
    test -f $state_dir/complete_targets &&
    test -f $state_dir/pull_target &&
    test -f $state_dir/pulling_branch &&
    test -f $state_dir/pulling_branch_pushed
}

while ( test -f $state_dir/complete_targets ) ; do
    # MAKE PRs
    if pull_target_state
    then
        pull_target=$(head --lines=1 $state_dir/complete_targets)
        # Move pull_target from complete_targets:
        echo $pull_target > $state_dir/pull_target
        sed --in-place --expression='1d' $state_dir/complete_targets
    else
        pull_target="$(cat $state_dir/pull_target)"
    fi

    if checkout_pulling_branch_state
    then
        pulling_branch="${prefix}-${pull_target}"
        git checkout $pulling_branch || die $resolvemsg
        # This is a reentry point (--continue)
        #   complete_targets
        #   pull_target
        #
        echo $pulling_branch > $state_dir/pulling_branch
    else
        pulling_branch="$(cat $state_dir/pulling_branch)"
    fi

    if push_state
    then
    git push $my_remote $pulling_branch:$pulling_branch || die $resolvemsg
    # This is a reentry point (--continue)
    #   complete_targets
    #   pull_target
    #   pulling_branch
    echo $pulling_branch > $state_dir/pulling_branch_pushed
    fi

    if pull_request_state
    then
        pr_message="cppr: ${prefix} - Pull request from ${commits}"
        echo "$pr_message" > $editmsg_file
        if test -f "${state_dir}/pr_msg_${pulling_branch}"
        then
            echo "" >> $editmsg_file
            cat "${state_dir}/pr_msg_${pulling_branch}" >> $editmsg_file
        fi
        # if ! hub pull-request -m "${pr_message}" -b "${our_fork}:${pull_target}" -h "${my_fork}:${pulling_branch}" ; then
        hub pull-request -b "${our_fork}:${pull_target}" -h "${my_fork}:${pulling_branch}" || die $resolvemsg
        # This is a reentry point (--continue)
        #   complete_targets
        #   pull_target
        #   pulling_branch
        #   pulling_branch_pushed
        echo $pulling_branch >> $state_dir/pulled_branches
        /bin/rm $state_dir/pulling_branch
        /bin/rm $state_dir/pulling_branch_pushed
        /bin/rm $state_dir/pull_target
        test -f "${state_dir}/pr_msg_${pulling_branch}" && /bin/rm "${state_dir}/pr_msg_${pulling_branch}"
        test -z "$(cat $state_dir/complete_targets)" && /bin/rm $state_dir/complete_targets
    fi
done

if ! test -f $state_dir/complete_targets && ! test -f $state_dir/remaining_targets
then
    git checkout "$current_branch"
    /bin/rm $state_dir/*
    /usr/bin/rmdir $state_dir
fi
