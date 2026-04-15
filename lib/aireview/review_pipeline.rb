require 'json'
require_relative 'errors'
require_relative 'context_builder'
require_relative 'reviewer'

module Aireview
  class ReviewPipeline
    SchemaError = Class.new(StandardError)

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

    REPAIR_SYSTEM_PROMPT = <<~PROMPT.strip.freeze
      You fix invalid JSON produced by another LLM call.
      Return only valid JSON matching the requested schema.
      Do not use markdown, code fences, comments, or text outside JSON.
      Do not add new review findings.
    PROMPT

    def initialize(config:, reviewer: nil, context_builder: nil, logger: Logger.new($stderr))
      @config = config
      @reviewer = reviewer || Reviewer.new(config: config, logger: logger)
      @context_builder = context_builder || ContextBuilder.new(config: config, logger: logger)
      @logger = logger
    end

    def run(merge_request:, changes_text:, jira_issue: nil, critique: true)
      generate_prompt = @context_builder.build_generate_prompt(
        merge_request: merge_request,
        changes_text: changes_text,
        jira_issue: jira_issue
      )
      @logger.info("Pipeline generate pass started (model=#{@config.generate_model})")
      candidates_raw = @reviewer.generate(**generate_prompt)
      generate_result = parse_with_repair(
        raw: candidates_raw,
        kind: 'generate result',
        expected: :generate,
        repair_stage: :generate
      )
      summary = generate_result['summary']
      candidates = Array(generate_result['candidates'])
      @logger.info("Pipeline generate pass completed with #{candidates.size} candidate(s)")

      accepted = if critique
                   @logger.info("Pipeline critique pass started (model=#{@config.critique_model})")
                   critique_candidates(
                     merge_request: merge_request,
                     changes_text: changes_text,
                     jira_issue: jira_issue,
                     candidates: candidates
                   )
                 else
                   @logger.info('Pipeline critique pass skipped')
                   candidates
                 end

      @logger.info("Pipeline finished with #{accepted.size} accepted finding(s)")

      render_markdown(accepted, summary: summary)
    end

    def dry_run_prompts(merge_request:, changes_text:, jira_issue: nil, critique: true)
      @config.require_models!

      generate_prompt = @context_builder.build_generate_prompt(
        merge_request: merge_request,
        changes_text: changes_text,
        jira_issue: jira_issue
      )

      critique_prompt = if critique
                          @context_builder.build_critique_prompt(
                            merge_request: merge_request,
                            changes_text: changes_text,
                            jira_issue: jira_issue,
                            candidates_json: '[{"id":"C1","file":"path/from/diff.rb","line":1,"quoted_code":"...","problem":"...","why":"...","suggestion":"...","category":"bug","severity":"major"}]'
                          )
                        end

      {
        generate_prompt: generate_prompt,
        critique_prompt: critique_prompt,
        generate_model: @config.generate_model,
        generate_temperature: @config.generate_temperature,
        critique_model: @config.critique_model,
        critique_temperature: @config.critique_temperature
      }
    end

    private

    def critique_candidates(merge_request:, changes_text:, jira_issue:, candidates:)
      candidates_json = JSON.pretty_generate(candidates)
      candidates_by_id = index_candidates_by_id(candidates)
      critique_prompt = @context_builder.build_critique_prompt(
        merge_request: merge_request,
        changes_text: changes_text,
        jira_issue: jira_issue,
        candidates_json: candidates_json
      )
      critique_raw = @reviewer.critique(**critique_prompt)
      critique_result = parse_with_repair(
        raw: critique_raw,
        kind: 'critique result',
        expected: :critique,
        repair_stage: :critique,
        critique_candidate_ids: candidates_by_id.keys
      )
      verdicts = Array(critique_result['verdicts'])
      @logger.info("Pipeline critique pass completed with #{verdicts.size} verdict(s)")
      apply_critique_verdicts(
        verdicts: verdicts,
        candidates_by_id: candidates_by_id
      )
    end

    def parse_with_repair(raw:, kind:, expected:, repair_stage:, critique_candidate_ids: nil)
      parse_expected_json(raw, expected, critique_candidate_ids: critique_candidate_ids)
    rescue JSON::ParserError, SchemaError => first_error
      @logger.warn("Invalid #{kind} JSON, requesting one repair: #{first_error.message}")
      repaired = repair_json(
        raw: raw,
        kind: kind,
        expected: expected,
        stage: repair_stage,
        critique_candidate_ids: critique_candidate_ids
      )
      begin
        parse_expected_json(repaired, expected, critique_candidate_ids: critique_candidate_ids)
      rescue JSON::ParserError, SchemaError => second_error
        raise ParseError, "LLM returned invalid #{kind} JSON after repair: #{second_error.message}"
      end
    end

    def parse_expected_json(raw, expected, critique_candidate_ids: nil)
      parsed = JSON.parse(strip_code_fences(raw.to_s))

      case expected
      when :generate
        parsed = normalize_generate_result(parsed)
      when :critique
        parsed = normalize_critique_result(parsed, critique_candidate_ids: critique_candidate_ids)
      else
        raise ArgumentError, "Unknown expected JSON schema: #{expected.inspect}"
      end

      parsed
    end

    def strip_code_fences(text)
      stripped = text.to_s.strip
      return stripped unless stripped.start_with?('```')

      stripped
        .sub(/\A```[[:alnum:]_-]*[ \t]*\r?\n?/, '')
        .sub(/\r?\n?```[ \t]*\z/, '')
        .strip
    end

    def normalize_generate_result(parsed)
      parsed = { 'summary' => nil, 'candidates' => parsed } if parsed.is_a?(Array)

      unless parsed.is_a?(Hash) && parsed['candidates'].is_a?(Array)
        raise SchemaError, 'expected an object with summary and candidates array'
      end

      parsed['summary'] = nil unless parsed.key?('summary')
      candidate_ids = parsed['candidates'].map { |candidate| normalize_id(value(candidate, 'id')) }

      unless candidate_ids.all?
        raise SchemaError, 'each generate candidate must include a non-empty id'
      end

      duplicate_ids = candidate_ids.group_by(&:itself).select { |_, ids| ids.size > 1 }.keys
      raise SchemaError, "duplicate generate candidate ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?

      parsed
    end

    def normalize_critique_result(parsed, critique_candidate_ids:)
      unless parsed.is_a?(Hash) && parsed['verdicts'].is_a?(Array)
        raise SchemaError, 'expected an object with verdicts array'
      end

      verdicts = parsed['verdicts']
      verdict_ids = verdicts.map { |verdict| normalize_id(value(verdict, 'id')) }
      raise SchemaError, 'each verdict must include a non-empty id' unless verdict_ids.all?

      duplicate_ids = verdict_ids.group_by(&:itself).select { |_, ids| ids.size > 1 }.keys
      raise SchemaError, "duplicate verdict ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?

      if critique_candidate_ids
        unknown_ids = verdict_ids - critique_candidate_ids
        missing_ids = critique_candidate_ids - verdict_ids
        raise SchemaError, "unknown verdict ids: #{unknown_ids.join(', ')}" unless unknown_ids.empty?
        raise SchemaError, "missing verdict ids: #{missing_ids.join(', ')}" unless missing_ids.empty?
      end

      verdicts.each do |verdict|
        id = normalize_id(value(verdict, 'id'))
        decision = normalize_decision(value(verdict, 'decision'))
        raise SchemaError, "invalid verdict decision for #{id}" unless %w[keep reject].include?(decision)

        refinement = value(verdict, 'refinement')

        if refinement_key?(verdict) && decision != 'keep'
          raise SchemaError, "reject verdict cannot include refinement for #{id}"
        end

        next if refinement.nil?

        raise SchemaError, "refinement must be an object for #{id}" unless refinement.is_a?(Hash)
      end

      parsed
    end

    def repair_json(raw:, kind:, expected:, stage:, critique_candidate_ids: nil)
      schema = expected == :critique ? critique_schema_description : generate_schema_description
      user_prompt = <<~PROMPT
        The previous #{kind} response was invalid.

        Convert it into valid JSON matching this schema:
        #{schema}

        Do not add new findings. Do not remove findings unless they cannot be represented.
        Return only JSON.

        Invalid response:
        #{raw}
      PROMPT
      if stage == :critique && critique_candidate_ids
        user_prompt << "\nExpected candidate ids: #{critique_candidate_ids.join(', ')}\n"
      end

      @logger.info("Pipeline #{stage} repair started for #{kind}")
      if stage == :critique
        @reviewer.critique(system_prompt: REPAIR_SYSTEM_PROMPT, user_prompt: user_prompt)
      else
        @reviewer.generate(system_prompt: REPAIR_SYSTEM_PROMPT, user_prompt: user_prompt)
      end
    end

    def generate_schema_description
      <<~SCHEMA.strip
        {
          "summary": "1-2 предложения о сути изменений в MR",
          "candidates": [
            {
              "id": "C1",
              "file": "path/from/diff.rb",
              "line": 42,
              "quoted_code": "изменённый фрагмент кода",
              "problem": "текст замечания",
              "why": "почему это важно",
              "suggestion": "что исправить или проверить",
              "category": "bug",
              "severity": "major"
            }
          ]
        }
      SCHEMA
    end

    def critique_schema_description
      <<~SCHEMA.strip
        {
          "verdicts": [
            {
              "id": "C1",
              "decision": "keep",
              "reason": "почему замечание подтверждено",
              "refinement": {
                "problem": "уточнённый текст замечания",
                "why": "почему это действительно проблема",
                "suggestion": "что исправить или проверить",
                "category": "bug",
                "severity": "major"
              }
            },
            {
              "id": "C2",
              "decision": "reject",
              "reason": "почему замечание отклонено"
            }
          ]
        }
      SCHEMA
    end

    def index_candidates_by_id(candidates)
      candidates.each_with_object({}) do |candidate, result|
        next unless candidate.is_a?(Hash)

        result[normalize_id(value(candidate, 'id'))] = candidate
      end
    end

    def apply_critique_verdicts(verdicts:, candidates_by_id:)
      accepted = []

      verdicts.each do |verdict|
        id = normalize_id(value(verdict, 'id'))
        decision = normalize_decision(value(verdict, 'decision'))
        reason = presence(value(verdict, 'reason')) || 'No reason provided.'
        refinement = value(verdict, 'refinement')

        if decision == 'reject'
          @logger.info("Critique reject #{id}: #{reason}")
          next
        end

        candidate = candidates_by_id.fetch(id)
        merged = merge_candidate_refinement(candidate: candidate, refinement: refinement)
        @logger.debug("Critique keep #{id}#{refinement_delta(candidate, merged)}: #{reason}")
        accepted << merged
      end

      accepted
    end

    def merge_candidate_refinement(candidate:, refinement:)
      return candidate unless refinement.is_a?(Hash)

      merged = candidate.dup
      %w[problem why suggestion category severity].each do |key|
        next unless refinement.key?(key) || refinement.key?(key.to_sym)
        next unless (new_value = presence(value(refinement, key)))

        merged[key] = new_value
      end
      merged
    end

    def refinement_delta(original, refined)
      changes = []
      %w[category severity].each do |key|
        before = presence(value(original, key))
        after = presence(value(refined, key))
        next if before == after

        changes << "#{key} #{before || 'nil'}->#{after || 'nil'}"
      end
      return '' if changes.empty?

      " (#{changes.join(', ')})"
    end

    def render_markdown(accepted, summary:)
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

    def sorted_findings(findings)
      findings
        .select { |finding| finding.is_a?(Hash) }
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

    def normalize_id(value)
      presence(value)
    end

    def normalize_decision(value)
      value.to_s.strip.downcase
    end

    def refinement_key?(verdict)
      verdict.key?('refinement') || verdict.key?(:refinement)
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
