# frozen_string_literal: true

require 'aireview'

RSpec.describe Aireview::Platform do
  let(:gitlab_target) { Aireview::MrParser.parse('https://gitlab.example.com/group/project/-/merge_requests/5') }
  let(:ci_env) { {'CI_PROJECT_ID' => '42', 'CI_JOB_ID' => '200'} }

  describe '.client' do
    it 'builds a GitLab client from the MR host when gitlab_url is not set' do
      config = instance_double(Aireview::Config, gitlab_url: nil, require_gitlab_token!: 'token')
      expect(Aireview::GitlabClient).to receive(:new)
        .with(base_url: 'https://gitlab.example.com', token: 'token', logger: anything)

      described_class.client(config: config, target: gitlab_target, logger: Logger.new(File::NULL))
    end
  end

  describe '.retried_run?' do
    it 'asks GitLab about the CI job' do
      client = double('client')
      expect(client).to receive(:retried_job?).with('42', '200').and_return(true)

      expect(described_class.retried_run?(client: client, target: gitlab_target, env: ci_env)).to be(true)
    end

    it 'is false outside GitLab CI without asking' do
      client = double('client')
      expect(client).not_to receive(:retried_job?)

      expect(described_class.retried_run?(client: client, target: gitlab_target, env: {})).to be(false)
    end
  end

  describe '.update_hint' do
    it 'suggests a retry in GitLab CI and --force elsewhere' do
      expect(described_class.update_hint(target: gitlab_target, env: ci_env)).to eq('retry the job to update')
      expect(described_class.update_hint(target: gitlab_target, env: {})).to eq('use --force to review again')
    end
  end

  it 'names the target for messages' do
    expect(described_class.label(gitlab_target)).to eq('MR group/project!5')
    expect(described_class.name(gitlab_target)).to eq('GitLab')
    expect(described_class.noun(gitlab_target)).to eq('merge request')
  end

  context 'with a GitHub pull request' do
    let(:github_target) { Aireview::MrParser.parse('https://github.com/owner/repo/pull/42') }

    it 'builds a GitHub client for api.github.com with the review author from the config' do
      config = instance_double(Aireview::Config, github_api_url: nil, require_github_token!: 'token',
                                                 github_review_author: 'my-app[bot]')
      expect(Aireview::GithubClient).to receive(:new).with(
        api_url: 'https://api.github.com', token: 'token', review_author: 'my-app[bot]', logger: anything
      )

      described_class.client(config: config, target: github_target, logger: Logger.new(File::NULL))
    end

    it 'prefers GITHUB_API_URL' do
      config = instance_double(Aireview::Config, github_api_url: 'https://ghe.example.com/api/v3',
                                                 require_github_token!: 'token', github_review_author: nil)
      expect(Aireview::GithubClient).to receive(:new).with(hash_including(api_url: 'https://ghe.example.com/api/v3'))

      described_class.client(config: config, target: github_target, logger: Logger.new(File::NULL))
    end

    it 'treats a later attempt of the workflow run as a retry, without API calls' do
      client = double('client')
      actions = {'GITHUB_ACTIONS' => 'true'}

      expect(described_class.retried_run?(client: client, target: github_target,
                                          env: actions.merge('GITHUB_RUN_ATTEMPT' => '2'))).to be(true)
      expect(described_class.retried_run?(client: client, target: github_target,
                                          env: actions.merge('GITHUB_RUN_ATTEMPT' => '1'))).to be(false)
      expect(described_class.retried_run?(client: client, target: github_target,
                                          env: {'GITHUB_RUN_ATTEMPT' => '2'})).to be(false)
    end

    it 'suggests a re-run in Actions and --force elsewhere' do
      expect(described_class.update_hint(target: github_target, env: {'GITHUB_ACTIONS' => 'true'}))
        .to eq('re-run the workflow to update')
      expect(described_class.update_hint(target: github_target, env: {})).to eq('use --force to review again')
    end

    it 'names the target for messages' do
      expect(described_class.label(github_target)).to eq('PR owner/repo#42')
      expect(described_class.name(github_target)).to eq('GitHub')
      expect(described_class.noun(github_target)).to eq('pull request')
    end
  end

  it 'rejects an unknown platform' do
    target = gitlab_target.dup.tap { |result| result.platform = :bitbucket }

    expect { described_class.label(target) }.to raise_error(ArgumentError, /bitbucket/)
  end
end
