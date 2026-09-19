# frozen_string_literal: true

require 'stringio'
require 'aireview'

RSpec.describe Aireview::CLI do
  describe 'models check' do
    it 'loads the config and returns the checker exit code' do
      config = instance_double('Aireview::Config', warnings: [])
      checker = instance_double('Aireview::ModelChecker', run: 1)
      allow(Aireview::Config).to receive(:load).and_return(config)
      allow(Aireview::ModelChecker).to receive(:new).and_return(checker)
      out = StringIO.new

      status = described_class.start(%w[models check --config custom.yml --strict], out: out, err: StringIO.new, env: {})

      expect(status).to eq(1)
      expect(Aireview::Config).to have_received(:load).with(hash_including(config_path: 'custom.yml'))
      expect(Aireview::ModelChecker).to have_received(:new).with(hash_including(config: config, out: out, strict: true))
      expect(checker).to have_received(:run)
    end

    it 'rejects anything but check' do
      error_output = StringIO.new
      expect(Aireview::Config).not_to receive(:load)

      status = described_class.start(%w[models list], out: StringIO.new, err: error_output, env: {})

      expect(status).to eq(1)
      expect(error_output.string).to include('Usage: aireview models check [options] (got: list)')
    end
  end

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
