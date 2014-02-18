#!/bin/sh
# -*- indent-tabs-mode: t -*-

SUBDIRECTORY_OK=Yes
OPTIONS_KEEPDASHDASH=
OPTIONS_SPEC="\
git ppr --target_branch <destination branch or source branch:destination branch> [--target_branch <another branch/mapping> ...] --my_repo <remote/github repo> --our_repo <remote/github repo> [--prefix <temp branch prefix>]
git-ppr --continue | --abort | --skip
--
 Available options are
t,target_branch=!   branch to create pull request against
u,my_repo=!         remote or github repository from which pull requests will be made
o,our_repo=!        remote or github repository (e.g. owner/repo) against which pull requests will be created
p,prefix=!          prefix to use when mapping topic branches to target branches
 Actions:
continue!          continue
abort!             abort and check out the original branch
skip!              skip current cherry-pick or pull request and continue
"

. git-sh-setup
. git-sh-i18n
set_reflog_action ppr
require_work_tree_exists
cd_to_toplevel

state_dir=$GIT_DIR/ppr_state
editmsg_file=$GIT_DIR/PULLREQ_EDITMSG
target_branches=

# prefix for naming topic branch(es)
prefix=
# name of remote to push topic branch(es) onto
my_repo=
# git fork for my_repo (derived)
my_fork=
# name of remote to stage PR against
our_repo=
# git fork for our_repo (derived)
our_fork=
# List of commits to build PR from
commits=
# File with list of target branches for which topic branch has been created
complete_targets=
# File with name of target branch currently being used for topic branch creation
topic_target=
# File with name of current topic branch, when creating pull request
pulling_branch=
# File with list of topic branches which have successfully been pushed to $my_repo
pulling_branch_pushed=
# File with list of topic branches which have successfully been turned into pull requests
pulled_branches=
# Current target branch for which a pull request is being created
pull_target=

github_credentials=

resolvemsg="
$(gettext 'When you have resolved this problem, run "ppr --continue".
If you prefer to skip this target branch, run "ppr --skip" instead.
To check out the original branch and stop creating pull requests, run "ppr --abort".')
"

require_hub () {
	req_msg="
$(gettext 'This command requires a recent version of 
hub, which can be found at: http://hub.github.com/')"
	unalias hub
	type hub || die $req_msg
	hub --version | grep -q '^git version' || die "$req_msg"
}

resolve_github_credentials () {
	test -n "$github_credentials" && return 0
	user_pass=
	no_creds_msg="
$(gettext 'This command requires github account credentials to be
specified either in the hub command configuration located in
$HOME/.config/hub, or in the environment variables
GITHUB_USER and GITHUB_PASSWORD.')"
	test -n "$GITHUB_USER" && test -n "$GITHUB_PASSWORD" && user_pass="${GITHUB_USER}:${GITHUB_PASSWORD}"
	if test -z "$user_pass" && test -f "${HOME}/.config/hub"
	then
		oauth_line="$(grep -A2 '^github.com:' ${HOME}/.config/hub | grep '^\s*oauth_token:')"
		user_pass="${oauth_line#*:}"
	fi
	test -z "$user_pass" && die "$no_creds_msg"
	github_credentials="$user_pass"
}

get_fork () {
	resolved_fork=
	push_url=$(git config --get remote.${1}.pushurl ||
			   git config --get remote.${1}.url)
	if test -z "$push_url"
	then
		test "200" = "$(curl --user ${github_credentials} --silent --output /dev/null --write-out '%{http_code}' https://api.github.com/repos/${1})" &&
		resolved_fork="${1}"
	else
		resolved_fork=$(git config --get remote.${1}.pushurl ||
						git config --get remote.${1}.url |
							awk '{gsub(/(^.+github.com.|\.git$)/, "", $1); print $1;}')
	fi
	test -z "$resolved_fork" && die "$(gettext 'Could not resolve fork for remote ${1}')"
	echo $resolved_fork
}

resolve_forks () {
	my_fork=$(get_fork $my_repo)
	our_fork=$(get_fork $our_repo)
}

write_state () {
	echo "$target_branches" > $state_dir/opt_target_branches
	echo "$my_repo" > $state_dir/opt_my_repo
	echo "$our_repo" > $state_dir/opt_our_repo
	echo "$my_fork" > $state_dir/opt_my_fork
	echo "$our_fork" > $state_dir/opt_our_fork
	echo "$prefix" > $state_dir/opt_prefix
	echo "$commits" > $state_dir/opt_commits
	echo "$current_branch" > $state_dir/current_branch
}

source_branch () {
	echo "${1%:*}"
}

dest_branch () {
	echo "${1#$(source_branch ${1}):}"
}

resolve_target_branches () {
	resolved_target_branches=
	prefix_req_msg="
$(gettext 'If --target_branch is used without a destination
 branch mapping, --prefix must be specified.')"
	for branch in $target_branches
	do
		if test "$branch" = "$(source_branch ${branch})"
		then
			test -z "$prefix" && die $prefix_req_msg
			branch="${prefix}-${branch}:${branch}"
		fi
		test -n "${resolved_target_branches}" &&
		resolved_target_branches="${resolved_target_branches} ${branch}" ||
		resolved_target_branches="${branch}"
	done
	target_branches="$resolved_target_branches"
}

verify_branches () {
	for branch in $target_branches
	do
		src_branch="$(source_branch ${branch})"
		dst_branch="$(dest_branch ${branch})"
		test "200" = "$(curl --user ${github_credentials} --silent --output /dev/null --write-out '%{http_code}' https://api.github.com/repos/${my_fork}/branches/${src_branch})" ||
		die "$(eval_gettext 'This branch could not be verified: ${my_fork}:${src_branch}')"
		test "200" = "$(curl --user ${github_credentials} --silent --output /dev/null --write-out '%{http_code}' https://api.github.com/repos/${our_fork}/branches/${dst_branch})" ||
		die "$(eval_gettext 'This branch could not be verified: ${our_fork}:${dst_branch}')"
	done
}

initialize_ppr () {
	resolve_forks
	resolve_target_branches
	verify_branches

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
	test -f $state_dir/opt_my_repo &&
	my_repo="$(cat $state_dir/opt_my_repo)" &&
	test -f $state_dir/opt_our_repo &&
	our_repo="$(cat $state_dir/opt_our_repo)" &&
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

abort_ppr () {
	test -d $state_dir || die "$(gettext 'No ppr operation is in progress')"
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
			git rev-parse --verify --quiet "${my_repo}/${pulling_branch}" > /dev/null &&
			git push "$my_repo" ":${pulling_branch}"
		fi
	fi
	cleanup_complete_targets
}

skip_branch () {
	test -d $state_dir || die "$(gettext 'No ppr operation is in progress')"
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
		--my_repo|-u)
			test -z "${my_repo}" && test 2 -le "$#" || usage
			my_repo=$2
			shift
			;;
		--our_repo|-o)
			test -z "${our_repo}" && test 2 -le "$#" || usage
			our_repo=$2
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

require_hub
resolve_github_credentials

if test -z "$action"
then
	if test -d $state_dir
	then
		# Stolen haphazardly from git-rebase.sh
		state_dir_base=${state_dir##*/}
		cmd_live_ppr="ppr (--continue | --abort | --skip)"
		cmd_clear_stale_ppr="rm -fr \"$state_dir\""
		die "
$(eval_gettext 'It seems that there is already a $state_dir_base directory, and
I wonder if you are in the middle of another ppr run. If that is the case, please try
	$cmd_live_ppr
If that is not the case, please
	$cmd_clear_stale_ppr
and run me again.  I am stopping in case you still have something
valuable there.')"
	else
		test -n "$target_branches" &&
		test -n "$my_repo" &&
		test -n "$our_repo" || usage
	fi
	test $# -eq "0" || usage
	initialize_ppr
elif test -n "$action"
then
	if ! test -d $state_dir
	then
		die "$(gettext 'No ppr run in progress?')"
	elif test -n "${target_branches}${my_repo}${our_repo}${prefix}${commits}"
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
$(eval_gettext 'Could not read ppr state from $state_dir. Please verify
permissions on the directory and try again')"
		;;
	abort)
		abort_ppr
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
		#	! ( git branch | grep -q "^\s*${temp_branch}$" )
		#	remaining_targets
		#	topic_target
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
		#	( git branch | grep -q "^\s*${temp_branch}$" )
		#	remaining_targets
		#	topic_target
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
		#	complete_targets
		#	pull_target
		#
		echo $pulling_branch > $state_dir/pulling_branch
	else
		pulling_branch="$(cat $state_dir/pulling_branch)"
	fi

	if push_state
	then
	git push $my_repo $pulling_branch:$pulling_branch || die $resolvemsg
	# This is a reentry point (--continue)
	#	complete_targets
	#	pull_target
	#	pulling_branch
	echo $pulling_branch > $state_dir/pulling_branch_pushed
	fi

	if pull_request_state
	then
		pr_message="ppr: ${prefix} - Pull request from ${commits}"
		echo "$pr_message" > $editmsg_file
		if test -f "${state_dir}/pr_msg_${pulling_branch}"
		then
			echo "" >> $editmsg_file
			cat "${state_dir}/pr_msg_${pulling_branch}" >> $editmsg_file
		fi
		# if ! hub pull-request -m "${pr_message}" -b "${our_fork}:${pull_target}" -h "${my_fork}:${pulling_branch}" ; then
		hub pull-request -b "${our_fork}:${pull_target}" -h "${my_fork}:${pulling_branch}" || die $resolvemsg
		# This is a reentry point (--continue)
		#	complete_targets
		#	pull_target
		#	pulling_branch
		#	pulling_branch_pushed
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
