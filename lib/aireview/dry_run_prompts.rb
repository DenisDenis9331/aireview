# frozen_string_literal: true
require 'json'
require 'logger'
require_relative 'utils'
require_relative 'jev_critic'

module Aireview
  # The prompts of a run without calling a model, and everything --dry-run
  # shows. The review key is computed from them too (ReviewMarker): the LLM
  # Critique prompt is built only when an LLM Critique can run, the Jev
  # question templates only when Jev decides.
  class DryRunPrompts
    CANDIDATES_JSON = '[{"id":"C1","file":"path/from/diff.rb","line":1,' \
                      '"quoted_code":"...","problem":"...","why":"...","suggestion":"...",' \
                      '"category":"bug","severity":"major"}]'

    def initialize(config:, context_builder:, logger: Logger.new($stderr))
      @config = config
      @context_builder = context_builder
      @logger = logger
    end

    def build(merge_request:, changes:, jira_issue: nil, critique: true)
      @config.require_models!(critique: critique)
      stages = @config.llm_stages(critique: critique)
      context = @context_builder.prepare(
        merge_request: merge_request,
        changes: changes,
        jira_issue: jira_issue,
        critique: critique
      )

      prompts(context, stages, critique).merge(settings(context, stages, critique))
    end

    private

    def prompts(context, stages, critique)
      jev = @config.jev_critique?(critique: critique)
      critique_prompt = if stages.include?('critique')
                          @context_builder.build_critique_prompt(context, candidates_json: CANDIDATES_JSON)
                        end
      {
        generate_prompt: @context_builder.build_generate_prompt(context),
        critique_prompt: critique_prompt,
        jev_questions: jev ? JevCritic.decision_templates : nil,
        jev_critique: jev ? jev_critique_settings(context) : nil,
        jev_shadow: critique && !jev ? jev_shadow_settings : nil
      }
    end

    def settings(context, stages, critique)
      llm_critique = stages.include?('critique')
      {
        generate_model: @config.generate_model,
        generate_temperature: @config.generate_temperature,
        critique_model: @config.critique_model,
        critique_temperature: @config.critique_temperature,
        generate_fallbacks: @config.fallback_names('generate'),
        critique_fallbacks: llm_critique ? @config.fallback_names('critique') : [],
        sources: setting_sources(stages),
        config_paths: @config.layer_paths,
        warnings: @config.warnings,
        critique_rule: llm_critique ? @config.routing.rule : nil,
        api_keys: @config.api_key_counts(stages),
        time_budget: @config.llm_time_budget,
        overloaded_quarantine: @config.overloaded_quarantine,
        coverage: context.coverage,
        sizes: context.sizes
      }
    end

    # The Jev request as it would go for the stub candidate; nothing is sent,
    # so the critic needs no client. Only whether the key is set: its value
    # never leaves.
    def jev_critique_settings(context)
      critic = JevCritic.new(client: nil, thresholds: @config.jev_thresholds,
                             review_instructions: @config.review_instructions,
                             scrub: @context_builder.method(:scrub_text), logger: @logger)
      request = critic.preview(context: context, candidates: JSON.parse(CANDIDATES_JSON))
      {model: @config.jev_model, key: Aireview::Utils.present?(@config.jev_api_key),
       thresholds: @config.jev_thresholds, fallback: @config.jev_fallback,
       state: request.state, questions: request.questions}
    end

    # Only whether the key is set: its value never leaves.
    def jev_shadow_settings
      return nil unless @config.jev_shadow?

      {model: @config.jev_model, key: Aireview::Utils.present?(@config.jev_api_key), thresholds: @config.jev_thresholds}
    end

    # Where the model, provider and reserves of a stage came from, for --dry-run.
    def setting_sources(stages)
      stages.to_h do |stage|
        [stage.to_sym, {
          model: @config.stage_model_source(stage),
          provider: @config.stage_provider_source(stage),
          fallbacks: @config.stage_fallbacks_source(stage)
        }]
      end
    end
  end
end
