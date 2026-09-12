# frozen_string_literal: true
require_relative 'errors'

module Aireview
  # Укладывает контекст ревью в бюджет символов и запоминает, что при этом не
  # вошло. Секции MR и Jira режутся до своих лимитов с сохранением начала,
  # дифф по целым файлам, затем по целым хункам; внутри хунка не режем.
  module ContextBudget
    # Пути, которые не вошли, перечисляются в конце диффа; список ограничен,
    # чтобы сам не съел бюджет.
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

    # Начало важнее конца: требования и критерии приёмки обычно там.
    def self.truncate_section(text, limit:, label:, coverage:)
      text = text.to_s
      return text if text.length <= limit

      coverage.truncated_sections << label
      "#{text[0, limit]}\n[#{label} truncated: #{limit} of #{text.length} chars shown]"
    end

    def self.pack_entries(entries, budget:, coverage:)
      Packer.new(entries, budget: budget, coverage: coverage).pack
    end

    # Файлы без хунков идут первыми: они дёшевы и всегда полезны для картины
    # MR. Текстовые файлы идут в порядке GitLab, пока влезают; первый файл,
    # который не влезает, показывается частично, всё после него не показывается.
    # Хунк, который не влез бы даже в пустой бюджет, пропускается с пометкой,
    # а не останавливает раскладку.
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

      # Что-то придётся опустить, значит нужен хвост со списком пропущенного.
      # @used считает весь собранный текст, включая разделители между
      # файлами: результат не должен выйти за бюджет ни на символ.
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

      # Место под следующий кусок с учётом разделителя перед ним.
      def remaining
        @limit - @used - (@parts.empty? ? 0 : 1)
      end

      # Возвращает [текст, число показанных хунков, остановлена ли раскладка].
      def pack_entry(entry)
        full = entry.render
        return [full, entry.hunks.size, false] if full.length <= remaining

        body, shown, skipped, stopped = pack_hunks(entry)
        return ['', 0, stopped] if shown.zero?

        skipped.each { |hunk| @coverage.hunks_skipped << {path: entry.path, hunk: hunk} }
        @coverage.files_partial << {path: entry.path, shown: shown, total: entry.hunks.size}
        [entry.header + body + partial_marker(entry, shown), shown, stopped]
      end

      # Каждый хунк и каждая пометка о пропуске проверяются на оставшееся
      # место вместе с заголовком файла и итоговой пометкой о частичности.
      # Слишком большой хунк раскладку не останавливает: он попадает в
      # покрытие, а пометка о нём попадает в текст, только если есть место.
      def pack_hunks(entry)
        base = entry.header.length + partial_marker(entry, 0).length
        body = +''
        shown = 0
        skipped = []
        entry.hunks.each_with_index do |hunk, index|
          if base + hunk.length > @limit
            skipped << (index + 1)
            marker = skip_marker(entry, index)
            body << marker if base + body.length + marker.length <= remaining
            next
          end
          return [body, shown, skipped, true] if base + body.length + hunk.length > remaining

          body << hunk
          shown += 1
        end
        [body, shown, skipped, false]
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
