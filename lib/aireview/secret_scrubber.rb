require_relative 'utils'

module Aireview
  class SecretScrubber
    REDACTED = '[REDACTED]'.freeze

    BUILTIN_RULES = [
      [/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m, REDACTED],
      [/\bAKIA[0-9A-Z]{16}\b/, REDACTED],
      [/\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b/, REDACTED],
      [/\b(?:gh[ps]|glpat)_[A-Za-z0-9_-]{20,}\b/, REDACTED],
      [/(Authorization:\s*Bearer\s+)[A-Za-z0-9._-]+/i, '\1[REDACTED]'],
      [/(Bearer\s+)[A-Za-z0-9._-]{20,}/i, '\1[REDACTED]'],
      [/(\baws_secret_access_key\b\s*[:=]\s*["']?)[A-Za-z0-9\/+=]{20,}(["']?)/i, '\1[REDACTED]\2'],
      [/(\b(?:api[_-]?key|token|secret|password|passwd|client_secret)\w*\s*[:=]\s*["']?)[^"'\s]+(["']?)/i, '\1[REDACTED]\2'],
      [/(x-api-key:\s*)[A-Za-z0-9._-]+/i, '\1[REDACTED]']
    ].freeze

    def initialize(secret_patterns:, secret_files:, logger: Logger.new($stderr))
      @logger = logger
      @secret_files = Array(secret_files).compact
      @custom_rules = compile_patterns(secret_patterns)
    end

    def scrub_changes(changes)
      Array(changes).map { |change| scrub_change(change) }
    end

    def scrub_change(change)
      path = change['new_path'] || change['old_path']
      scrubbed = change.dup

      scrubbed['diff'] =
        if secret_file?(path)
          "[REDACTED: secret file #{path}]"
        else
          scrub_text(change['diff'].to_s)
        end

      scrubbed
    end

    def scrub_text(text)
      (BUILTIN_RULES + @custom_rules).reduce(text.to_s) do |memo, (pattern, replacement)|
        memo.gsub(pattern, replacement)
      end
    end

    private

    def compile_patterns(patterns)
      Array(patterns).compact.filter_map do |pattern|
        [Regexp.new(pattern, Regexp::IGNORECASE), REDACTED]
      rescue RegexpError => e
        @logger.warn("Skipping invalid secret pattern #{pattern.inspect}: #{e.message}")
        nil
      end
    end

    def secret_file?(path)
      return false if Aireview::Utils.blank?(path)

      @secret_files.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
      end
    end
  end
end
