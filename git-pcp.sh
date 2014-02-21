#!/bin/sh
# -*- indent-tabs-mode: t -*-

test -n "$DEBUG_CPPR" && set -x

SUBDIRECTORY_OK=Yes
OPTIONS_KEEPDASHDASH=
OPTIONS_SPEC="\
git pcp --target_branch <branch> [--target_branch <another branch> ...] [--my_remote <remote>] [--prefix <temp branch prefix>] <commit(s)>
git-pcp --continue | --abort | --skip
--
 Available options are
t,target_branch=!   branch or branches to cherry-pick into, or to base topic branches from when --prefix is specified
u,my_remote=!       remote repository; when specified, modified branches are pushed here
p,prefix=!          when specified, prefix to use when creating topic branches
 Actions:
continue!          continue
abort!             abort current and remaining cherry-picks and check out the original branch
skip!              skip current branch and continue
"

. git-sh-setup
. git-sh-i18n
. git-require-hub

set_reflog_action pcp
require_work_tree_exists
cd_to_toplevel

github_pr_regex="https://${GITHUB_HOST}/.\+/pull/[0-9]\+"
github_credentials=
state_dir=$GIT_DIR/pcp_state
target_branches=

# prefix for naming topic branch(es)
prefix=
# name of remote to push topic branch(es) onto
my_remote=
# git fork for my_remote (derived)
commits=
# File with list of target branches for which topic branch has been created
complete_targets=
# File with name of target branch currently being used for topic branch creation
topic_target=
# File with name of current topic branch, when creating pull request
pushing_branch=
# File with list of topic branches which have successfully been turned into pull requests
pulled_branches=
# Current target branch for which a pull request is being created
push_branch=

resolvemsg="
$(gettext 'When you have resolved this problem, run "pcp --continue".
If you prefer to skip this target branch, run "pcp --skip" instead.
To check out the original branch and stop cherry-picking, run "pcp --abort".')
"

clean_die () {
	test -d $state_dir && rm --recursive --force $state_dir
	die "$1"
}

get_fork () {
	fork=$(git config --get remote.${1}.pushurl ||
		   git config --get remote.${1}.url |
			   awk '{gsub("(^.+"ENVIRON["GITHUB_HOST"]".|\\.git$)", "", $1); print $1;}')
	if test -z "$fork"
	then
		die $(gettext "Could not resolve fork for remote ${1}")
	fi
	echo $fork
}

write_state () {
	echo "$target_branches" > $state_dir/opt_target_branches
	if test -n "$my_remote"
	then
		echo "$my_remote" > $state_dir/opt_my_remote
	fi
	test -n "$prefix" && echo "$prefix" > $state_dir/opt_prefix
	echo "$commits" > $state_dir/opt_commits
	echo "$current_branch" > $state_dir/current_branch
}

temp_branch_name () {
	tmp_branch_name=
	while test -z "$tmp_branch_name"
	do
		tbname="temp-branch-$(date '+%s%N' | md5sum | cut -b1-8)"
		git rev-parse --verify --quiet "$tbname" >/dev/null || tmp_branch_name="$tbname"
	done
	echo "$tmp_branch_name"
}

resolve_pr_to_commit () {
	pr_url="$1"
	api_url=$(echo $pr_url | awk -F '/' '{print "https://"ENVIRON["GITHUB_API_HOST"]"/repos/"$4"/"$5"/pulls/"$7;}')
	test "200" = "$(curl --user ${github_credentials} --silent --output /dev/null --write-out '%{http_code}' ${api_url})" ||
	return 1
	tmp_branch_name=$(temp_branch_name)
	if hub checkout $pr_url $tmp_branch_name 1>/dev/null 2>/dev/null
	then
		echo "$tmp_branch_name" >>$state_dir/temp_pr_branches
	else
		return 2
	fi
	echo $tmp_branch_name
}

validate_commits () {
	resolved_commits=
	for rev in $commits
	do
		if echo $rev | grep -q "$github_pr_regex"
		then
			rev="$(resolve_pr_to_commit $rev)"
			case "$?" in
				1)
					clean_die "\
$(eval_gettext 'The url $rev does not appear to be a valid github pull request URL.')"
					;;
				2)
					clean_die "\
$(eval_gettext 'Could not check out pull request $pr_url')"
					;;
			esac
		fi
		if ! git rev-parse --verify $rev 1>/dev/null 2>/dev/null
		then
			clean_die "$(eval_gettext 'Could not validate commit $rev')"
		fi
		test -n "${resolved_commits}" &&
		resolved_commits="${resolved_commits} ${rev}" ||
		resolved_commits="${rev}"
	done
	commits="$resolved_commits"
}

initialize_pcp () {
	hub_required_msg="
$(gettext 'It looks like you are using a github pull request as
a commit for cherry-picking; checking if hub is installed...')"
	if echo $commits | grep -q "$github_pr_regex"
	then
		echo $hub_required_msg
		require_hub
		github_credentials="$(resolve_github_credentials)"
		case "$?" in
			1)
				die "$require_hub_no_creds_msg"
				;;
		esac
	fi
	if test -n "$prefix"
	then
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
					echo "	  ${br}"
				done
				test -z "$conflicting_remote_branches" && exit 1
			fi

			if test -n "$conflicting_remote_branches"
			then
				echo "$(gettext 'The following remote branches conflict with the branch names generated using the prefix you provided; please remove the existing branches or select a different prefix: ')"
				for br in $conflicting_remote_branches
				do
					echo "	  ${br}"
				done
				exit 1
			fi
		fi
	fi

	if ! test -d $state_dir
	then
		# unless continue/abort/etc.
		mkdir -p "$state_dir"
	fi

	current_branch="$(git rev-parse --abbrev-ref HEAD)"

	validate_commits

	write_state

	for target in $target_branches
	do
		echo $target >> $state_dir/remaining_targets
	done
}

read_state () {
	test -f $state_dir/opt_my_remote &&
	my_remote="$(cat $state_dir/opt_my_remote)"
	test -f $state_dir/opt_prefix &&
	prefix="$(cat $state_dir/opt_prefix)"

	test -f $state_dir/opt_target_branches &&
	target_branches="$(cat $state_dir/opt_target_branches)" &&
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

delete_temp_branches () {
	if test -f $state_dir/temp_pr_branches
	then
		for tmp_branch in $(cat ${state_dir}/temp_pr_branches)
		do
			git rev-parse --verify --quiet "$tmp_branch" > /dev/null &&
			git branch -D "$tmp_branch"
		done
	fi
}

abort_pcp () {
	test -d $state_dir || die "$(gettext 'No pcp operation is in progress')"
	read_state
	if test -f "${GIT_DIR}/CHERRY_PICK_HEAD"
	then
		git cherry-pick --abort
	fi

	switch_to_safe_branch

	if test -n "$prefix"
	then
		if test -f $state_dir/complete_targets
		then
			test -f $state_dir/topic_target && topic_target="$(cat $state_dir/topic_target)"
			for branch in $(cat $state_dir/complete_targets) $topic_target
			do
				temp_branch="${prefix}-${branch}"
				git rev-parse --verify --quiet "$temp_branch" > /dev/null &&
				git branch -D "$temp_branch"
			done
		fi
		test -f $state_dir/pushing_branch && pushing_branch="$(cat $state_dir/pushing_branch)"
		test -f $state_dir/from_pr && from_pr="$(cat $state_dir/from_pr)"
		for branch in $pushing_branch $from_pr
		do
			git rev-parse --verify --quiet "$branch" > /dev/null &&
			git branch -D "$branch"
		done
	fi
	delete_temp_branches
	/bin/rm -rf $state_dir
}

skip_remaining_targets () {
	test -f $state_dir/topic_target && topic_target="$(cat $state_dir/topic_target)" || return
	test -n "${topic_target}" &&
	if test -n "$prefix"
	then
		temp_branch="${prefix}-${topic_target}"
	else
		temp_branch="${topic_target}"
	fi
	if test "$(git rev-parse --abbrev-ref HEAD)" = "${temp_branch}"
	then
		test -f "${GIT_DIR}/CHERRY_PICK_HEAD" && git cherry-pick --abort
	fi
	switch_to_safe_branch
	if test -n "$prefix" && git rev-parse --verify --quiet "$temp_branch" > /dev/null
	then
		git branch -D "$temp_branch"
	elif ! test -n "$prefix" && test -f $state_dir/pre_cp_ref
	then
		 # Revert any changes that might have happened to this branch (shouldn't be any)
		 git checkout "$temp_branch"
		 pre_cp_ref=$(cat $state_dir/pre_cp_ref)
		 test "$pre_cp_ref" = "$(git rev-parse HEAD)" || git reset --hard "$pre_cp_ref"
	fi
	remove_target_branch "$topic_target"
	/bin/rm $state_dir/topic_target
	test -f $state_dir/pre_cp_ref && /bin/rm $state_dir/pre_cp_ref
}

cleanup_complete_targets () {
	test -f $state_dir/pushing_branch && /bin/rm $state_dir/pushing_branch
	test -f $state_dir/push_branch && /bin/rm $state_dir/push_branch
	test -z "$(cat $state_dir/complete_targets)" && /bin/rm $state_dir/complete_targets
}

skip_complete_targets () {
	test -f $state_dir/push_branch && push_branch="$(cat $state_dir/push_branch)" || return
	if test -f $state_dir/pushing_branch
	then
		pushing_branch="$(cat $state_dir/pushing_branch)"
	else
		test -n "${push_branch}" &&
		if test -n "$prefix"
		then
			pushing_branch="${prefix}-${push_branch}"
		else
			pushing_branch="${push_branch}"
		fi
	fi
	switch_to_safe_branch
	cleanup_complete_targets
}

skip_branch () {
	test -d $state_dir || die "$(gettext 'No pcp operation is in progress')"
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
		--prefix|-p)
			test -z "${prefix}" && test 2 -le "$#" || usage
			prefix=$2
			shift
			;;
		--continue|--skip|--abort)
			test $total_argc -eq 2 || usage
			action=${1##--}
			;;
		[!-]*)
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
		cmd_live_pcp="pcp (--continue | --abort | --skip)"
		cmd_clear_stale_pcp="rm -fr \"$state_dir\""
		die "
$(eval_gettext 'It seems that there is already a $state_dir_base directory, and
I wonder if you are in the middle of another pcp run. If that is the case, please try
	$cmd_live_pcp
If that is not the case, please
	$cmd_clear_stale_pcp
and run me again.  I am stopping in case you still have something
valuable there.')"
	else
		test -n "$target_branches" || usage
	fi
	test $# -ge "1" || usage
	commits="$@"
	initialize_pcp
elif test -n "$action"
then
	if ! test -d $state_dir
	then
		die "$(gettext 'No pcp run in progress?')"
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
$(eval_gettext 'Could not read pcp state from $state_dir. Please verify
permissions on the directory and try again')"
		;;
	abort)
		abort_pcp
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
	! test -f $state_dir/pre_cp_ref
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
	test -n "$prefix" &&
	temp_branch=$prefix-$topic_target ||
	temp_branch=$topic_target

	if checkout_state
	then
		if test -n "$prefix"
		then
			git checkout -B $temp_branch $topic_target || die $resolvemsg
		else
			git checkout $temp_branch || die $resolvemsg
		fi
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

push_branch_state () {
	test -f $state_dir/complete_targets &&
	! test -f $state_dir/push_branch
}

checkout_pushing_branch_state () {
	test -f $state_dir/complete_targets &&
	test -f $state_dir/push_branch &&
	! test -f $state_dir/pushing_branch
}

push_state () {
	test -f $state_dir/complete_targets &&
	test -f $state_dir/push_branch &&
	test -f $state_dir/pushing_branch
}

if test -n "$my_remote"
then
	while ( test -f $state_dir/complete_targets ) ; do
		# MAKE PRs
		if push_branch_state
		then
			push_branch=$(head --lines=1 $state_dir/complete_targets)
			# Move push_branch from complete_targets:
			echo $push_branch > $state_dir/push_branch
			sed --in-place --expression='1d' $state_dir/complete_targets
		else
			push_branch="$(cat $state_dir/push_branch)"
		fi

		if checkout_pushing_branch_state
		then
			if test -n "$prefix"
			then
				pushing_branch="${prefix}-${push_branch}"
			else
				pushing_branch="${push_branch}"
			fi
			git checkout $pushing_branch || die $resolvemsg
			# This is a reentry point (--continue)
			#	complete_targets
			#	push_branch
			#
			echo $pushing_branch > $state_dir/pushing_branch
		else
			pushing_branch="$(cat $state_dir/pushing_branch)"
		fi

		if push_state
		then
			git push $my_remote $pushing_branch:$pushing_branch || die $resolvemsg
			# This is a reentry point (--continue)
			#	complete_targets
			#	push_branch
			#	pushing_branch
			/bin/rm $state_dir/pushing_branch
			/bin/rm $state_dir/push_branch
			test -z "$(cat $state_dir/complete_targets)" && /bin/rm $state_dir/complete_targets
		fi
	done
else
	test -f "$state_dir/complete_targets" && /bin/rm $state_dir/complete_targets
fi

if ! test -f $state_dir/complete_targets && ! test -f $state_dir/remaining_targets
then
	git checkout "$current_branch"
	delete_temp_branches
	/bin/rm $state_dir/*
	/usr/bin/rmdir $state_dir
fi
