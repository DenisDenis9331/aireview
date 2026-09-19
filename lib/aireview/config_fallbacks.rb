# frozen_string_literal: true
require_relative 'stages'
require_relative 'errors'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'stage_chains'
require_relative 'model_pool'

module Aireview
  # Резервы на случай, когда основная модель лежит или у ключа кончилась
  # квота: план маршрутизации (см. StageChains и ModelPool) и список ключей
  # на провайдера. Модели задаются в .aireview.yml или env, ключи — только
  # в env.
  module ConfigFallbacks
    KEYLESS_PROVIDERS = %w[ollama].freeze
    DEFAULT_TIME_BUDGET = 1_800
    DEFAULT_OVERLOADED_QUARANTINE = 120

    # План маршрутизации строится один раз: общий пул, если задан llm.models,
    # иначе независимые цепочки стадий. Стадия со своей model внутри пула —
    # независимая цепочка.
    def routing
      @routing ||= build_routing
    end

    def stage_chain(stage)
      routing.chain(stage)
    end

    # Ключи в порядке предпочтения; для провайдера без ключей — один nil,
    # чтобы обход цепочки не зависел от провайдера.
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

    # Только число ключей на провайдера — для --dry-run; значения наружу не
    # выходят.
    def api_key_counts(stages)
      providers = stages.flat_map { |stage| stage_chain(stage).map(&:provider) }.uniq
      providers.reject { |provider| KEYLESS_PROVIDERS.include?(provider.to_s) }
        .to_h { |provider| [provider, provider_api_keys(provider).size] }
    end

    # Общий потолок на все LLM-запросы прогона вместе с паузами между
    # попытками: цепочка резервов не должна съедать всю CI-джобу.
    def llm_time_budget
      positive_integer!(dig('llm', 'time_budget') || DEFAULT_TIME_BUDGET, 'llm.time_budget')
    end

    # Сколько секунд перегруженная или зависшая модель пропускается, прежде
    # чем роутер попробует её снова.
    def overloaded_quarantine
      positive_integer!(dig('llm', 'overloaded_quarantine') || DEFAULT_OVERLOADED_QUARANTINE,
                        'llm.overloaded_quarantine')
    end

    def require_models!
      missing = []
      missing << 'llm.generate.model (or LLM_GENERATE_MODEL)' if Aireview::Utils.blank?(generate_model)
      missing << 'llm.critique.model (or LLM_CRITIQUE_MODEL)' if Aireview::Utils.blank?(critique_model)
      raise ConfigError, "LLM models are required: #{missing.join(', ')}" unless missing.empty?
    end

    # План строится целиком (с проверкой пула и политики критики) до первого
    # запроса, а не в критике после оплаченного generate.
    def require_llm_configuration!
      require_models!
      routing

      missing_keys = STAGES.flat_map do |stage|
        providers = stage_chain(stage).map(&:provider).uniq.reject { |provider| provider_keys_present?(provider) }
        providers.map { |provider| "#{stage}: API key is required for provider #{provider.inspect}" }
      end
      raise ConfigError, missing_keys.join(', ') unless missing_keys.empty?
    end

    private

    def build_routing
      settings = STAGES.to_h { |stage| [stage, stage_settings(stage)] }
      models = Array(dig('llm', 'models'))
      return StageChains.build(settings, only_primary: fallbacks_disabled?) if models.empty?

      own = settings.select { |_, stage_settings| Aireview::Utils.present?(stage_settings[:model]) }
      ModelPool.new(
        items: models, provider: llm_provider,
        limits: STAGES.to_h { |stage| [stage, max_prompt_chars(stage)] },
        starts: STAGES.to_h { |stage| [stage, dig('llm', stage, 'start')] },
        inherited_starts: STAGES.select { |stage| start_inherited?(stage) },
        rank: dig('llm', 'critique', 'rank'), allow_weaker: dig('llm', 'critique', 'allow_weaker'),
        own_chains: StageChains.build(own, only_primary: fallbacks_disabled?), only_primary: fallbacks_disabled?
      )
    end

    def stage_settings(stage)
      {
        provider: stage_setting(stage, 'provider') || llm_provider,
        model: dig('llm', stage, 'model'),
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
