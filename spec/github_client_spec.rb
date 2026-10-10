# frozen_string_literal: true

require 'faraday'
require 'json'
require 'aireview'

RSpec.describe Aireview::GithubClient do
  def client_for(stubs, review_author: nil)
    connection = Faraday.new do |builder|
      builder.request :json
      builder.adapter :test, stubs
    end

    described_class.new(
      api_url: 'https://api.github.com',
      token: 'token',
      review_author: review_author,
      logger: Logger.new(File::NULL),
      connection: connection
    )
  end

  def json(status, payload, headers = {})
    [status, {'Content-Type' => 'application/json'}.merge(headers), JSON.generate(payload)]
  end

  def next_link(path, page)
    {'Link' => "<https://api.github.com/#{path}?per_page=100&page=#{page}>; rel=\"next\", " \
               "<https://api.github.com/#{path}?per_page=100&page=9>; rel=\"last\""}
  end

  let(:pull) do
    {
      'title' => 'Add retries',
      'body' => nil,
      'user' => {'login' => 'dev-one'},
      'head' => {'ref' => 'feature/retries', 'sha' => 'headsha'},
      'base' => {'ref' => 'release/2.0', 'sha' => 'oldbasesha'},
      'changed_files' => 2
    }
  end

  describe '.api_url_for' do
    it 'uses api.github.com for github.com and /api/v3 for GitHub Enterprise' do
      expect(described_class.api_url_for('https://github.com')).to eq('https://api.github.com')
      expect(described_class.api_url_for('https://ghe.example.com')).to eq('https://ghe.example.com/api/v3')
    end
  end

  describe '#fetch_merge_request' do
    it 'returns the GitLab-shaped merge request with the merge base as diff_refs.base_sha' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('repos/owner/repo/pulls/7') { json(200, pull) }
      # Compared against the base branch, not base.sha: base.sha may be stale.
      stubs.get('repos/owner/repo/compare/release/2.0...headsha') do |env|
        expect(env.params['per_page']).to eq('1')
        json(200, 'merge_base_commit' => {'sha' => 'mergebase'})
      end

      expect(client_for(stubs).fetch_merge_request('owner/repo', 7)).to eq(
        'title' => 'Add retries',
        'description' => nil,
        'author' => {'name' => 'dev-one'},
        'source_branch' => 'feature/retries',
        'target_branch' => 'release/2.0',
        'sha' => 'headsha',
        'diff_refs' => {'base_sha' => 'mergebase', 'head_sha' => 'headsha'},
        'changed_files' => 2
      )
      stubs.verify_stubbed_calls
    end

    it 'escapes a base branch name except its slashes' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('repos/owner/repo/pulls/7') { json(200, pull.merge('base' => {'ref' => 'fix/a b#1'})) }
      stubs.get('repos/owner/repo/compare/fix/a%20b%231...headsha') do
        json(200, 'merge_base_commit' => {'sha' => 'mergebase'})
      end

      expect(client_for(stubs).fetch_merge_request('owner/repo', 7)['diff_refs']['base_sha']).to eq('mergebase')
    end

    it 'fails when GitHub returns no merge base' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('repos/owner/repo/pulls/7') { json(200, pull) }
      stubs.get('repos/owner/repo/compare/release/2.0...headsha') { json(200, {}) }

      expect { client_for(stubs).fetch_merge_request('owner/repo', 7) }
        .to raise_error(Aireview::ApiError, /merge base/)
    end

    it 'fails on an API error with the status' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('repos/owner/repo/pulls/7') { json(404, 'message' => 'Not Found') }

      expect { client_for(stubs).fetch_merge_request('owner/repo', 7) }
        .to raise_error(Aireview::ApiError, /GitHub API error 404/)
    end
  end

  describe '#fetch_merge_request_changes' do
    it 'maps files to GitLab change hashes, following the Link header' do
      path = 'repos/owner/repo/pulls/7/files'
      first = [
        {'filename' => 'lib/a.rb', 'status' => 'modified', 'changes' => 2, 'patch' => "@@ -1 +1 @@\n-a\n+b"},
        {'filename' => 'lib/new.rb', 'status' => 'added', 'changes' => 1, 'patch' => "@@ -0,0 +1 @@\n+x"},
        {'filename' => 'lib/old.rb', 'status' => 'removed', 'changes' => 1, 'patch' => "@@ -1 +0,0 @@\n-x"}
      ]
      second = [
        {'filename' => 'lib/moved.rb', 'previous_filename' => 'lib/was.rb', 'status' => 'renamed', 'changes' => 0},
        {'filename' => 'lib/edited.rb', 'previous_filename' => 'lib/e.rb', 'status' => 'renamed', 'changes' => 3,
         'patch' => "@@ -1 +1 @@\n-a\n+b"},
        {'filename' => 'logo.png', 'status' => 'modified', 'changes' => 0},
        {'filename' => 'empty.txt', 'status' => 'added', 'changes' => 0},
        {'filename' => 'huge.sql', 'status' => 'modified', 'changes' => 90_000}
      ]
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get(path) do |env|
        env.params['page'] == '2' ? json(200, second) : json(200, first, next_link(path, 2))
      end

      changes = client_for(stubs).fetch_merge_request_changes('owner/repo', 7)

      expect(changes.map { |change| change.values_at('old_path', 'new_path') }).to eq(
        [%w[lib/a.rb lib/a.rb], %w[lib/new.rb lib/new.rb], %w[lib/old.rb lib/old.rb], %w[lib/was.rb lib/moved.rb],
         %w[lib/e.rb lib/edited.rb], %w[logo.png logo.png], %w[empty.txt empty.txt], %w[huge.sql huge.sql]]
      )
      expect(changes[0]).to include('diff' => "@@ -1 +1 @@\n-a\n+b", 'too_large' => false)
      expect(changes[1]).to include('new_file' => true, 'deleted_file' => false)
      expect(changes[2]).to include('deleted_file' => true)
      expect(changes[3]).to include('renamed_file' => true, 'too_large' => false, 'diff' => '')
      expect(changes[4]).to include('renamed_file' => true, 'too_large' => false)
      # No patch: a binary, a diff too large, an empty file — never claimed reviewed.
      expect(changes[5..].map { |change| change['too_large'] }).to eq([true, true, true])
    end

    it 'turns the missing patches into unavailable diff entries' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('repos/owner/repo/pulls/7/files') do
        json(200, [{'filename' => 'logo.png', 'status' => 'modified', 'changes' => 0},
                   {'filename' => 'moved.rb', 'previous_filename' => 'was.rb', 'status' => 'renamed', 'changes' => 0}])
      end
      changes = client_for(stubs).fetch_merge_request_changes('owner/repo', 7)

      entries = Aireview::DiffFetcher.new(ignore_paths: []).entries(changes)
      expect(entries.map(&:kind)).to eq(%i[unavailable no_text_changes])
    end

    it 'fails instead of stopping silently past the page limit' do
      path = 'repos/owner/repo/pulls/7/files'
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get(path) { |env| json(200, [], next_link(path, env.params['page'].to_i + 1)) }

      expect { client_for(stubs).fetch_merge_request_changes('owner/repo', 7) }
        .to raise_error(Aireview::ApiError, /more than 10000 files/)
    end
  end

  describe '#fetch_merge_request_notes' do
    it 'returns every page newest first, with the login as the author id' do
      path = 'repos/owner/repo/issues/7/comments'
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get(path) do |env|
        if env.params['page'] == '2'
          json(200, [{'id' => 3, 'body' => 'third', 'user' => {'login' => 'github-actions[bot]'}}])
        else
          json(200, [{'id' => 1, 'body' => 'first', 'user' => {'login' => 'dev-one'}},
                     {'id' => 2, 'body' => 'second', 'user' => {'login' => 'dev-two'}}], next_link(path, 2))
        end
      end

      notes = client_for(stubs).fetch_merge_request_notes('owner/repo', 7)

      expect(notes.map { |note| note['id'] }).to eq([3, 2, 1])
      expect(notes.first).to eq(
        'id' => 3, 'body' => 'third', 'author' => {'id' => 'github-actions[bot]'}, 'system' => false
      )
    end
  end

  describe 'publishing' do
    it 'posts a PR comment and updates it by comment id without the PR number' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post('repos/owner/repo/issues/7/comments') do |env|
        expect(JSON.parse(env.body)).to eq('body' => 'review')
        expect(env.request_headers).to include(
          'Authorization' => 'Bearer token', 'X-GitHub-Api-Version' => '2022-11-28',
          'Accept' => 'application/vnd.github+json'
        )
        json(201, 'id' => 11)
      end
      stubs.patch('repos/owner/repo/issues/comments/11') do |env|
        expect(JSON.parse(env.body)).to eq('body' => 'updated')
        json(200, 'id' => 11)
      end
      client = client_for(stubs)

      client.post_merge_request_note('owner/repo', 7, 'review')
      client.update_merge_request_note('owner/repo', 7, 11, 'updated')
      stubs.verify_stubbed_calls
    end
  end

  describe '#fetch_current_user' do
    it 'uses the login of the token owner' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('user') { json(200, 'login' => 'dev-one', 'id' => 99) }

      expect(client_for(stubs).fetch_current_user).to eq('id' => 'dev-one')
    end

    it 'takes GITHUB_REVIEW_AUTHOR without asking /user' do
      stubs = Faraday::Adapter::Test::Stubs.new

      expect(client_for(stubs, review_author: 'my-app[bot]').fetch_current_user).to eq('id' => 'my-app[bot]')
    end

    # Inside Actions the token may belong to the workflow's own GitHub App:
    # guessing github-actions[bot] would miss the app's review and post a
    # duplicate, so a 403 without an explicit author is an error.
    it 'does not guess github-actions[bot] when /user is forbidden' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('user') { json(403, 'message' => 'Resource not accessible by integration') }

      expect { client_for(stubs).fetch_current_user }
        .to raise_error(Aireview::ApiError, /set GITHUB_REVIEW_AUTHOR.*Resource not accessible by integration/)
    end
  end
end
