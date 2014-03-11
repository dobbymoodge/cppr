#!/usr/bin/env ruby

# Small script to perform various github API operations:
#  * Extract commit info from github pull request URLs for use in a
#    shell script
#    - Outputs space-separated list of commits for provided PR URL
#  * Verify a pull request URL references a valid PR
#  * Verify that a specified branch exists for a given fork (repo)
#  * Verify that a given fork/repo exists

# Returns 1 for general failures and 2 or 3 for particular exceptions.

# This script is intended to be run from other scripts, so output is
# minimal

require 'hub'
require 'uri'
require 'getoptlong'
require 'net/http'

def usage
  puts <<USAGE
  Usage: git-cppr--github-helper [--help]
     or: git-cppr--github-helper [--commits-for-pr <pull URL>]
     or: git-cppr--github-helper [--verify-pull <pull URL>]
     or: git-cppr--github-helper [--verify-branch <branch>] [--fork <fork>]
     or: git-cppr--github-helper [--verify-fork <fork>]
USAGE
  exit 255
end

opts = GetoptLong.new(
  ["--help", "-h",     GetoptLong::NO_ARGUMENT],
  ["--commits-for-pr", GetoptLong::REQUIRED_ARGUMENT],
  ["--verify-pull",    GetoptLong::REQUIRED_ARGUMENT],
  ["--verify-branch",  GetoptLong::REQUIRED_ARGUMENT],
  ["--fork",           GetoptLong::REQUIRED_ARGUMENT],
  ["--verify-fork",    GetoptLong::REQUIRED_ARGUMENT],
)

commits_pull = verify_pull = github_branch = my_fork = github_fork = nil

opts.each do |opt, arg|
  case opt
  when '--help'
    usage
  when '--commits-for-pr'
    usage if verify_pull or github_branch or github_fork
    commits_pull = arg
  when '--verify-pull'
    usage if commits_pull or github_branch or github_fork
    verify_pull = arg
  when '--verify-branch'
    usage if commits_pull or github_fork or verify_pull
    github_branch = arg
  when '--fork'
    usage if commits_pull or github_fork or verify_pull
    my_fork = arg
  when '--verify-fork'
    usage if commits_pull or github_branch or my_fork or verify_pull
    github_fork = arg
  end
end

if (github_branch and not my_fork) or (my_fork and not github_branch)
  usage
end

include Hub

module Hub
  class GitHubAPI

    def github_api_host
      ENV['GITHUB_API_HOST'] || 'api.github.com'
    end

    def get_commits_for_pr (pull_request, num_tries=3)
      uri = URI pull_request
      _, pr_user, pr_repo, _, pr_id = uri.path.split('/')
      commits = nil
      (1..num_tries).each do |i|
        res = get "https://#{github_api_host}/repos/#{pr_user}/#{pr_repo}/pulls/#{pr_id}/commits"
        if res.success?
          commits = res.data
          break
        elsif i == num_tries
          res.error!
        end
        sleep 1
      end
      commits.map do |commit|
        commit['sha']
      end
    end

    def verify_pull (pull_request, num_tries=3)
      uri = URI pull_request
      _, pr_user, pr_repo, _, pr_id = uri.path.split('/')
      commits = nil
      (1..num_tries).each do |i|
        res = get "https://#{github_api_host}/repos/#{pr_user}/#{pr_repo}/pulls/#{pr_id}"
        if res.success?
          return true
        end
        sleep 1
      end
      return false
    end

    def verify_branch (gh_branch, b_fork, num_tries=3)
      (1..num_tries).each do |i|
        res = get "https://#{github_api_host}/repos/#{b_fork}/branches/#{gh_branch}"
        if res.success?
          return true
        end
        sleep 1
      end
      return false
    end

    def verify_fork (gh_fork, num_tries=3)
      (1..num_tries).each do |i|
        res = get "https://#{github_api_host}/repos/#{gh_fork}"
        if res.success?
          return true
        end
        sleep 1
      end
      return false
    end
  end
end

@api_client ||= begin
  config_file = ENV['HUB_CONFIG'] || File.join(ENV['HOME'], '.config', 'hub')
  file_store = GitHubAPI::FileStore.new File.expand_path(config_file)
  file_config = GitHubAPI::Configuration.new file_store
  GitHubAPI.new file_config, :app_url => 'http://hub.github.com/'
end

begin
  if commits_pull
    puts "#{@api_client.get_commits_for_pr(commits_pull).join(' ')}\n"
  elsif verify_pull and not @api_client.verify_pull(verify_pull)
    exit 1
  elsif github_branch and not @api_client.verify_branch(github_branch, my_fork)
    exit 1
  elsif github_fork and not @api_client.verify_fork(github_fork)
    exit 1
  end
rescue Net::HTTPServerException
  exit 2
rescue URI::InvalidURIError
  exit 3
end
