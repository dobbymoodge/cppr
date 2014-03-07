#!/usr/bin/env ruby

# Small script to extract commit info from github pull request URLs
# for use in a shell script

# Outputs space-separated list of commits for provided PR URL

# Returns 1 if the PR URL can't be parsed into a valid API call or if
# no URL is provided

require 'hub'
require 'uri'

include Hub

module Hub
  class GitHubAPI

    def get_commits_for_pr(pr_url, num_tries=3)
      github_api_host = ENV['GITHUB_API_HOST'] || 'api.github.com'
      uri = URI pr_url
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
  end
end

@api_client ||= begin
  config_file = ENV['HUB_CONFIG'] || File.join(ENV['HOME'], '.config', 'hub')
  file_store = GitHubAPI::FileStore.new File.expand_path(config_file)
  file_config = GitHubAPI::Configuration.new file_store
  GitHubAPI.new file_config, :app_url => 'http://hub.github.com/'
end

exit! false unless ARGV[0]

begin
  puts @api_client.get_commits_for_pr(ARGV[0]).join(' ')
  exit! true
rescue Net::HTTPServerException
  exit! false
end
