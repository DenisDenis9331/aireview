# frozen_string_literal: true
require 'uri'

module Aireview
  class MrParser
    Result = Struct.new(:platform, :url, :base_url, :project_path, :project_id, :iid, keyword_init: true)

    MR_PATH = %r{\A/(?<project>.+)/-/merge_requests/(?<iid>\d+)\z}
    # github.com and GitHub Enterprise share the path; the PR page tabs and a
    # trailing slash point at the same pull request.
    PR_PATH = %r{\A/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/(?<number>\d+)(?:/(?:files|commits|checks))?/?\z}
    # What GitHub allows in owner and repository names. Checked here, so that
    # the "owner/repo" id goes into API paths as is, and a malformed URL
    # fails as a URL error instead of a 404.
    GITHUB_NAME = /\A[A-Za-z0-9_.-]+\z/

    def self.parse(url)
      uri = URI.parse(url.to_s)
      raise ParseError, 'Merge request URL must include http:// or https://' unless uri.is_a?(URI::HTTP)

      gitlab(url, uri) || github(url, uri) || raise(ParseError, "Unsupported merge request URL: #{url}")
    rescue URI::InvalidURIError => e
      raise ParseError, "Invalid merge request URL: #{e.message}"
    end

    def self.gitlab(url, uri)
      match = MR_PATH.match(uri.path)
      return unless match

      project_path = match[:project]
      Result.new(
        platform: :gitlab,
        url: url,
        base_url: base_url(uri),
        project_path: project_path,
        project_id: URI.encode_www_form_component(project_path),
        iid: match[:iid].to_i
      )
    end

    # GitHub takes the repository as two path segments (repos/owner/repo),
    # not one encoded segment like a GitLab project id.
    def self.github(url, uri)
      match = PR_PATH.match(uri.path)
      return unless match

      owner, repo = match.values_at(:owner, :repo)
      unless [owner, repo].all? { |name| GITHUB_NAME.match?(name) }
        raise ParseError, "Unsupported pull request URL: #{url}"
      end

      Result.new(
        platform: :github,
        url: url,
        base_url: base_url(uri),
        project_path: "#{owner}/#{repo}",
        project_id: "#{owner}/#{repo}",
        iid: match[:number].to_i
      )
    end

    def self.base_url(uri)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)}"
    end

    private_class_method :gitlab, :github, :base_url
  end
end
