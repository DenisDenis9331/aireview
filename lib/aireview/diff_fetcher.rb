# frozen_string_literal: true
require_relative 'utils'

module Aireview
  class DiffFetcher
    NO_TEXT_CHANGES = '[no text changes]'
    DIFF_UNAVAILABLE = '[diff not available]'
    BINARY_DIFF = /\ABinary files .* differ/

    # Один файл из ответа GitLab: заголовок, хунки и что с ним можно делать.
    # kind:
    #   :text            есть хунки, код можно проверить;
    #   :no_text_changes переименование, смена режима, пустой файл: проверять
    #                    нечего;
    #   :unavailable     GitLab не отдал дифф (too_large) или файл бинарный:
    #                    код есть, но проверить его не удалось.
    class Entry
      attr_reader :path, :kind, :header, :hunks

      def initialize(change)
        old_path = change['old_path'] || change['new_path']
        new_path = change['new_path'] || change['old_path']
        @path = new_path
        @header = "diff --git a/#{old_path} b/#{new_path}\n--- a/#{old_path}\n+++ b/#{new_path}\n"
        diff = change['diff'].to_s
        @kind = classify(change, diff)
        @hunks = @kind == :text ? split_hunks(diff) : []
      end

      def text?
        kind == :text
      end

      def unavailable?
        kind == :unavailable
      end

      def body
        case kind
        when :text then hunks.join
        when :no_text_changes then "#{NO_TEXT_CHANGES}\n"
        else "#{DIFF_UNAVAILABLE}\n"
        end
      end

      def render
        header + body
      end

      private

      def classify(change, diff)
        return :unavailable if change['too_large']
        return :unavailable if diff.match?(BINARY_DIFF)
        return :no_text_changes if diff.strip.empty?

        :text
      end

      # Хунки режем по заголовкам @@; текст до первого @@ (или дифф без них,
      # например заглушка про секретный файл) считается одним хунком.
      def split_hunks(diff)
        diff = "#{diff}\n" unless diff.end_with?("\n")
        pieces = diff.split(/^(?=@@ )/)
        return pieces if pieces.size <= 1 || pieces.first.start_with?('@@ ')

        [pieces[0] + pieces[1], *pieces[2..]]
      end
    end

    def initialize(ignore_paths:, logger: Logger.new($stderr))
      @ignore_paths = Array(ignore_paths).compact
      @logger = logger
    end

    def filter(changes)
      Array(changes).reject do |change|
        ignored_path?(change['new_path']) || ignored_path?(change['old_path'])
      end
    end

    def entries(changes)
      Array(changes).map { |change| Entry.new(change) }
    end

    def render(changes)
      entries(changes).map(&:render).join("\n")
    end

    private

    def ignored_path?(path)
      return false if Aireview::Utils.blank?(path)

      @ignore_paths.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
      end
    end
  end
end
