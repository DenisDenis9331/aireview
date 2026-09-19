# frozen_string_literal: true
require_relative 'errors'

module Aireview
  # Fits the review context into a character budget and remembers what was
  # left out. The MR and Jira sections are cut to their limits keeping the
  # beginning, the diff by whole files, then by whole hunks; a hunk is never
  # cut inside.
  module ContextBudget
    # The paths that did not fit are listed at the end of the diff; the list
    # is capped so that it does not eat the budget itself.
    NOT_SHOWN_LIST_LIMIT = 20
    TRAILER_RESERVE_CHARS = 400

    Coverage = Struct.new(
      :truncated_sections, :files_not_shown, :files_partial, :files_unavailable, :hunks_skipped,
      keyword_init: true
    ) do
      def self.empty
        new(truncated_sections: [], files_not_shown: [], files_partial: [], files_unavailable: [], hunks_skipped: [])
      end

      def complete?
        to_h.values.all?(&:empty?)
      end
    end

    Packed = Struct.new(:text, :shown_hunks, :total_hunks, keyword_init: true)

    # The beginning matters more than the end: requirements and acceptance
    # criteria usually live there.
    def self.truncate_section(text, limit:, label:, coverage:)
      text = text.to_s
      return text if text.length <= limit

      coverage.truncated_sections << label
      "#{text[0, limit]}\n[#{label} truncated: #{limit} of #{text.length} chars shown]"
    end

    def self.pack_entries(entries, budget:, coverage:)
      Packer.new(entries, budget: budget, coverage: coverage).pack
    end

    # Files without hunks go first: they are cheap and always useful for the
    # picture of the MR. Text files go in GitLab order while they fit; the
    # first file that does not fit is shown partially, everything after it is
    # not shown. A hunk that would not fit even into an empty budget is
    # skipped with a mark instead of stopping the layout.
    class Packer
      def initialize(entries, budget:, coverage:)
        @non_text, @text = entries.partition { |entry| !entry.text? }
        @budget = budget
        @coverage = coverage
        @total_hunks = @text.sum { |entry| entry.hunks.size }
      end

      def pack
        @non_text.each { |entry| @coverage.files_unavailable << entry.path if entry.unavailable? }
        full = (@non_text + @text).map(&:render).join("\n")
        return Packed.new(text: full, shown_hunks: @total_hunks, total_hunks: @total_hunks) if full.length <= @budget

        pack_within_limit
      end

      private

      # Something has to be left out, so a trailer listing the skipped paths
      # is needed. @used counts the whole assembled text, separators between
      # files included: the result must not exceed the budget by a character.
      def pack_within_limit
        @parts = @non_text.map(&:render)
        @used = joined_length(@parts)
        @limit = @budget - TRAILER_RESERVE_CHARS
        raise_no_room!(:non_text) if @used > @limit

        shown_hunks = pack_text_entries
        raise_no_room!(:hunks) if shown_hunks.zero? && @total_hunks.positive?

        @parts << not_shown_trailer unless @coverage.files_not_shown.empty?
        Packed.new(text: @parts.join("\n"), shown_hunks: shown_hunks, total_hunks: @total_hunks)
      end

      def pack_text_entries
        shown_hunks = 0
        stopped = false
        @text.each do |entry|
          piece, shown, stopped = stopped ? ['', 0, true] : pack_entry(entry)
          if shown.zero?
            @coverage.files_not_shown << entry.path
            next
          end

          @parts << piece
          @used = joined_length(@parts)
          shown_hunks += shown
        end
        shown_hunks
      end

      # Room for the next piece, the separator before it included.
      def remaining
        @limit - @used - (@parts.empty? ? 0 : 1)
      end

      # Returns [text, number of shown hunks, whether the layout stopped].
      def pack_entry(entry)
        full = entry.render
        return [full, entry.hunks.size, false] if full.length <= remaining

        body, shown, skipped, stopped = pack_hunks(entry)
        return ['', 0, stopped] if shown.zero?

        skipped.each { |hunk| @coverage.hunks_skipped << {path: entry.path, hunk: hunk} }
        @coverage.files_partial << {path: entry.path, shown: shown, total: entry.hunks.size}
        [entry.header + body + partial_marker(entry, shown), shown, stopped]
      end

      # Room goes first to the hunks that can be shown, and only the remainder
      # to the marks about oversized ones: otherwise the marks could push out
      # the only fitting hunk. The skip is recorded in the coverage whether
      # or not there is room for the mark.
      def pack_hunks(entry)
        base = entry.header.length + partial_marker(entry, 0).length
        shown = []
        skipped = []
        stopped = false
        used = 0
        entry.hunks.each_with_index do |hunk, index|
          if base + hunk.length > @limit
            skipped << index
            next
          end
          if base + used + hunk.length > remaining
            stopped = true
            break
          end

          shown << index
          used += hunk.length
        end

        body = render_hunks(entry, shown: shown, skipped: skipped, room: remaining - base - used)
        [body, shown.size, skipped.map { |index| index + 1 }, stopped]
      end

      def render_hunks(entry, shown:, skipped:, room:)
        marked = skipped.select do |index|
          marker = skip_marker(entry, index)
          next false if marker.length > room

          room -= marker.length
          true
        end
        entry.hunks.each_with_index.filter_map do |hunk, index|
          next hunk if shown.include?(index)

          skip_marker(entry, index) if marked.include?(index)
        end.join
      end

      def skip_marker(entry, index)
        "[hunk #{index + 1} of #{entry.hunks.size} skipped: larger than the context budget]\n"
      end

      def joined_length(parts)
        parts.sum(&:length) + [parts.size - 1, 0].max
      end

      def partial_marker(entry, shown)
        "[file #{entry.path}: #{shown} of #{entry.hunks.size} hunks shown]\n"
      end

      def not_shown_trailer
        paths = @coverage.files_not_shown
        listed = []
        paths.first(NOT_SHOWN_LIST_LIMIT).each do |path|
          break if listed.sum(&:length) + path.length > TRAILER_RESERVE_CHARS / 2

          listed << path
        end
        rest = paths.size - listed.size
        list = listed.join(', ')
        list += " and #{rest} more" if rest.positive?
        "[#{paths.size} file(s) not shown: #{list}]\n"
      end

      def raise_no_room!(reason)
        detail = if reason == :non_text
                   'the entries for files without text changes alone exceed it'
                 else
                   "not a single hunk fits after #{@used} chars of entries without text changes"
                 end
        raise ContextBudgetError,
              "Diff does not fit into the context budget of #{@budget} chars: #{detail}. " \
              'Raise llm.max_prompt_chars / context.max_diff_chars, or add paths to ignore_paths.'
      end
    end
  end
end
