#!/bin/sh
# -*- indent-tabs-mode: t -*-

SUBDIRECTORY_OK=Yes
OPTIONS_KEEPDASHDASH=
OPTIONS_SPEC="\
git ppr --target_branch <destination branch or source branch:destination branch> [--target_branch <another branch/mapping> ...] --my_repo <remote/github repo> --our_repo <remote/github repo> [--prefix <temp branch prefix>] [--pr_msg_dir <path/to/pr_message_files>]
git-ppr --continue | --abort | --skip
--
 Available options are
t,target_branch=!  branch to create pull request against
u,my_repo=!        remote or github repository from which pull requests will be made
o,our_repo=!       remote or github repository (e.g. owner/repo) against which pull requests will be created
p,prefix=!         prefix to use when mapping topic branches to target branches
m,pr_msg_dir=!     path to directory containing files with prepared pull request descriptions for each target branch mapping
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
# name of remote to push topic branch(es) onto
my_repo=
# git fork for my_repo (derived)
my_fork=
# name of remote to stage PR against
our_repo=
# git fork for our_repo (derived)
our_fork=
# prefix for naming topic branch(es)
prefix=
# directory containing prepared pull request descriptions named
# source_branch:destination_branch - primarily for use with cppr
pr_msg_dir=

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
	unalias hub 2>/dev/null 1>/dev/null
	type hub >/dev/null || die $req_msg
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
		user_pass="${oauth_line#*:}:x-oauth-basic"
	fi
	test -z "$user_pass" && die "$no_creds_msg"
	github_credentials="$user_pass"
	echo "github_credentials: ${github_credentials}"
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
	echo "$pr_msg_dir" > $state_dir/opt_pr_msg_dir
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
	test -f $state_dir/opt_prefix &&
	prefix="$(cat $state_dir/opt_prefix)"
	test -f $state_dir/opt_pr_msg_dir &&
	pr_msg_dir="$(cat $state_dir/opt_pr_msg_dir)"

	test -f $state_dir/opt_target_branches &&
	target_branches="$(cat $state_dir/opt_target_branches)" &&
	test -f $state_dir/opt_my_repo &&
	my_repo="$(cat $state_dir/opt_my_repo)" &&
	test -f $state_dir/opt_our_repo &&
	our_repo="$(cat $state_dir/opt_our_repo)" &&
	test -f $state_dir/opt_my_fork &&
	my_fork="$(cat $state_dir/opt_my_fork)" &&
	test -f $state_dir/opt_our_fork &&
	our_fork="$(cat $state_dir/opt_our_fork)"
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

abort_ppr () {
	test -d $state_dir || die "$(gettext 'No ppr operation is in progress')"
	/bin/rm --recursive --force $state_dir
}


skip_branch () {
	test -d $state_dir || die "$(gettext 'No ppr operation is in progress')"
	read_state
	test -f $state_dir/current_target && current_target="$(cat ${state_dir}/current_target)"
	/bin/rm $state_dir/current_target
	if test -f $state_dir/remaining_targets
	then
		test "$(head --lines=1 ${state_dir}/remaining_targets)" = "$current_target" &&
		sed --in-place --expression='1d' $state_dir/remaining_targets
		test -z "$(cat $state_dir/remaining_targets)" && /bin/rm $state_dir/remaining_targets
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
		--pr_msg_dir|-m)
			test -z "${pr_msg_dir}" && test 2 -le "$#" || usage
			pr_msg_dir=$2
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
		state_dir_base=${state_dir##*/}
		cmd_live_ppr="ppr (--continue | --abort | --skip)"
		cmd_clear_stale_ppr="rm --recursive --force \"$state_dir\""
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
	elif test -n "${target_branches}${my_repo}${our_repo}${prefix}${pr_msg_dir}"
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

while ( test -f $state_dir/remaining_targets ) ; do
	if test -f $state_dir/current_target
	then
		current_target="$(cat ${state_dir}/current_target)"
	else
		current_target=$(head --lines=1 $state_dir/remaining_targets)
		echo $current_target > $state_dir/current_target
		sed --in-place --expression='1d' $state_dir/remaining_targets
	fi
	src_branch="$(source_branch ${current_target})"
	dst_branch="$(dest_branch ${current_target})"
	pr_message="Generated pull request from git-ppr"
	echo "$pr_message" > $editmsg_file
	if test -f "${pr_msg_dir}/${current_target}"
	then
		echo "" >> $editmsg_file
		cat "${pr_msg_dir}/${current_target}" >> $editmsg_file
	fi
	hub pull-request -b "${our_fork}:${dst_branch}" -h "${my_fork}:${src_branch}" || die $resolvemsg
	echo $current_target > $state_dir/completed_targets
	/bin/rm $state_dir/current_target
	test -f "${pr_msg_dir}/${current_target}" && /bin/rm "${pr_msg_dir}/${current_target}"
	test -z "$(cat $state_dir/remaining_targets)" && /bin/rm $state_dir/remaining_targets
done

if ! test -f $state_dir/remaining_targets
then
	/bin/rm --recursive --force $state_dir
fi
