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
    end

    it 'rejects an invalid url' do
      expect do
        described_class.parse('gitlab.company.com/team/project/-/merge_requests/123')
      end.to raise_error(Aireview::ParseError, /http/)
    end
  end
end
