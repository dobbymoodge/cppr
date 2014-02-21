#!/bin/sh
# -*- indent-tabs-mode: t -*-

test -n "$DEBUG_CPPR" && set -x

if test -z "$GITHUB_HOST"
then
    GITHUB_HOST="github.com"
fi

if test "$GITHUB_HOST" = "github.com"
then
    GITHUB_API_HOST="api.github.com"
else
    GITHUB_API_HOST="${GITHUB_HOST}/api/v3"
fi

export GITHUB_HOST
export GITHUB_API_HOST

require_hub_no_creds_msg="
$(gettext 'This command requires github account credentials to be
specified either in the hub command configuration located in
$HOME/.config/hub, or in the environment variables
GITHUB_USER and GITHUB_PASSWORD.')"

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
	test -n "$GITHUB_USER" && test -n "$GITHUB_PASSWORD" && user_pass="${GITHUB_USER}:${GITHUB_PASSWORD}"
	if test -z "$user_pass" && test -f "${HOME}/.config/hub"
	then
		oauth_line="$(grep -A2 "^${GITHUB_HOST}:" ${HOME}/.config/hub | grep '^\s*oauth_token:')"
		user_pass="${oauth_line#*:}:x-oauth-basic"
	fi
	test -z "$user_pass" && return 1
	github_credentials="$user_pass"
	echo "${github_credentials}"
}
