# frozen_string_literal: true

module Aireview
  class ReviewRenderer
    MISMATCH_LIMIT = 2
    IMPORTANT_LIMIT = 3
    TOTAL_FINDINGS_LIMIT = 3
    IMPORTANT_CATEGORIES = %w[
      bug
      regression
      security
      performance
      data_loss
      edge_case
    ].freeze

    SEVERITY_ORDER = {
      'critical' => 0,
      'major' => 1,
      'minor' => 2
    }.freeze

    def render(accepted, summary:)
      findings = sorted_findings(Array(accepted)).first(TOTAL_FINDINGS_LIMIT)
      mismatches = findings.select { |finding| category(finding) == 'task_mismatch' }.first(MISMATCH_LIMIT)
      important = findings.select { |finding| important_finding?(finding) }.first(IMPORTANT_LIMIT)
      result = mismatches.empty? && important.empty? ? 'ok' : 'needs attention'

      <<~MARKDOWN.rstrip
        ## Сводка

        #{summary_text(summary)}

        ## Несоответствия

        #{render_findings(mismatches)}

        ## Важные замечания

        #{render_findings(important)}

        ## Результат

        #{result}

        Отчёт сгенерирован ИИ и может содержать ошибки. Проверьте замечания вручную перед принятием решений.
      MARKDOWN
    end

    private

    def sorted_findings(findings)
      findings
        .grep(Hash)
        .sort_by { |finding| [SEVERITY_ORDER.fetch(severity(finding), 99), value(finding, 'id').to_s] }
    end

    def important_finding?(finding)
      return false if category(finding) == 'task_mismatch'
      return false if severity(finding) == 'minor'

      IMPORTANT_CATEGORIES.include?(category(finding))
    end

    def summary_text(summary)
      presence(summary) || 'Сводка изменений не была возвращена на первом проходе.'
    end

    def render_findings(findings)
      return 'Не найдено.' if findings.empty?

      findings.map do |finding|
        <<~ITEM.rstrip
          - **Где**: #{location(finding)}
          - **Проблема**: #{presence(value(finding, 'problem')) || 'Не указано.'}
          - **Почему важно**: #{presence(value(finding, 'why')) || 'Не указано.'}
          - **Предложение**: #{presence(value(finding, 'suggestion')) || 'Не указано.'}
        ITEM
      end.join("\n\n")
    end

    def location(finding)
      file = presence(value(finding, 'file'))
      line = value(finding, 'line')
      return 'Не указано.' unless file
      return file if line.nil? || line.to_s.empty?

      "#{file}:#{line}"
    end

    def value(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def category(finding)
      value(finding, 'category').to_s.downcase
    end

    def severity(finding)
      value(finding, 'severity').to_s.downcase
    end

    def presence(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
