# frozen_string_literal: true
require 'json'
require 'uri'
require_relative 'errors'
require_relative 'utils'

module Aireview
  # GitHub pull requests in the shapes the rest of the review knows from
  # GitLab: the merge request hash, change hashes with old/new paths and a
  # diff, notes with an author id. Method names follow GitlabClient, so the
  # CLI and the publisher do not care which platform answers.
  class GithubClient
    # A 403: for /user it means the token has no user to read.
    class ForbiddenError < ApiError; end

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    PER_PAGE = 100
    # The files endpoint stops at 3000 files (30 pages); comments have no
    # such cap. Past the limit the walk fails instead of stopping: with an
    # incomplete comment list the publisher would not find its own review
    # and would post a second one.
    PAGE_LIMIT = 100
    API_VERSION = '2022-11-28'
    GITHUB_COM_API = 'https://api.github.com'

    # github.com has its API on a separate host, GitHub Enterprise under /api/v3.
    def self.api_url_for(base_url)
      host = URI.parse(base_url).host
      %w[github.com www.github.com].include?(host) ? GITHUB_COM_API : "#{base_url}/api/v3"
    end

    def initialize(api_url:, token:, review_author: nil, logger: Logger.new($stderr), connection: nil)
      require 'faraday'

      raise ConfigError, 'GitHub API URL is required' if Aireview::Utils.blank?(api_url)
      raise ConfigError, 'GitHub token is required' if Aireview::Utils.blank?(token)

      @logger = logger
      @token = token
      @review_author = review_author
      @connection = connection || build_connection(api_url)
    end

    # diff_refs carries the merge base — the same meaning as GitLab's
    # diff_refs.base_sha. The PR diff is taken against it, and it can move
    # while the head stays: when the base branch takes in part of the PR's
    # history. The compare goes against the base branch as it is now, not
    # against base.sha.
    def fetch_merge_request(repo, number)
      pull = get_json("repos/#{repo}/pulls/#{number}")
      validate_pull!(pull)
      head_sha = pull.dig('head', 'sha')
      base_ref = pull.dig('base', 'ref')
      compare = get_json("repos/#{repo}/compare/#{escape_ref(base_ref)}...#{head_sha}", per_page: 1)
      merge_base = compare.dig('merge_base_commit', 'sha') if compare.is_a?(Hash)
      raise ApiError, 'GitHub did not return the merge base of the pull request' if Aireview::Utils.blank?(merge_base)

      {
        'title' => pull['title'],
        'description' => pull['body'],
        'author' => {'name' => pull.dig('user', 'login')},
        'source_branch' => pull.dig('head', 'ref'),
        'target_branch' => base_ref,
        'sha' => head_sha,
        'diff_refs' => {'base_sha' => merge_base, 'head_sha' => head_sha},
        'changed_files' => pull['changed_files']
      }
    end

    def fetch_merge_request_changes(repo, number)
      get_pages("repos/#{repo}/pulls/#{number}/files", 'files').map { |file| change(file) }
    end

    # PR conversation comments are issue comments in the GitHub API. They
    # come oldest first; the publisher expects newest first, like GitLab
    # notes sorted by creation time descending.
    def fetch_merge_request_notes(repo, number)
      get_pages("repos/#{repo}/issues/#{number}/comments", 'comments').reverse.map do |comment|
        {
          'id' => comment['id'],
          'body' => comment['body'],
          'author' => {'id' => comment.dig('user', 'login')},
          'system' => false
        }
      end
    end

    def post_merge_request_note(repo, number, body)
      send_json(:post, "repos/#{repo}/issues/#{number}/comments", body: body)
    end

    def update_merge_request_note(repo, _number, comment_id, body)
      send_json(:patch, "repos/#{repo}/issues/comments/#{comment_id}", body: body)
    end

    # The login is the author id the publisher matches comments by. A token
    # that cannot read /user (the Actions GITHUB_TOKEN, a GitHub App
    # installation token) needs the login given explicitly: inside Actions a
    # workflow may comment as its own App, so github-actions[bot] is not
    # guessed — a wrong guess would miss the review and post a duplicate.
    def fetch_current_user
      return {'id' => @review_author} if Aireview::Utils.present?(@review_author)

      {'id' => get_json('user')['login']}
    rescue ForbiddenError => e
      raise ApiError, 'GitHub token cannot read its user; set GITHUB_REVIEW_AUTHOR to the login that posts ' \
                      "the comments (github-actions[bot] for the Actions GITHUB_TOKEN). #{e.message}"
    end

    private

    def validate_pull!(pull)
      valid = pull.is_a?(Hash) && %w[head base].all? { |side| pull[side].is_a?(Hash) } &&
              Aireview::Utils.present?(pull.dig('head', 'sha')) && Aireview::Utils.present?(pull.dig('base', 'ref'))
      raise ApiError, 'GitHub API returned an invalid pull request payload' unless valid
    end

    # A file without a patch is a binary or a diff too large for GitHub; it
    # has no mode fields either. Only a rename without changes explains an
    # empty diff, everything else counts as unavailable — the report must not
    # claim that a binary was reviewed. An empty new file ends up there too.
    def change(file)
      status = file['status']
      patch = file['patch'].to_s
      pure_rename = status == 'renamed' && file['changes'].to_i.zero?
      {
        'old_path' => file['previous_filename'] || file['filename'],
        'new_path' => file['filename'],
        'diff' => patch,
        'new_file' => status == 'added',
        'deleted_file' => status == 'removed',
        'renamed_file' => status == 'renamed',
        'too_large' => patch.empty? && !pure_rename
      }
    end

    # Pages are followed by the Link header, not counted: GitHub decides
    # where the list ends.
    def get_pages(path, what)
      items = []
      url = path
      params = {per_page: PER_PAGE}

      PAGE_LIMIT.times do
        response = request(:get, url, params)
        batch = parse_json(response)
        raise ApiError, "GitHub API returned an invalid #{what} list" unless batch.is_a?(Array)

        items.concat(batch)
        url = next_page(response)
        return items unless url

        params = {}
      end

      raise ApiError, "Pull request has more than #{PAGE_LIMIT * PER_PAGE} #{what}"
    end

    def next_page(response)
      link = response.headers['link'].to_s
      link.split(',').each do |part|
        match = /<([^>]+)>\s*;\s*rel="next"/.match(part)
        return match[1] if match
      end
      nil
    end

    # Branch names may hold characters that mean something in a URL; the
    # slashes of a branch name stay, GitHub reads them as part of the ref.
    def escape_ref(ref)
      ref.split('/').map { |part| URI.encode_www_form_component(part).gsub('+', '%20') }.join('/')
    end

    def build_connection(api_url)
      Faraday.new(url: "#{api_url.chomp('/')}/") do |builder|
        builder.request :json
        builder.options.open_timeout = OPEN_TIMEOUT
        builder.options.timeout = READ_TIMEOUT
        builder.adapter Faraday.default_adapter
      end
    end

    def get_json(path, params = {})
      parse_json(request(:get, path, params))
    end

    def request(method, path, params)
      @connection.public_send(method, path, params, headers)
    rescue Faraday::Error => e
      raise ApiError, "GitHub API request failed: #{e.message}"
    end

    def send_json(method, path, body)
      response = @connection.public_send(method, path) do |request|
        request.headers.update(headers)
        request.body = JSON.generate(body)
      end
      parse_json(response)
    rescue Faraday::Error => e
      raise ApiError, "GitHub API request failed: #{e.message}"
    end

    def parse_json(response)
      status = response.status.to_i
      body = response.body.to_s

      return JSON.parse(body) if status.between?(200, 299)
      raise ForbiddenError, "GitHub API error #{status}: #{body}" if status == 403

      raise ApiError, "GitHub API error #{status}: #{body}"
    rescue JSON::ParserError
      raise ApiError, "GitHub API returned invalid JSON: #{body}"
    end

    def headers
      {
        'Accept' => 'application/vnd.github+json',
        'Authorization' => "Bearer #{@token}",
        'Content-Type' => 'application/json',
        'X-GitHub-Api-Version' => API_VERSION
      }
    end
  end
end
