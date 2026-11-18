# frozen_string_literal: true

module Aireview
  # Shortens rendered review comments to fit a platform character limit
  # without dropping findings or the overall result section.
  class ReviewCommentFormatter
    RESULT_HEADING = /\n## (?:Result|Результат)\n\n/
    NOT_REVIEWED_HEADING = /(\n## (?:Not reviewed|Не вошло в ревью)\n\n)(.*)/m
    SUMMARY_HEADING = /(?:\A|\n)## (?:Summary|Сводка)\n\n/

    def self.fit(body, limit:)
      new(limit: limit).fit(body)
    end

    def initialize(limit:)
      @limit = limit
    end

    def fit(body)
      return body if body.length <= @limit

      fitted = truncate_not_reviewed(body)
      return fitted if fitted && fitted.length <= @limit

      fitted = truncate_summary(fitted || body)
      return fitted if fitted && fitted.length <= @limit

      nil
    end

    private

    def truncate_not_reviewed(body)
      result_index = body.rindex(RESULT_HEADING)
      return nil unless result_index

      match = body[result_index..].match(NOT_REVIEWED_HEADING)
      return nil unless match

      prefix = body[0...(result_index + match.begin(0))] + match[1]
      is_ru = body.include?('Не вошло в ревью')
      items, footer = split_items_and_footer(match[2])

      kept, omitted = fit_items(items, prefix: prefix, footer: footer, is_ru: is_ru)
      result_items = kept
      result_items << omission_note(omitted, is_ru) if omitted.positive?

      "#{prefix}#{result_items.join}#{footer}"
    end

    def truncate_summary(body)
      prefix, summary, suffix = split_summary_section(body)
      return nil unless prefix

      is_ru = body.include?('## Сводка')
      note = is_ru ? "\n[сводка усечена]" : "\n[summary truncated]"

      room = @limit - prefix.length - suffix.length - note.length
      return nil if room.negative?

      truncated = truncate_with_closed_fence(summary, room)

      "#{prefix}#{truncated}#{note}#{suffix}"
    end

    def split_summary_section(body)
      match = body.match(SUMMARY_HEADING)
      return nil unless match

      prefix = body[0...match.end(0)]
      rest = body[match.end(0)..]
      boundary = find_next_heading_offset(rest)
      return nil unless boundary

      [prefix, rest[0...(boundary - 2)], rest[(boundary - 2)..]]
    end

    def find_next_heading_offset(rest)
      fence = nil
      prev_blank = false
      offset = 0
      rest.each_line do |line|
        return offset if fence.nil? && prev_blank && line.start_with?('## ')

        fence = next_fence_state(line, fence)
        prev_blank = (line == "\n")
        offset += line.length
      end
      nil
    end

    def truncate_with_closed_fence(summary, room)
      loop do
        truncated = summary[0, room]
        fence = open_fence(truncated)
        return truncated unless fence

        closing = "\n#{fence}"
        return '' if room < closing.length

        candidate = summary[0, room - closing.length]
        return "#{candidate}#{closing}" if open_fence(candidate) == fence

        room -= closing.length
      end
    end

    def open_fence(text)
      fence = nil
      text.each_line { |line| fence = next_fence_state(line, fence) }
      fence
    end

    def next_fence_state(line, fence)
      if fence.nil?
        match = line.match(/^ {0,3}(`{3,}|~{3,})/)
        return match[1] if match
      elsif line.match?(/^ {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*\r?\n?\z/)
        return nil
      end
      fence
    end

    def split_items_and_footer(rest)
      items = []
      trailer = []
      in_items = true
      rest.lines.each do |line|
        if in_items && line.start_with?('- ')
          items << line
        else
          in_items = false
          trailer << line
        end
      end
      [items, trailer.join]
    end

    def fit_items(items, prefix:, footer:, is_ru:)
      kept = []
      kept_length = 0
      items.each_with_index do |line, index|
        remaining = items.size - (index + 1)
        omission = remaining.positive? ? omission_note(remaining, is_ru) : ''
        candidate_size = prefix.length + kept_length + line.length + omission.length + footer.length
        break if candidate_size > @limit

        kept << line
        kept_length += line.length
      end
      [kept, items.size - kept.size]
    end

    def omission_note(count, is_ru)
      is_ru ? "- ... и ещё #{count} файлов не показано\n" : "- ... and #{count} more files not shown\n"
    end
  end
end
