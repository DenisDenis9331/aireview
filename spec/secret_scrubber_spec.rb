require 'aireview/secret_scrubber'

RSpec.describe Aireview::SecretScrubber do
  describe '#scrub_text' do
    it 'scrubs builtin secret patterns' do
      scrubber = described_class.new(secret_patterns: [], secret_files: [], logger: Logger.new(nil))
      text = <<~TEXT
        api_key = "super-secret"
        SECRET_KEY = "another-secret"
        Authorization: Bearer token123
        Authorization:
        - Bearer sk-proj-fakefakefakefakefakefakefakefake
        Authorization:
        - Bearer long-bearer-token-value-1234567890
        openai = "sk-fakefakefakefakefakefakefakefake"
        gitlab = "glpat_fakefakefakefakefakefakefake"
        github = "ghp_fakefakefakefakefakefakefake"
        aws_secret_access_key = abcdefghijklmnopqrstuvwxyz123456
      TEXT

      result = scrubber.scrub_text(text)

      expect(result).not_to include('super-secret')
      expect(result).not_to include('another-secret')
      expect(result).not_to include('token123')
      expect(result).not_to include('sk-proj-fake')
      expect(result).not_to include('long-bearer-token-value')
      expect(result).not_to include('sk-fake')
      expect(result).not_to include('glpat_fake')
      expect(result).not_to include('ghp_fake')
      expect(result).not_to include('abcdefghijklmnopqrstuvwxyz123456')
      expect(result).to include('[REDACTED]')
    end
  end

  describe '#scrub_change' do
    it 'masks secret files' do
      scrubber = described_class.new(
        secret_patterns: [],
        secret_files: ['.env', 'config/credentials/*.key', 'spec/fixtures/cassettes/*.yml'],
        logger: Logger.new(nil)
      )

      result = scrubber.scrub_change('new_path' => '.env', 'diff' => '+TOKEN=abc')

      expect(result['diff']).to eq('[REDACTED: secret file .env]')

      result = scrubber.scrub_change(
        'new_path' => 'spec/fixtures/cassettes/openai_images.yml',
        'diff' => '+Authorization: Bearer secret'
      )

      expect(result['diff']).to eq('[REDACTED: secret file spec/fixtures/cassettes/openai_images.yml]')
    end
  end
end
