# frozen_string_literal: true
require_relative 'stages'
require_relative 'errors'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'stage_chains'
require_relative 'model_pool'

module Aireview
  # Reserves for when the primary model is down or a key is out of quota:
  # the routing plan (see StageChains and ModelPool) and the list of keys
  # per provider. Models are set in .aireview.yml or the environment, keys
  # only in the environment.
  module ConfigFallbacks
    KEYLESS_PROVIDERS = %w[ollama].freeze
    DEFAULT_TIME_BUDGET = 1_800
    DEFAULT_OVERLOADED_QUARANTINE = 120

    # The routing plan is built once: a shared pool when llm.models is set,
    # independent stage chains otherwise. A stage with a model of its own
    # inside the pool is an independent chain.
    def routing
      @routing ||= build_routing
    end

    def stage_chain(stage)
      routing.chain(stage)
    end

    # The keys a model is called with. A server of your own (a model with
    # api_base) never gets the provider's key — OPENAI_API_KEY must not leave
    # for a self-hosted server — but LLM_API_KEY, or a placeholder for a
    # server without auth, since the client wants some key.
    SELF_HOSTED_PLACEHOLDER_KEY = 'no-key'

    def candidate_api_keys(candidate)
      return provider_api_keys(candidate.provider) unless candidate.api_base
      return [nil] if KEYLESS_PROVIDERS.include?(candidate.provider.to_s)

      [Aireview::Utils.presence(llm_api_key) || SELF_HOSTED_PLACEHOLDER_KEY]
    end

    # Keys in order of preference; a single nil for a keyless provider, so
    # that walking the chain does not depend on the provider.
    def provider_api_keys(provider)
      provider = provider.to_s
      return [nil] if KEYLESS_PROVIDERS.include?(provider)

      keys = Array(@data["#{provider}_api_keys"]).compact
      keys = [provider_api_key(provider)].compact if keys.empty?
      fallbacks_disabled? ? keys.first(1) : keys
    end

    def fallbacks_disabled?
      @data['fallbacks_disabled'] == true
    end

    def fallback_names(stage)
      stage_chain(stage).drop(1).map(&:to_s)
    end

    # Only the number of keys per provider, for --dry-run; the values never
    # leave. Servers of your own are not counted: they take LLM_API_KEY.
    def api_key_counts(stages)
      providers = stages.flat_map { |stage| stage_chain(stage).reject(&:api_base).map(&:provider) }.uniq
      providers.reject { |provider| KEYLESS_PROVIDERS.include?(provider.to_s) }
        .to_h { |provider| [provider, provider_api_keys(provider).size] }
    end

    # The ceiling for all LLM requests of the run, pauses between attempts
    # included: the chain of reserves must not eat the whole CI job.
    def llm_time_budget
      positive_integer!(dig('llm', 'time_budget') || DEFAULT_TIME_BUDGET, 'llm.time_budget')
    end

    # For how many seconds an overloaded or hung model is skipped before the
    # router tries it again.
    def overloaded_quarantine
      positive_integer!(dig('llm', 'overloaded_quarantine') || DEFAULT_OVERLOADED_QUARANTINE,
                        'llm.overloaded_quarantine')
    end

    # critique — the run has a critique (false with --no-critique); only the
    # stages that need an LLM in such a run are required (see llm_stages).
    def require_models!(critique: true)
      stages = llm_stages(critique: critique)
      missing = []
      missing << 'llm.generate.model (or LLM_GENERATE_MODEL)' if Aireview::Utils.blank?(generate_model)
      if stages.include?('critique') && Aireview::Utils.blank?(critique_model)
        missing << 'llm.critique.model (or LLM_CRITIQUE_MODEL)'
      end
      raise ConfigError, "LLM models are required: #{missing.join(', ')}" unless missing.empty?
    end

    # The plan is built whole (pool and critique policy validated) before the
    # first request, not in Critique after a paid-for Generate. Keys are
    # required for the stages that need an LLM: generate on Ollama with Jev
    # as the critic and no fallback needs no Gemini key.
    def require_llm_configuration!(critique: true)
      require_models!(critique: critique)
      require_jev!(critique: critique)
      routing

      missing_keys = llm_stages(critique: critique).flat_map do |stage|
        providers = stage_chain(stage).reject(&:api_base).map(&:provider).uniq
        providers.reject { |provider| provider_keys_present?(provider) }
          .map { |provider| "#{stage}: API key is required for provider #{provider.inspect}" }
      end
      raise ConfigError, missing_keys.join(', ') unless missing_keys.empty?
    end

    private

    # Only the stages that go to an LLM are routed (llm_stages): without an
    # LLM Critique (Jev with fallback: fail, --no-critique) its model, limit,
    # start, rank and allow_weaker are not used, so they must neither fail
    # the run nor change the review key, nor push the pool out of it.
    def build_routing
      stages = llm_stages
      settings = stages.to_h { |stage| [stage, stage_settings(stage)] }
      models = Array(dig('llm', 'models'))
      return StageChains.build(settings, only_primary: fallbacks_disabled?) if models.empty?

      own = settings.select { |_, stage_settings| Aireview::Utils.present?(stage_settings[:model]) }
      ModelPool.new(
        items: models, provider: llm_provider, stages: stages,
        limits: stages.to_h { |stage| [stage, max_prompt_chars(stage)] },
        starts: stages.to_h { |stage| [stage, dig('llm', stage, 'start')] },
        inherited_starts: stages.select { |stage| start_inherited?(stage) },
        rank: dig('llm', 'critique', 'rank'), allow_weaker: dig('llm', 'critique', 'allow_weaker'),
        own_chains: StageChains.build(own, only_primary: fallbacks_disabled?), only_primary: fallbacks_disabled?
      )
    end

    def stage_settings(stage)
      {
        provider: stage_setting(stage, 'provider') || llm_provider,
        model: dig('llm', stage, 'model'),
        api_base: dig('llm', stage, 'api_base'),
        fallbacks: dig('llm', stage, 'fallbacks'),
        max_prompt_chars: max_prompt_chars(stage)
      }
    end

    def provider_keys_present?(provider)
      return true if ConfigFallbacks::KEYLESS_PROVIDERS.include?(provider.to_s)

      provider_api_keys(provider).any? { |key| Aireview::Utils.present?(key) }
    end
  end
end
