# frozen_string_literal: true
require 'json'
require_relative 'errors'
require_relative 'stages'
require_relative 'context_builder'
require_relative 'candidate_checker'
require_relative 'result_parser'
require_relative 'review_renderer'
require_relative 'review_schemas'
require_relative 'reviewer'

module Aireview
  # Прогон ревью: контекст → generate → проверка привязки к диффу → critique
  # → отчёт. Негодный JSON чинится один раз той же моделью; если и починка
  # негодна, стадия перезапускается на другой модели с исходным запросом.
  class ReviewPipeline
    SchemaError = ResultParser::SchemaError

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
      @parser = ResultParser.new
      @reviewer = reviewer || Reviewer.new(config: config, logger: logger)
      @context_builder = context_builder || ContextBuilder.new(config: config, logger: logger)
      @logger = logger
    end

    def run(merge_request:, changes:, jira_issue: nil, critique: true)
      context = @context_builder.prepare(
        merge_request: merge_request,
        changes: changes,
        jira_issue: jira_issue,
        critique: critique
      )
      generate_prompt = @context_builder.build_generate_prompt(context)
      @logger.info("Pipeline generate pass started (model=#{@config.generate_model})")
      generate_result = run_stage('generate') do
        parse_with_repair(
          raw: @reviewer.generate(**generate_prompt),
          kind: 'generate result',
          expected: 'generate',
          repair_stage: 'generate'
        )
      end
      summary = generate_result['summary']
      candidates = Array(generate_result['candidates'])
      @logger.info("Pipeline generate pass completed with #{candidates.size} candidate(s) " \
                   "(model=#{@reviewer.answered_model('generate')})")
      candidates = check_candidates(context: context, changes: changes, candidates: candidates)

      accepted = critique ? maybe_critique(context: context, candidates: candidates) : skip_critique(candidates)

      @logger.info("Pipeline finished with #{accepted.size} accepted finding(s)")

      ReviewRenderer.new(language: @config.review_language).render(
        accepted,
        summary: summary,
        coverage: context.coverage,
        fallback_models: @reviewer.fallback_models,
        critique_weaker: critique && @reviewer.critique_weaker?
      )
    end

    def dry_run_prompts(merge_request:, changes:, jira_issue: nil, critique: true)
      @config.require_models!

      context = @context_builder.prepare(
        merge_request: merge_request,
        changes: changes,
        jira_issue: jira_issue,
        critique: critique
      )
      generate_prompt = @context_builder.build_generate_prompt(context)
      critique_prompt = if critique
                          @context_builder.build_critique_prompt(context, candidates_json: DRY_RUN_CANDIDATES_JSON)
                        end

      {
        generate_prompt: generate_prompt,
        critique_prompt: critique_prompt,
        generate_model: @config.generate_model,
        generate_temperature: @config.generate_temperature,
        critique_model: @config.critique_model,
        critique_temperature: @config.critique_temperature,
        generate_fallbacks: @config.fallback_names('generate'),
        critique_fallbacks: critique ? @config.fallback_names('critique') : [],
        sources: setting_sources(critique),
        config_paths: @config.layer_paths,
        warnings: @config.warnings,
        critique_rule: critique ? @config.routing.rule : nil,
        api_keys: @config.api_key_counts(critique ? STAGES : ['generate']),
        time_budget: @config.llm_time_budget,
        overloaded_quarantine: @config.overloaded_quarantine,
        coverage: context.coverage,
        sizes: context.sizes
      }
    end

    private

    # Откуда пришли модель, провайдер и фолбеки стадии — для --dry-run.
    def setting_sources(critique)
      (critique ? %w[generate critique] : %w[generate]).to_h do |stage|
        [stage.to_sym, {
          model: @config.stage_model_source(stage),
          provider: @config.stage_provider_source(stage),
          fallbacks: @config.stage_fallbacks_source(stage)
        }]
      end
    end

    # Стадия — запрос, разбор и одна починка той же моделью. Негодный
    # результат после починки, как и починка без попыток, исключает модель
    # для стадии, и стадия начинается заново на следующей — с исходным
    # запросом. Ошибки API идут мимо: их резервами занимается роутер, а
    # маршруты кончились — значит, кончились и для перезапуска.
    def run_stage(stage)
      loop do
        return yield
      rescue ParseError => e
        reason = "#{e.is_a?(RepairImpossibleError) ? 'repair impossible' : 'invalid result'}: #{e.message}"
        excluded = @reviewer.exclude_answered_model(stage: stage, reason: reason)
        raise unless excluded

        @logger.warn("Pipeline #{stage}: restarting on the next model after #{excluded} (#{e.message})")
      end
    end

    # Привязка к коду проверяется по диффу, который видела модель, до критика:
    # ему уходят пометки, в отчёт — сброшенная строка и знак ненайденной цитаты.
    def check_candidates(context:, changes:, candidates:)
      CandidateChecker.new(
        changes: changes,
        diff_text: context.diff_text,
        coverage: context.coverage,
        logger: @logger
      ).check(candidates)
    end

    def skip_critique(candidates, reason = nil)
      @logger.info(['Pipeline critique pass skipped', reason].compact.join(': '))
      candidates
    end

    # Критику нечего фильтровать без кандидатов: запрос к LLM был бы пустой
    # тратой квоты и времени.
    def maybe_critique(context:, candidates:)
      return skip_critique(candidates, 'no candidates') if candidates.empty?

      @logger.info("Pipeline critique pass started (model=#{@config.critique_model})")
      critique_candidates(context: context, candidates: candidates)
    end

    def critique_candidates(context:, candidates:)
      candidates_json = JSON.pretty_generate(candidates)
      candidates_by_id = index_candidates_by_id(candidates)
      critique_prompt = @context_builder.build_critique_prompt(context, candidates_json: candidates_json)
      critique_result = run_stage('critique') do
        parse_with_repair(
          raw: @reviewer.critique(**critique_prompt),
          kind: 'critique result',
          expected: 'critique',
          repair_stage: 'critique',
          critique_candidate_ids: candidates_by_id.keys
        )
      end
      verdicts = Array(critique_result['verdicts'])
      @logger.info("Pipeline critique pass completed with #{verdicts.size} verdict(s) " \
                   "(model=#{@reviewer.answered_model('critique')})")
      apply_critique_verdicts(
        verdicts: verdicts,
        candidates_by_id: candidates_by_id
      )
    end

    def parse_with_repair(raw:, kind:, expected:, repair_stage:, critique_candidate_ids: nil)
      if raw.is_a?(Hash)
        return parse_structured_result(
          raw,
          kind: kind,
          expected: expected,
          critique_candidate_ids: critique_candidate_ids
        )
      end

      raise ParseError, "LLM returned unsupported #{kind} type: #{raw.class}" unless raw.is_a?(String)

      parse_string_with_repair(
        raw: raw,
        kind: kind,
        expected: expected,
        repair_stage: repair_stage,
        critique_candidate_ids: critique_candidate_ids
      )
    end

    def parse_structured_result(raw, kind:, expected:, critique_candidate_ids: nil)
      parse_expected_result(raw, expected, critique_candidate_ids: critique_candidate_ids)
    rescue SchemaError => e
      raise ParseError, "LLM returned invalid #{kind}: #{e.message}"
    end

    def parse_string_with_repair(raw:, kind:, expected:, repair_stage:, critique_candidate_ids: nil)
      parse_expected_result(raw, expected, critique_candidate_ids: critique_candidate_ids)
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
        parse_expected_result(repaired, expected, critique_candidate_ids: critique_candidate_ids)
      rescue JSON::ParserError, SchemaError => second_error
        raise ParseError, "LLM returned invalid #{kind} JSON after repair: #{second_error.message}"
      end
    end

    def parse_expected_result(raw, expected, critique_candidate_ids: nil)
      @parser.parse(raw, expected: expected, critique_candidate_ids: critique_candidate_ids)
    end

    def repair_json(raw:, kind:, expected:, stage:, critique_candidate_ids: nil)
      schema = expected == 'critique' ? ReviewSchemas.critique : ReviewSchemas.generate
      user_prompt = <<~PROMPT
        The previous #{kind} response was invalid.

        Convert it into valid JSON matching this schema:
        #{schema}

        Do not add new findings. Do not remove findings unless they cannot be represented.
        Return only JSON.

        Invalid response:
        #{raw}
      PROMPT
      if stage == 'critique' && critique_candidate_ids
        user_prompt << "\nExpected candidate ids: #{critique_candidate_ids.join(', ')}\n"
      end

      @logger.info("Pipeline #{stage} repair started for #{kind}")
      prompt = repair_prompt(stage, user_prompt)
      if stage == 'critique'
        @reviewer.critique(**prompt, pinned: true)
      else
        @reviewer.generate(**prompt, pinned: true)
      end
    end

    # Починка, которая не помещается в лимит стадии, — негодный результат
    # этой модели, а не ошибка размера исходного запроса: стадия уходит на
    # следующую модель с исходным промптом.
    def repair_prompt(stage, user_prompt)
      @context_builder.check_stage_size!(stage, REPAIR_SYSTEM_PROMPT, user_prompt)
    rescue ContextBudgetError => e
      raise ParseError, "repair request does not fit the stage limit: #{e.message}"
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

    def normalize_decision(value)
      value.to_s.strip.downcase
    end

    def presence(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
    alias normalize_id presence
  end
end
