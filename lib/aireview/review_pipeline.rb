# frozen_string_literal: true
require 'json'
require_relative 'errors'
require_relative 'context_builder'
require_relative 'review_renderer'
require_relative 'review_schemas'
require_relative 'reviewer'

module Aireview
  class ReviewPipeline
    class SchemaError < StandardError
    end

    REPAIR_SYSTEM_PROMPT = <<~PROMPT.strip.freeze
      You fix invalid JSON produced by another LLM call.
      Return only valid JSON matching the requested schema.
      Do not use markdown, code fences, comments, or text outside JSON.
      Do not add new review findings.
    PROMPT
    DRY_RUN_CANDIDATES_JSON = '[{"id":"C1","file":"path/from/diff.rb","line":1,' \
                              '"quoted_code":"...","problem":"...","why":"...","suggestion":"...",' \
                              '"category":"bug","severity":"major"}]'

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

      ReviewRenderer.new.render(accepted, summary: summary)
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
                            candidates_json: DRY_RUN_CANDIDATES_JSON
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
    rescue JSON::ParserError, SchemaError => e
      @logger.warn("Invalid #{kind} JSON, requesting one repair: #{e.message}")
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
      parsed = {'summary' => nil, 'candidates' => parsed} if parsed.is_a?(Array)
      validate_generate_result_shape!(parsed)
      parsed['summary'] = nil unless parsed.key?('summary')
      candidate_ids = parsed['candidates'].map { |candidate| normalize_id(value(candidate, 'id')) }
      validate_identifiers!(
        candidate_ids,
        missing_message: 'each generate candidate must include a non-empty id',
        duplicate_prefix: 'duplicate generate candidate ids'
      )

      parsed
    end

    def normalize_critique_result(parsed, critique_candidate_ids:)
      validate_critique_result_shape!(parsed)
      verdicts = parsed['verdicts']
      verdict_ids = verdicts.map { |verdict| normalize_id(value(verdict, 'id')) }
      validate_identifiers!(
        verdict_ids,
        missing_message: 'each verdict must include a non-empty id',
        duplicate_prefix: 'duplicate verdict ids'
      )
      validate_expected_verdict_ids!(verdict_ids, critique_candidate_ids)
      verdicts.each { |verdict| validate_verdict!(verdict) }

      parsed
    end

    def validate_generate_result_shape!(parsed)
      return if parsed.is_a?(Hash) && parsed['candidates'].is_a?(Array)

      raise SchemaError, 'expected an object with summary and candidates array'
    end

    def validate_critique_result_shape!(parsed)
      return if parsed.is_a?(Hash) && parsed['verdicts'].is_a?(Array)

      raise SchemaError, 'expected an object with verdicts array'
    end

    def validate_identifiers!(identifiers, missing_message:, duplicate_prefix:)
      raise SchemaError, missing_message unless identifiers.all?

      duplicate_ids = identifiers.group_by(&:itself).select { |_, ids| ids.size > 1 }.keys
      return if duplicate_ids.empty?

      raise SchemaError, "#{duplicate_prefix}: #{duplicate_ids.join(', ')}"
    end

    def validate_expected_verdict_ids!(verdict_ids, expected_ids)
      return unless expected_ids

      unknown_ids = verdict_ids - expected_ids
      missing_ids = expected_ids - verdict_ids
      raise SchemaError, "unknown verdict ids: #{unknown_ids.join(', ')}" unless unknown_ids.empty?
      raise SchemaError, "missing verdict ids: #{missing_ids.join(', ')}" unless missing_ids.empty?
    end

    def validate_verdict!(verdict)
      id = normalize_id(value(verdict, 'id'))
      decision = normalize_decision(value(verdict, 'decision'))
      raise SchemaError, "invalid verdict decision for #{id}" unless %w[keep reject].include?(decision)

      refinement = value(verdict, 'refinement')
      raise SchemaError, "reject verdict cannot include refinement for #{id}" if invalid_refinement?(verdict, decision)
      return if refinement.nil?
      return if refinement.is_a?(Hash)

      raise SchemaError, "refinement must be an object for #{id}"
    end

    def invalid_refinement?(verdict, decision)
      refinement_key?(verdict) && decision != 'keep'
    end

    def repair_json(raw:, kind:, expected:, stage:, critique_candidate_ids: nil)
      schema = expected == :critique ? ReviewSchemas.critique : ReviewSchemas.generate
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

    def presence(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
