require_relative 'utils'

module Aireview
  class DiffFetcher
    DIFF_UNAVAILABLE = '[DIFF_NOT_AVAILABLE]'.freeze

    def initialize(ignore_paths:, logger: Logger.new($stderr))
      @ignore_paths = Array(ignore_paths).compact
      @logger = logger
    end

    def filter(changes)
      Array(changes).reject do |change|
        ignored_path?(change['new_path']) || ignored_path?(change['old_path'])
      end
    end

    def render(changes)
      Array(changes).map { |change| render_change(change) }.join("\n")
    end

    private

    def ignored_path?(path)
      return false if Aireview::Utils.blank?(path)

      @ignore_paths.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
      end
    end

    def render_change(change)
      old_path = change['old_path'] || change['new_path']
      new_path = change['new_path'] || change['old_path']
      diff = change['diff'].to_s
      diff = DIFF_UNAVAILABLE if diff.strip.empty?

      <<~DIFF
        diff --git a/#{old_path} b/#{new_path}
        --- a/#{old_path}
        +++ b/#{new_path}
        #{diff}
      DIFF
    end
  end
end
