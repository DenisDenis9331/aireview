# frozen_string_literal: true

require 'stringio'
require 'aireview'

# Клиент GitLab, у которого merge request может «уехать» между двумя чтениями:
# первое отдаёт исходное состояние, последующие — то, что задано в moved_to.
class RecordingGitlabClient
  attr_reader :created, :updated

  def initialize(merge_request:, changes:, notes: [], moved_to: nil, user: {'id' => 7})
    @merge_request = merge_request
    @moved_to = moved_to
    @changes = changes
    @notes = notes
    @user = user
    @reads = 0
    @created = []
    @updated = []
  end

  def fetch_merge_request(_project_id, _iid)
    @reads += 1
    @reads == 1 || @moved_to.nil? ? @merge_request : @moved_to
  end

  def fetch_merge_request_changes(_project_id, _iid)
    @changes
  end

  def fetch_merge_request_notes(_project_id, _iid)
    @notes
  end

  def retried_job?(_project_id, _job_id)
    false
  end

  def fetch_current_user
    @user
  end

  def post_merge_request_note(_project_id, _iid, body)
    @created << body
  end

  def update_merge_request_note(_project_id, _iid, note_id, body)
    @updated << [note_id, body]
  end
end

RSpec.describe 'aireview review --post' do
  let(:merge_request) do
    {
      'iid' => 5,
      'sha' => 'headsha',
      'title' => 'Add timeouts',
      'description' => 'Требования: добавить таймауты',
      'target_branch' => 'master',
      'diff_refs' => {'base_sha' => 'basesha', 'head_sha' => 'headsha'}
    }
  end

  let(:changes) do
    [{'old_path' => 'app.rb', 'new_path' => 'app.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"}]
  end

  let(:config) do
    Aireview::Config.new(
      {
        'gitlab_token' => 'token',
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

  let(:pipeline) do
    instance_double(Aireview::ReviewPipeline, dry_run_prompts: prompts, run: 'review text')
  end

  def run_cli(client, *options, env: {})
    allow(Aireview::Config).to receive(:load).and_return(config)
    allow(Aireview::GitlabClient).to receive(:new).and_return(client)
    allow(Aireview::ReviewPipeline).to receive(:new).and_return(pipeline)

    Aireview::CLI.start(
      ['review', 'https://gitlab.example.com/group/project/-/merge_requests/5', '--post', *options],
      out: StringIO.new,
      err: StringIO.new,
      env: env
    )
  end

  it 'passes --no-fallbacks to the config so only the primary model and key are used' do
    client = RecordingGitlabClient.new(merge_request: merge_request, changes: changes)
    allow(Aireview::ReviewPipeline).to receive(:new) do |config:, **|
      expect(config.fallbacks_disabled?).to be(true)
      pipeline
    end

    expect(run_cli(client, '--no-fallbacks')).to eq(0)
  end

  it 'publishes the review when the merge request stays put' do
    client = RecordingGitlabClient.new(merge_request: merge_request, changes: changes)

    expect(run_cli(client)).to eq(0)
    expect(client.created.first).to include('review text')
  end

  it 'skips publication when a new commit arrives while the review runs' do
    client = RecordingGitlabClient.new(
      merge_request: merge_request,
      changes: changes,
      moved_to: merge_request.merge('sha' => 'newsha')
    )

    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
  end

  it 'skips publication when the requirements in the description change while the review runs' do
    client = RecordingGitlabClient.new(
      merge_request: merge_request,
      changes: changes,
      moved_to: merge_request.merge('description' => 'Требования: таймауты не нужны')
    )

    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
  end

  it 'skips publication when the title changes while the review runs' do
    client = RecordingGitlabClient.new(
      merge_request: merge_request,
      changes: changes,
      moved_to: merge_request.merge('title' => 'Drop timeouts')
    )

    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
  end

  it 'skips the LLM entirely when the existing review matches the current key' do
    key = Aireview::ReviewMarker.key(prompts: prompts, config: config)
    client = RecordingGitlabClient.new(
      merge_request: merge_request,
      changes: changes,
      notes: [{'id' => 3, 'system' => false, 'author' => {'id' => 7},
               'body' => Aireview::ReviewMarker.build(key)}]
    )

    expect(pipeline).not_to receive(:run)
    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
    expect(client.updated).to be_empty
  end

  it 'updates the existing note when the key changed' do
    client = RecordingGitlabClient.new(
      merge_request: merge_request,
      changes: changes,
      notes: [{'id' => 3, 'system' => false, 'author' => {'id' => 7},
               'body' => Aireview::ReviewMarker.build('0000000000000000')}]
    )

    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
    expect(client.updated.first[0]).to eq(3)
  end
  it 'updates a legacy review and adds its marker instead of creating another note' do
    client = RecordingGitlabClient.new(
      merge_request: merge_request, changes: changes,
      notes: [{'id' => 3, 'system' => false, 'author' => {'id' => 7},
               'body' => "#{Aireview::Publisher::PREFIX}\n\nold review"}]
    )
    expect(pipeline).to receive(:run).once.and_return('fresh review')

    expect(run_cli(client)).to eq(0)
    expect(client.created).to be_empty
    key = Aireview::ReviewMarker.key(prompts: prompts, config: config)
    expect(client.updated).to eq([[3, "#{Aireview::ReviewMarker.build(key)}\n**aireview review**\n\nfresh review"]])
  end

  context 'with review_mode=once' do
    let(:ci_env) { {'CI_PROJECT_ID' => '42', 'CI_JOB_ID' => '200'} }
    let(:previous_key) { '0000000000000000' }
    let(:moved_to) { nil }
    let(:notes) do
      [{'id' => 3, 'system' => false, 'author' => {'id' => 7},
        'body' => Aireview::ReviewMarker.build(previous_key)}]
    end
    let(:client) do
      RecordingGitlabClient.new(
        merge_request: merge_request, changes: changes, notes: notes, moved_to: moved_to
      )
    end

    before do
      allow(config).to receive(:review_mode).and_return('once')
    end

    it 'publishes the first review without looking up job history' do
      client = RecordingGitlabClient.new(merge_request: merge_request, changes: changes)
      expect(client).not_to receive(:retried_job?)
      expect(pipeline).to receive(:run).once.and_return('first review')

      expect(run_cli(client, env: ci_env)).to eq(0)
      expect(client.created.first).to include('first review')
    end

    it 'skips changed input on the first job attempt in a new pipeline' do
      expect(client).to receive(:retried_job?).with('42', '200').and_return(false)
      expect(pipeline).not_to receive(:run)

      expect(run_cli(client, env: ci_env)).to eq(0)
      expect(client.created).to be_empty
      expect(client.updated).to be_empty
    end

    it 'updates the existing review for changed input on a job retry' do
      expect(client).to receive(:retried_job?).with('42', '200').and_return(true)
      expect(pipeline).to receive(:run).once.and_return('fresh review')

      expect(run_cli(client, env: ci_env)).to eq(0)
      expect(client.created).to be_empty
      key = Aireview::ReviewMarker.key(prompts: prompts, config: config)
      expect(client.updated).to eq([[3, "#{Aireview::ReviewMarker.build(key)}\n**aireview review**\n\nfresh review"]])
    end

    context 'when the existing review has no marker' do
      let(:notes) do
        [{'id' => 3, 'system' => false, 'author' => {'id' => 7},
          'body' => "#{Aireview::Publisher::PREFIX}\n\nold review"}]
      end

      it 'counts the legacy review as existing on a new pipeline' do
        expect(client).to receive(:retried_job?).and_return(false)
        expect(pipeline).not_to receive(:run)

        expect(run_cli(client, env: ci_env)).to eq(0)
        expect(client.created).to be_empty
        expect(client.updated).to be_empty
      end

      it 'migrates the legacy review on retry' do
        expect(client).to receive(:retried_job?).and_return(true)
        expect(pipeline).to receive(:run).once.and_return('fresh review')

        expect(run_cli(client, env: ci_env)).to eq(0)
        expect(client.created).to be_empty
        key = Aireview::ReviewMarker.key(prompts: prompts, config: config)
        expect(client.updated).to eq([[3, "#{Aireview::ReviewMarker.build(key)}\n**aireview review**\n\nfresh review"]])
      end
    end

    context 'when the input has not changed' do
      let(:previous_key) { Aireview::ReviewMarker.key(prompts: prompts, config: config) }

      it 'skips the LLM and job history lookup even on a retry' do
        expect(client).not_to receive(:retried_job?)
        expect(pipeline).not_to receive(:run)

        expect(run_cli(client, env: ci_env)).to eq(0)
        expect(client.created).to be_empty
        expect(client.updated).to be_empty
      end

      it 'still permits an explicit force without looking up job history' do
        expect(client).not_to receive(:retried_job?)
        expect(pipeline).to receive(:run).once.and_return('forced review')

        expect(run_cli(client, '--force', env: ci_env)).to eq(0)
        expect(client.created).to be_empty
        expect(client.updated.first[1]).to include('forced review')
      end
    end

    [{}, {'CI_PROJECT_ID' => '42'}, {'CI_JOB_ID' => '200'}].each do |env|
      it "skips existing reviews with incomplete CI context #{env.inspect}" do
        expect(client).not_to receive(:retried_job?)
        expect(pipeline).not_to receive(:run)

        expect(run_cli(client, env: env)).to eq(0)
        expect(client.created).to be_empty
        expect(client.updated).to be_empty
      end
    end

    it 'fails without calling the LLM when retry detection fails' do
      expect(client).to receive(:retried_job?).and_raise(Aireview::ApiError, 'GitLab unavailable')
      expect(pipeline).not_to receive(:run)

      expect(run_cli(client, env: ci_env)).to eq(1)
      expect(client.created).to be_empty
      expect(client.updated).to be_empty
    end

    it 'allows update mode to override once without looking up job history' do
      expect(client).not_to receive(:retried_job?)
      expect(pipeline).to receive(:run).once.and_return('fresh review')

      expect(run_cli(client, '--review-mode', 'update', env: ci_env)).to eq(0)
      expect(client.created).to be_empty
      expect(client.updated.first[1]).to include('fresh review')
    end

    context 'when the MR changes again during the retry' do
      let(:moved_to) { merge_request.merge('description' => 'New requirements') }

      it 'keeps the previous review instead of publishing stale output' do
        expect(client).to receive(:retried_job?).and_return(true)
        expect(pipeline).to receive(:run).once.and_return('stale review')

        expect(run_cli(client, env: ci_env)).to eq(0)
        expect(client.created).to be_empty
        expect(client.updated).to be_empty
      end
    end
  end
end

RSpec.describe 'aireview review --dry-run' do
  let(:merge_request) do
    {
      'title' => 'Add timeouts',
      'description' => 'D' * 50,
      'source_branch' => 'feature',
      'target_branch' => 'main',
      'author' => {'name' => 'Denis'},
      'sha' => 'headsha'
    }
  end

  let(:changes) do
    [
      {'old_path' => 'app.rb', 'new_path' => 'app.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"},
      {'old_path' => 'big.rb', 'new_path' => 'big.rb', 'diff' => "@@ -1,3 +1,3 @@\n#{"+x\n" * 400}"},
      {'old_path' => 'old.rb', 'new_path' => 'moved.rb', 'diff' => '', 'renamed_file' => true}
    ]
  end

  let(:config) do
    Aireview::Config.new(
      {
        'gitlab_token' => 'token',
        'gemini_api_key' => 'key',
        'context' => {'max_diff_chars' => 700, 'max_mr_description_chars' => 20},
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

  it 'prints the context summary, coverage and prompts with truncation markers' do
    client = RecordingGitlabClient.new(merge_request: merge_request, changes: changes)
    allow(Aireview::Config).to receive(:load).and_return(config)
    allow(Aireview::GitlabClient).to receive(:new).and_return(client)
    out = StringIO.new

    status = Aireview::CLI.start(
      ['review', 'https://gitlab.example.com/group/project/-/merge_requests/5', '--dry-run', '--no-jira'],
      out: out,
      err: StringIO.new,
      env: {}
    )

    expect(status).to eq(0)
    expect(out.string).to include('=== CONTEXT ===')
    expect(out.string).to match(/Sections: \d+ chars, diff: \d+ chars \(budget 700, hunks 1\/2\)/)
    expect(out.string).to match(/Generate request: \d+ chars \(~\d+ tokens\) of max 400000, system prompt \d+/)
    expect(out.string).to match(/Critique request: \d+ chars/)
    expect(out.string).to include("Coverage: partial\n  truncated sections: MR description\n  files not shown: big.rb")
    expect(out.string).to include('[MR description truncated: 20 of 50 chars shown]')
    expect(out.string).to include("+++ b/moved.rb\n[no text changes]")
    expect(out.string).to include('[1 file(s) not shown: big.rb]')
    expect(out.string).to include('=== CRITIQUE USER PROMPT ===')
  end
end
