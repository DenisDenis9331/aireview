# frozen_string_literal: true

require 'stringio'
require 'aireview'

RSpec.describe Aireview::CLI do
  describe '.start' do
    it 'rejects an invalid URL before loading config' do
      error_output = StringIO.new

      expect(Aireview::Config).not_to receive(:load)

      status = described_class.start(
        ['review', 'gitlab.company.com/team/project/-/merge_requests/123'],
        out: StringIO.new,
        err: error_output
      )

      expect(status).to eq(1)
      expect(error_output.string).to include('Merge request URL must include http:// or https://')
    end
  end
end
