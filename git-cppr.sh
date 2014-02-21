#!/bin/sh
# -*- indent-tabs-mode: t -*-

test -n "$DEBUG_CPPR" && set -x

SUBDIRECTORY_OK=Yes
OPTIONS_KEEPDASHDASH=
OPTIONS_SPEC="\
git cppr --target_branch <branch> [--target_branch <another branch> ...] --my_remote <remote> --our_remote <remote> --prefix <temp branch prefix> <commit(s)>
git-cppr --continue | --abort
--
 Available options are
t,target_branch=!  branch to create pull request against
u,my_remote=!      remote to push topic branches to, from which pull requests will be made
o,our_remote=!     remote against which pull requests will be created
p,prefix=!         prefix to use when creating topic branches
 Actions:
continue!          continue
abort!             abort and check out the original branch
"

LONG_USAGE="\
This is a test
"

. git-sh-setup
. git-sh-i18n
. git-require-hub

set_reflog_action cppr
require_work_tree_exists
cd_to_toplevel

state_dir="${GIT_DIR}/cppr_state"
pr_desc_dir="${state_dir}/pr_desc"
target_branches=

# prefix for naming topic branch(es)
prefix=
# name of remote to push topic branch(es) onto
my_remote=
# name of remote to stage PR against
our_remote=
# List of commits to build PR from
commits=

resolvemsg="
$(gettext 'When you have resolved this problem, run "cppr --continue".
To check out the original branch and stop creating pull requests, run "cppr --abort".')
"

write_state () {
	echo "$target_branches" > $state_dir/opt_target_branches
	echo "$my_remote" > $state_dir/opt_my_remote
	echo "$our_remote" > $state_dir/opt_our_remote
	echo "$prefix" > $state_dir/opt_prefix
	echo "$commits" > $state_dir/opt_commits
	echo "$current_branch" > $state_dir/current_branch
}

initialize_cppr () {
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

	current_branch="$(git rev-parse --abbrev-ref HEAD)"

	if ! test -d $state_dir
	then
		# unless continue/abort/etc.
		mkdir -p "$state_dir"
		mkdir -p "$pr_desc_dir"
	fi

	write_state

	for target in $target_branches
	do
		dst_target="${prefix}-${target}"
		echo "$target" >>$state_dir/pcp_targets
		git rev-parse $target >"${state_dir}/${dst_target}_head_ref"
	done
}

read_state () {
	test -f $state_dir/opt_target_branches &&
	target_branches="$(cat $state_dir/opt_target_branches)" &&
	test -f $state_dir/opt_my_remote &&
	my_remote="$(cat $state_dir/opt_my_remote)" &&
	test -f $state_dir/opt_our_remote &&
	our_remote="$(cat $state_dir/opt_our_remote)" &&
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

abort_cppr () {
	test -f "${GIT_DIR}/pcp_state" && git pcp --abort
	test -f "${GIT_DIR}/ppr_state" && git ppr --abort
	switch_to_safe_branch
	/bin/rm --recursive --force $state_dir
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
		--continue|--abort)
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
		cmd_live_cppr="cppr (--continue | --abort)"
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
		read_state || die "
$(eval_gettext 'Could not read cppr state from $state_dir. Please verify
permissions on the directory and try again')"
		;;
	abort)
		read_state
		abort_cppr
		exit 0
		;;
esac

# Cherry-pick
cp_target_branch_args () {
	local tbargs=
	for branch in $target_branches
	do
		test -n "${tbargs}" &&
		tbargs="${tbargs} --target_branch ${branch}" ||
		tbargs="--target_branch ${branch}"
	done
	echo $tbargs
}

determine_cped_branches () {
	missing_branches=
	for branch in $target_branches
	do
		temp_branch="${prefix}-${branch}"
		if git rev-parse --verify --quiet "$temp_branch" > /dev/null
		then
			echo "$branch" >>$state_dir/cped_branches
		else
			echo "$(eval_gettext 'WARNING: Branch ${branch} lacks corresponding cherry-pick branch ${temp_branch}')"
			missing_branches="true"
		fi
	done
	test -n "$missing_branches" && echo "$(eval_gettext 'WARNING: No pull requests will be generated for these branches')"
}

bare_state () {
	test -f $state_dir/pcp_targets &&
	! test -f $state_dir/pcp_in_progress
}

pcp_in_progress_state () {
	test -f $state_dir/pcp_targets &&
	test -f $state_dir/pcp_in_progress
}

pull_request_needed () {
	test -f $state_dir/cped_branches &&
	test -n "$(cat ${state_dir}/cped_branches)"
}

probably_pcp_failure="$(gettext 'This probably means that the git pcp subcommand is in the midst of a failure.')"

while test -f $state_dir/pcp_targets
do
	if bare_state
	then
		pcp_args="$(cp_target_branch_args) --my_remote ${my_remote} --prefix ${prefix} ${commits}"
		echo "true" >$state_dir/pcp_in_progress
		git pcp $pcp_args || die "\
$(eval_gettext 'The git pcp subcommand has encountered a problem.
$resolvemsg')"
	elif pcp_in_progress_state
	then
# 		test -d "${GIT_DIR}/pcp_state" && die "\
# $(eval_gettext 'There appears to be a git pcp subcommand in progress already.
# $probably_pcp_failure
# $resolvemsg')"
		if test -d "${GIT_DIR}/pcp_state"
		then
			git pcp --continue || die "\
$(eval_gettext 'The git pcp subcommand has encountered a problem.
$resolvemsg')"
		fi
		test -f "${GIT_DIR}/CHERRY_PICK_HEAD" && die "\
$(eval_gettext 'There appears to be a git cherry-pick subcommand in progress.
$probably_pcp_failure
$resolvemsg')"
		determine_cped_branches
		mv $state_dir/pcp_in_progress $state_dir/pcp_complete
		/bin/rm $state_dir/pcp_targets
		if ! pull_request_needed
		then
			echo "$(gettext 'No branches exist for creating pull requests.')"
			abort_cppr
			exit
		fi
	fi
done

# Pull request
write_pr_desc () {
	branch="$1"
	temp_branch="${prefix}-${branch}"
	test -f "${state_dir}/${temp_branch}_head_ref" || return
	pre_cp_ref="$(cat ${state_dir}/${temp_branch}_head_ref)"
	git checkout "$temp_branch"
	git log "${pre_cp_ref}"..HEAD > "${pr_desc_dir}/${temp_branch}:${branch}"
	switch_to_safe_branch
}

pr_target_branch_args () {
	local tbargs=
	test -f $state_dir/cped_branches || return
	for branch in $(cat ${state_dir}/cped_branches)
	do
		temp_branch="${prefix}-${branch}"
		mapping="${temp_branch}:${branch}"
		test -n "${tbargs}" &&
		tbargs="${tbargs} --target_branch ${mapping}" ||
		tbargs="--target_branch ${mapping}"
		write_pr_desc "$branch"
	done
	echo $tbargs
}

pull_request_state () {
	pull_request_needed &&
	test -f $state_dir/pcp_complete &&
	! test -f $state_dir/ppr_in_progress
}

ppr_in_progress_state () {
	pull_request_needed &&
	test -f $state_dir/pcp_complete &&
	test -f $state_dir/ppr_in_progress
}

probably_ppr_failure="$(gettext 'This probably means that the git ppr subcommand is in the midst of a failure.')"

while test -f $state_dir/cped_branches
do
	if pull_request_state
	then
		echo "true" >$state_dir/ppr_in_progress
		ppr_args="$(pr_target_branch_args) --my_repo ${my_remote} --our_repo ${our_remote} --prefix ${prefix} --pr_msg_dir ${pr_desc_dir}"
		git ppr $ppr_args || die "\
$(eval_gettext 'The git-ppr subcommand has encountered a problem.
$resolvemsg')"
	elif ppr_in_progress_state
	then
# 		test -d "${GIT_DIR}/ppr_state" && die "\
# $(eval_gettext 'There appears to be a git ppr subcommand in progress.
# $probably_ppr_failure
# $resolvemsg')"
 		if test -d "${GIT_DIR}/ppr_state"
		then
			git ppr --continue || die "\
$(eval_gettext 'The git-ppr subcommand has encountered a problem.
$resolvemsg')"
		fi
		echo "$(gettext 'All pull request operations appear to be complete.')"
		/bin/rm $state_dir/cped_branches
	fi
done

if ! test -f $state_dir/pcp_targets && ! test -f $state_dir/cped_branches
then
	switch_to_safe_branch
	/bin/rm --recursive --force $state_dir
fi
