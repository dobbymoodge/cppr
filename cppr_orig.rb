#!/usr/bin/env ruby

require 'getoptlong'

def usage
  puts <<USAGE
Usage: cppr [--help|-h] [--target|-t base_branch_1] [--target|-t base_branch_2] ... [--base-fork|-b base_user/base_repo] [--head-remote|-e head_remote] [[--prefix|-p topic_branch] [--from-commits|-c COMMITS]] [[--from-pull-request|-f https://url.to/pull/id]]
USAGE
  exit 255
end

opts = GetoptLong.new(
       ["--help", "-h", GetoptLong::NO_ARGUMENT],
       ["--prefix", "-p", GetoptLong::REQUIRED_ARGUMENT],
       ["--target", "-t", GetoptLong::REQUIRED_ARGUMENT],
       ["--base-fork", "-b", GetoptLong::REQUIRED_ARGUMENT],
       ["--head-remote", "-e", GetoptLong::REQUIRED_ARGUMENT],
       ["--from-commits", "-c", GetoptLong::NO_ARGUMENT],
       ["--from-pull-request", "-f", GetoptLong::NO_ARGUMENT]
     )

branch_prefix = nil
targets = []
base_fork = nil
head_remote = nil
from_commits = nil
from_pull_request = nil

opts.each do |opt, arg|
  case opt.downcase
  when '--help'
    usage
  when '--prefix'
    usage if (branch_prefix or from_pull_request)
    branch_prefix = arg
  when '--target'
    targets.push arg
  when '--base-fork'
    usage if base_fork
    base_fork = arg
  when '--head-remote'
    usage if head_remote
    head_remote = arg
  when '--from-commits'
    usage if (from_commits or from_pull_request)
    from_commits = true
  when '--from-pull-request'
    usage if (from_commits or from_pull_request)
    from_pull_request = true
  end
end

if ARGV.length < 1
  puts "Missing COMMITS or pull request argument(s)"
  usage
end

commits = ARGV.join ' ' if from_commits
pull_request = ARGV.shift if from_pull_request

hub_path = `command -v hub`
if $?.exitstatus != 0
  puts 'Could not find the "hub" executable in your path. Please make sure that hub is installed: http://hub.github.com/'
  exit 1
end

head_fork = `hub remote show #{head_remote} | grep 'Push \\+URL:'`.split(/(:|\.)/)[-3]
current_branch = `hub rev-parse --abbrev-ref HEAD`.strip
current_directory = Dir.getwd
repo_toplevel = `hub rev-parse --show-toplevel`.strip
puts "Changing directory to repo top-level directory #{repo_toplevel}"
Dir.chdir "#{repo_toplevel}" do

  if from_pull_request
    puts "Checking out pull request at #{pull_request}"
    output = `hub checkout #{pull_request}`
    exit_code = $?.exitstatus
    if exit_code != 0
      puts "Failed checkout of pull request branch #{pull_request}:"
      puts output
      exit 1
    end
    commits = branch_prefix = `hub rev-parse --abbrev-ref HEAD`.strip
    output = `hub push #{head_remote} #{branch_prefix}`
    exit_code = $?.exitstatus
    if exit_code != 0
      puts "Failed push of pull request branch #{branch_prefix} to base remote #{head_remote} branch #{branch_prefix}:"
      puts output
      exit 1
    end
  end

  targets.each do |target_br|
    temp_br = "#{branch_prefix}-#{target_br}"
    pr_command = nil
      pr_command = %{
set -ex
    hub checkout -b "#{temp_br}" "#{target_br}"
    hub cherry-pick "#{commits}"
    hub push "#{head_remote}" "#{temp_br}"
    hub pull-request -m "oo-cpr: #{branch_prefix} - Pull request from #{commits}" \
        -b "#{base_fork}:#{target_br}" \
        -h "#{head_fork}:#{temp_br}"
}
    puts ""
    puts "Attempting to create pull request against #{head_fork}:#{target_br}"
    output = `#{pr_command}`
    exit_code = $?.exitstatus
    puts "Pull request for target branch #{head_fork}:#{target_br} failed, see output for details:" if exit_code != 0
    puts output
  end

  puts "Pull requests attempted, switching back to branch #{current_branch}"
  puts `hub checkout #{current_branch}`
end
