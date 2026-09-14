# frozen_string_literal: true
require 'logger'
require 'set'

module Aireview
  # Механическая проверка привязки кандидата к коду по тому диффу, который
  # реально ушёл в модель: файл, строка, цитата. Проверяется привязка, а не
  # сам баг: ненайденная цитата — повод критику присмотреться, не
  # доказательство выдумки. Файл, которого нет среди изменений MR, — другое
  # дело: такого кандидата проверять нечем, он отбрасывается.
  class CandidateChecker
    HUNK_HEADER = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
    FILE_HEADER = %r{^diff --git a/(.+?) b/(.+)$}
    NOTE_QUOTE_NOT_FOUND = 'quoted_code not found in the diff shown to the model'
    NOTE_LINE_RESET = 'line was outside the shown hunks and has been reset to null'
    NOTE_NOT_VERIFIED = 'file shown partially or without a diff, location not verified'

    # Один файл из контекста: диапазоны строк нового файла по показанным
    # хункам и нормализованный текст каждого хунка для поиска цитаты —
    # отдельно новая сторона (контекст + добавленные строки) и старая
    # (контекст + удалённые), чтобы многострочная цитата из одной версии
    # файла находилась целиком. Хунки не склеиваются: между ними пропущенный
    # код, и цитата через границу хунка — не цитата.
    Section = Struct.new(:ranges, :hunks, :partial, keyword_init: true) do
      def include?(quote)
        hunks.any? { |hunk| hunk[:new_text].include?(quote) || hunk[:old_text].include?(quote) }
      end
    end

    def initialize(changes:, diff_text:, coverage:, logger: Logger.new($stderr))
      @mr_paths = changes.flat_map { |change| change.values_at('old_path', 'new_path') }.compact.to_set
      @coverage = coverage
      @logger = logger
      @sections = parse_sections(diff_text.to_s)
    end

    # Возвращает кандидатов с пометками: note для критика, quote_missing для
    # отчёта, line сброшена в null, если не подтвердилась. Кандидаты с файлом
    # не из MR отброшены.
    def check(candidates)
      candidates.filter_map do |candidate|
        id = value(candidate, 'id')
        path = resolve_path(value(candidate, 'file'))
        unless path
          @logger.warn("Candidate #{id} dropped: file #{value(candidate, 'file').inspect} is not in the merge request")
          next
        end

        annotate(candidate.dup, id: id, section: @sections[path])
      end
    end

    private

    def annotate(candidate, id:, section:)
      notes = []
      if section.nil? || section.partial
        @logger.debug("Candidate #{id}: file shown partially or not at all, location not verified")
        notes << NOTE_NOT_VERIFIED
      else
        notes << check_line(candidate, id, section)
        notes << check_quote(candidate, id, section)
      end
      notes.compact!
      set(candidate, 'note', notes.join('; ')) unless notes.empty?
      candidate
    end

    def check_line(candidate, id, section)
      line = value(candidate, 'line')
      return nil if line.nil?
      return nil if line.is_a?(Integer) && section.ranges.any? { |range| range.cover?(line) }

      @logger.warn("Candidate #{id}: line #{line} is outside the shown hunks, reset to null")
      set(candidate, 'line', nil)
      NOTE_LINE_RESET
    end

    def check_quote(candidate, id, section)
      quote = normalize_text(value(candidate, 'quoted_code'))
      return nil if quote.empty? || section.include?(quote)

      @logger.warn("Candidate #{id}: quoted_code not found in the diff shown to the model")
      set(candidate, 'quote_missing', true)
      NOTE_QUOTE_NOT_FOUND
    end

    # Дифф уже собран под бюджет: у показанного частично файла хунков может
    # не хватать, у файла без диффа хунков нет вовсе. Заголовки --- / +++
    # бывают только между заголовком файла и первым @@; внутри хунка строка
    # «+++ x» — это добавленный код «++ x».
    def parse_sections(diff_text)
      sections = {}
      section = nil
      hunk = nil
      diff_text.each_line do |line|
        if (header = line.match(FILE_HEADER))
          section = Section.new(ranges: [], hunks: [], partial: false)
          hunk = nil
          header.captures.map(&:strip).each { |path| sections[path] = section }
        elsif section && (hunk_header = line.match(HUNK_HEADER))
          hunk = start_hunk(section, hunk_header)
        elsif hunk
          add_line(hunk, line)
        end
      end
      mark_partial(sections)
      normalize_hunks(sections)
    end

    # Хунк без новых строк (удаление, @@ -1 +0,0 @@) диапазона не даёт:
    # строки 0 в новом файле нет.
    def start_hunk(section, header)
      start = header[1].to_i
      length = header[2] ? header[2].to_i : 1
      section.ranges << (start..(start + length - 1)) if length.positive?
      hunk = {new_text: +'', old_text: +''}
      section.hunks << hunk
      hunk
    end

    def add_line(hunk, line)
      if line.start_with?(' ')
        hunk[:new_text] << line[1..]
        hunk[:old_text] << line[1..]
      elsif line.start_with?('+')
        hunk[:new_text] << line[1..]
      elsif line.start_with?('-')
        hunk[:old_text] << line[1..]
      end
    end

    def normalize_hunks(sections)
      sections.each_value do |section|
        section.hunks.each { |hunk| hunk.transform_values! { |text| normalize_text(text) } }
      end
    end

    def mark_partial(sections)
      partial = @coverage.files_partial.map { |file| file[:path] } + @coverage.files_unavailable
      partial += @coverage.hunks_skipped.map { |skipped| skipped[:path] }
      partial.each { |path| sections[path]&.partial = true }
    end

    # Сначала точное совпадение: каталоги a/ и b/ бывают настоящими. Префикс
    # из заголовка диффа снимается только если точного пути в MR нет.
    def resolve_path(path)
      path = path.to_s.strip
      return path if @mr_paths.include?(path)

      stripped = path.sub(%r{\A(?:\./|[ab]/)}, '')
      stripped if @mr_paths.include?(stripped)
    end

    def normalize_text(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end

    def value(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def set(hash, key, new_value)
      hash[hash.key?(key.to_sym) ? key.to_sym : key] = new_value
    end
  end
end
