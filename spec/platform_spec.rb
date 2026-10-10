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
  end

  it 'rejects an unknown platform' do
    target = gitlab_target.dup.tap { |result| result.platform = :bitbucket }

    expect { described_class.label(target) }.to raise_error(ArgumentError, /bitbucket/)
  end
end
