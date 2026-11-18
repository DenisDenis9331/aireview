# frozen_string_literal: true

require 'stringio'
require 'aireview'

# A GitHub client in the shapes GithubClient returns. The pull request can
# move between the read before the review and the one before publishing.
class FakeGithubClient
  attr_reader :created, :updated

  def initialize(pull_request:, changes:, comments: [], moved_to: nil, login: 'github-actions[bot]')
    @pull_request = pull_request
    @changes = changes
    @comments = comments
    @moved_to = moved_to
    @login = login
    @reads = 0
    @created = []
    @updated = []
  end

  def fetch_merge_request(_repo, _number)
    @reads += 1
    @reads == 1 || @moved_to.nil? ? @pull_request : @moved_to
  end

  def fetch_merge_request_changes(_repo, _number)
    @changes
  end

  def fetch_merge_request_notes(_repo, _number)
    @comments
  end

  def fetch_current_user
    {'id' => @login}
  end

  def post_merge_request_note(_repo, _number, body)
    @created << body
  end

  def update_merge_request_note(_repo, _number, comment_id, body)
    @updated << [comment_id, body]
  end
end

RSpec.describe 'aireview review for a GitHub pull request' do
  let(:url) { 'https://github.com/owner/repo/pull/7' }
  let(:pull_request) do
    {
      'title' => 'Add retries',
      'description' => nil,
      'author' => {'name' => 'dev-one'},
      'source_branch' => 'feature/retries',
      'target_branch' => 'main',
      'sha' => 'headsha',
      'diff_refs' => {'base_sha' => 'mergebase', 'head_sha' => 'headsha'},
      'changed_files' => 1
    }
  end
  let(:changes) do
    [{'old_path' => 'app.rb', 'new_path' => 'app.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"}]
  end
  let(:config) do
    Aireview::Config.new(
      {
        'github_token' => 'token',
        'github_review_author' => 'github-actions[bot]',
        'gemini_api_key' => 'key',
        'llm' => {
          'provider' => 'gemini',
          'generate' => {'model' => 'gemini-3.7-flash'},
          'critique' => {'model' => 'gemini-3.8-flash'}
        }
      },
      config_path: nil,
      logger: Logger.new(File::NULL)
    )
  end
  let(:prompts) do
    {
      generate_prompt: {system_prompt: 'system', user_prompt: 'user'},
      critique_prompt: {system_prompt: 'system', user_prompt: 'candidates'},
      generate_model: 'gemini-3.7-flash',
      generate_temperature: 0,
      critique_model: 'gemini-3.8-flash',
      critique_temperature: 0
    }
  end
  let(:pipeline) { instance_double(Aireview::ReviewPipeline, dry_run_prompts: prompts, run: 'review text') }
  let(:key) { Aireview::ReviewMarker.key(prompts: prompts, config: config) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def run_cli(client, *options, env: {})
    allow(Aireview::Config).to receive(:load).and_return(config)
    allow(Aireview::GithubClient).to receive(:new).and_return(client)
    allow(Aireview::ReviewPipeline).to receive(:new).and_return(pipeline)

    Aireview::CLI.start(['review', url, '--post', *options], out: out, err: err, env: env)
  end

  def comment(id, key)
    {'id' => id, 'body' => "#{Aireview::ReviewMarker.build(key)}\nold review", 'system' => false,
     'author' => {'id' => 'github-actions[bot]'}}
  end

  it 'builds the GitHub client from the config and posts the review' do
    client = FakeGithubClient.new(pull_request: pull_request, changes: changes)
    allow(Aireview::Config).to receive(:load).and_return(config)
    allow(Aireview::ReviewPipeline).to receive(:new).and_return(pipeline)
    expect(Aireview::GithubClient).to receive(:new).with(
      api_url: 'https://api.github.com', token: 'token', review_author: 'github-actions[bot]', logger: anything
    ).and_return(client)

    expect(Aireview::CLI.start(['review', url, '--post'], out: out, err: err, env: {})).to eq(0)
    expect(client.created).to eq(["#{Aireview::ReviewMarker.build(key)}\n**aireview review**\n\nreview text"])
    expect(err.string).to include('Loading PR owner/repo#7')
  end

  it 'requires GITHUB_TOKEN for a GitHub URL' do
    allow(config).to receive(:github_token).and_return(nil)
    allow(Aireview::Config).to receive(:load).and_return(config)

    expect(Aireview::CLI.start(['review', url, '--post'], out: out, err: err, env: {})).to eq(1)
    expect(err.string).to include('Error: GITHUB_TOKEN is required')
  end

  context 'with review_mode=once' do
    let(:actions) { {'GITHUB_ACTIONS' => 'true'} }
    let(:client) do
      FakeGithubClient.new(pull_request: pull_request, changes: changes, comments: [comment(3, '0000000000000000')])
    end

    before { allow(config).to receive(:review_mode).and_return('once') }

    it 'skips changed input on the first attempt of the workflow run' do
      expect(pipeline).not_to receive(:run)

      expect(run_cli(client, env: actions.merge('GITHUB_RUN_ATTEMPT' => '1'))).to eq(0)
      expect(client.updated).to be_empty
      expect(out.string).to include(
        'Review skipped: pull request already reviewed (review_mode=once), ' \
        'review inputs changed: re-run the workflow to update'
      )
    end

    it 'updates the review on a re-run of the workflow' do
      expect(run_cli(client, env: actions.merge('GITHUB_RUN_ATTEMPT' => '2'))).to eq(0)
      expect(client.updated).to eq([[3, "#{Aireview::ReviewMarker.build(key)}\n**aireview review**\n\nreview text"]])
    end
  end

  context 'when the pull request moves while the review runs' do
    # Part of the PR merged into the base branch: the head stays, the merge
    # base and with it the PR diff move.
    it 'skips publication when only the merge base moved' do
      moved = pull_request.merge('diff_refs' => {'base_sha' => 'newmergebase', 'head_sha' => 'headsha'})
      client = FakeGithubClient.new(pull_request: pull_request, changes: changes, moved_to: moved)

      expect(run_cli(client)).to eq(0)
      expect(client.created).to be_empty
      expect(err.string).to include('Pull request changed while review was running (diff_refs); skipping publication')
    end

    # An ordinary push to the base branch leaves the merge base and the PR
    # diff as they were: the review is still current.
    it 'publishes when the base branch moved but the merge base did not' do
      client = FakeGithubClient.new(pull_request: pull_request, changes: changes, moved_to: pull_request.dup)

      expect(run_cli(client)).to eq(0)
      expect(client.created.size).to eq(1)
    end
  end

  it 'reports the files GitHub did not return as not reviewed' do
    client = FakeGithubClient.new(pull_request: pull_request.merge('changed_files' => 3412), changes: changes)
    expect(pipeline).to receive(:run)
      .with(hash_including(merge_request: hash_including('files_not_returned' => 3411)))
      .and_return('review text')

    expect(run_cli(client)).to eq(0)
    expect(err.string).to include('Only 1 of 3412 changed files were returned; the rest is not reviewed')
  end

  # The returned files and so the prompts stay the same while the pull
  # request grows past what GitHub lists: the comment must gain the warning.
  context 'when files stop being returned' do
    let(:pipeline) do
      Aireview::ReviewPipeline.new(config: config, logger: Logger.new(File::NULL)).tap do |real|
        allow(real).to receive(:run).and_return('review text')
      end
    end

    def posted_review
      client = FakeGithubClient.new(pull_request: pull_request, changes: changes)
      run_cli(client)
      client.created.fetch(0)
    end

    def rerun(changed_files, body)
      previous = {'id' => 3, 'body' => body, 'system' => false, 'author' => {'id' => 'github-actions[bot]'}}
      FakeGithubClient.new(pull_request: pull_request.merge('changed_files' => changed_files),
                           changes: changes, comments: [previous]).tap { |client| run_cli(client) }
    end

    it 'keeps a complete review up to date while every file is returned' do
      client = rerun(1, posted_review)

      expect(client.updated).to be_empty
      expect(out.string).to include('Review skipped: existing review is up to date')
    end

    it 'updates the review once part of the files is not returned' do
      previous = posted_review
      client = rerun(3412, previous)

      expect(client.updated.size).to eq(1)
      expect(Aireview::ReviewMarker.extract(client.updated[0][1])).not_to eq(Aireview::ReviewMarker.extract(previous))
    end
  end
end
