require 'aireview/errors'
require 'aireview/mr_parser'

RSpec.describe Aireview::MrParser do
  describe '.parse' do
    it 'parses a gitlab merge request url' do
      result = described_class.parse('https://gitlab.company.com/team/project/-/merge_requests/123')

      expect(result.base_url).to eq('https://gitlab.company.com')
      expect(result.project_path).to eq('team/project')
      expect(result.project_id).to eq('team%2Fproject')
      expect(result.iid).to eq(123)
      expect(result.platform).to eq(:gitlab)
    end

    it 'parses a github pull request url into an owner/repo id of two path segments' do
      result = described_class.parse('https://github.com/Owner-1/my.repo_2/pull/42')

      expect(result.platform).to eq(:github)
      expect(result.base_url).to eq('https://github.com')
      expect(result.project_path).to eq('Owner-1/my.repo_2')
      expect(result.project_id).to eq('Owner-1/my.repo_2')
      expect(result.iid).to eq(42)
    end

    it 'accepts the pull request tabs, a trailing slash and GitHub Enterprise hosts' do
      %w[
        https://github.com/owner/repo/pull/42/files
        https://github.com/owner/repo/pull/42/commits
        https://github.com/owner/repo/pull/42/
      ].each do |url|
        expect(described_class.parse(url)).to have_attributes(platform: :github, project_id: 'owner/repo', iid: 42)
      end

      result = described_class.parse('https://ghe.example.com:8443/owner/repo/pull/3')
      expect(result).to have_attributes(platform: :github, base_url: 'https://ghe.example.com:8443', iid: 3)
    end

    it 'rejects github urls that are not a pull request or have invalid names' do
      %w[
        https://github.com/owner/repo/issues/42
        https://github.com/owner/repo/pull/abc
        https://github.com/group/sub/repo/pull/42
        https://github.com/own%20er/repo/pull/42
      ].each do |url|
        expect { described_class.parse(url) }.to raise_error(Aireview::ParseError, /Unsupported/), url
      end
    end

    it 'rejects an invalid url' do
      expect do
        described_class.parse('gitlab.company.com/team/project/-/merge_requests/123')
      end.to raise_error(Aireview::ParseError, /http/)
    end
  end
end
