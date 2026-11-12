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
    REDIRECT_LIMIT = 5
    REDIRECT_STATUSES = [301, 302, 307, 308].freeze
    # GitHub limits issue and PR comment bodies to 65,536 characters.
    MAX_COMMENT_LENGTH = 65_536
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
      @base_uri = URI.parse("#{api_url.chomp('/')}/")
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
      send_json(:post, "repos/#{repo}/issues/#{number}/comments", body: fit_comment_body(body))
    end

    def update_merge_request_note(repo, _number, comment_id, body)
      send_json(:patch, "repos/#{repo}/issues/comments/#{comment_id}", body: fit_comment_body(body))
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
    # Note: Git does not track line counts for binary files, so a binary file
    # renamed with byte modifications also reports changes == 0 without a patch;
    # without a base blob comparison this is indistinguishable from a pure rename.
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
        response = request(:get, url, params: params)
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
      parse_json(request(:get, path, params: params))
    end

    def request(method, path, params: nil, body: nil)
      current_path = path
      current_params = params
      redirects = 0

      loop do
        response = execute_request(method, current_path, current_params, body)
        return response unless REDIRECT_STATUSES.include?(response.status.to_i)

        redirects += 1
        raise ApiError, 'Too many redirects from GitHub API' if redirects > REDIRECT_LIMIT

        current_path, current_params = follow_redirect(response, current_path, current_params)
      end
    rescue Faraday::Error => e
      raise ApiError, "GitHub API request failed: #{e.message}"
    end

    def send_json(method, path, body)
      parse_json(request(method, path, body: body))
    end

    def execute_request(method, path, params, body)
      if body.nil?
        @connection.public_send(method, path, params, headers)
      else
        @connection.public_send(method, path) do |request|
          request.headers.update(headers)
          request.body = JSON.generate(body)
        end
      end
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

    # Follow same-origin redirects (e.g. repo rename or transfer) without
    # leaking authorization tokens to external hosts.
    def follow_redirect(response, current_path, current_params)
      location = response.headers['location'].to_s
      if Aireview::Utils.blank?(location)
        raise ApiError, "GitHub API redirected with status #{response.status} without a Location header"
      end

      current_url = URI.join(@base_uri.to_s, current_path)
      target = URI.join(current_url.to_s, location)
      unless same_origin?(target, @base_uri)
        raise ApiError, "Refusing redirect from #{@base_uri.host} to #{target.host}"
      end

      [target.to_s, target.query ? {} : current_params]
    end

    def same_origin?(target, base)
      target.scheme == base.scheme && target.host == base.host && target.port == base.port
    end

    # When an enormous review overflows GitHub's 65,536-char limit, findings
    # and summary stay intact; only the files list in the not-reviewed block
    # (or the summary if oversized) is shortened with a note. Never drops
    # findings or result: a corrupted review must not be saved to GitHub.
    def fit_comment_body(body, limit = MAX_COMMENT_LENGTH)
      return body if body.length <= limit

      fitted = truncate_not_reviewed(body, limit)
      return fitted if fitted && fitted.length <= limit

      fitted = truncate_summary(fitted || body, limit)
      return fitted if fitted && fitted.length <= limit

      raise ApiError, "Review comment exceeds GitHub limit of #{limit} characters " \
                      'and cannot be shortened without dropping findings'
    end

    def truncate_not_reviewed(body, limit)
      result_index = body.rindex(/\n## (?:Result|Результат)\n\n/)
      return nil unless result_index

      match = body[result_index..].match(/(\n## (?:Not reviewed|Не вошло в ревью)\n\n)(.*)/m)
      return nil unless match

      prefix = body[0...(result_index + match.begin(0))] + match[1]
      rest = match[2]
      is_ru = body.include?('Не вошло в ревью')
      items, footer = split_items_and_footer(rest)

      kept, omitted = fit_items(items, prefix: prefix, footer: footer, is_ru: is_ru, limit: limit)
      result_items = kept
      result_items << omission_note(omitted, is_ru) if omitted.positive?

      "#{prefix}#{result_items.join}#{footer}"
    end

    def truncate_summary(body, limit)
      summary_pattern = /(\n## (?:Summary|Сводка)\n\n)(.*?)(\n\n## )/m
      match = body.match(summary_pattern)
      return nil unless match

      prefix = body[0...match.begin(0)] + match[1]
      summary = match[2]
      suffix = match[3] + body[match.end(0)..]
      is_ru = body.include?('## Сводка')
      note = is_ru ? "\n[сводка усечена]" : "\n[summary truncated]"

      room = limit - prefix.length - suffix.length - note.length
      return nil if room <= 0

      "#{prefix}#{summary[0, room]}#{note}#{suffix}"
    end

    def split_items_and_footer(rest)
      items = []
      trailer = []
      in_items = true
      rest.lines.each do |line|
        if in_items && line.start_with?('- ')
          items << line
        else
          in_items = false
          trailer << line
        end
      end
      [items, trailer.join]
    end

    def fit_items(items, prefix:, footer:, is_ru:, limit:)
      kept = []
      kept_length = 0
      items.each_with_index do |line, index|
        remaining = items.size - (index + 1)
        omission = remaining.positive? ? omission_note(remaining, is_ru) : ''
        candidate_size = prefix.length + kept_length + line.length + omission.length + footer.length
        break if candidate_size > limit

        kept << line
        kept_length += line.length
      end
      [kept, items.size - kept.size]
    end

    def omission_note(count, is_ru)
      is_ru ? "- ... и ещё #{count} файлов не показано\n" : "- ... and #{count} more files not shown\n"
    end
  end
end
