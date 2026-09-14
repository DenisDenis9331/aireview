# frozen_string_literal: true

module Aireview
  # Резервы на случай, когда основная модель лежит или у ключа кончилась
  # квота: цепочка моделей на стадию и список ключей на провайдера. Модели
  # задаются в .aireview.yml или env, ключи — только в env.
  module ConfigFallbacks
    ModelCandidate = Struct.new(:provider, :model, :max_prompt_chars, keyword_init: true) do
      def to_s
        "#{provider}/#{model}"
      end
    end

    KNOWN_PROVIDERS = %w[gemini ollama].freeze
    KEYLESS_PROVIDERS = %w[ollama].freeze
    PROVIDER_KEYS_MAPPING = {
      'gemini' => 'GEMINI_API_KEYS'
    }.freeze
    DEFAULT_TIME_BUDGET = 1_800

    module ClassMethods
      # LLM_GENERATE_FALLBACK_MODEL=gemini-3.8-flash (или список через запятую) —
      # провайдер отделён слэшем, потому что теги Ollama содержат двоеточие.
      def fallback_models_env_config(env, stage)
        value = env["LLM_#{stage}_FALLBACK_MODEL"]
        return nil if Aireview::Utils.blank?(value)

        value.split(',').map(&:strip).reject(&:empty?).map { |item| parse_fallback_item(item) }
      end

      def parse_fallback_item(item)
        provider, model = item.split('/', 2)
        return {'provider' => provider, 'model' => model} if model && KNOWN_PROVIDERS.include?(provider)

        {'model' => item}
      end

      def provider_keys_env_config(env)
        PROVIDER_KEYS_MAPPING.each_with_object({}) do |(provider, env_key), config|
          keys = env[env_key].to_s.split(',').map(&:strip).reject(&:empty?)
          config["#{provider}_api_keys"] = keys unless keys.empty?
        end
      end
    end

    # Первый элемент — основная модель стадии, дальше запасные в порядке
    # обхода. Запасная без провайдера наследует провайдера стадии, без
    # max_prompt_chars — лимит стадии.
    def stage_chain(stage)
      stage = stage.to_s
      primary = ModelCandidate.new(
        provider: public_send("#{stage}_provider"),
        model: public_send("#{stage}_model"),
        max_prompt_chars: max_prompt_chars(stage)
      )
      return [primary] if fallbacks_disabled?

      [primary, *fallback_candidates(stage, primary)]
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

    private

    def fallback_candidates(stage, primary)
      Array(dig('llm', stage, 'fallbacks')).each_with_index.map do |item, index|
        item = {'model' => item} if item.is_a?(String)
        name = "llm.#{stage}.fallbacks[#{index}]"
        raise ConfigError, "#{name} must be a model name or a hash with model" unless item.is_a?(Hash)
        raise ConfigError, "#{name}.model is required" if Aireview::Utils.blank?(item['model'])

        limit = item['max_prompt_chars']
        ModelCandidate.new(
          provider: (item['provider'] || primary.provider).to_s,
          model: item['model'].to_s,
          max_prompt_chars: limit.nil? ? primary.max_prompt_chars : positive_integer!(limit, "#{name}.max_prompt_chars")
        )
      end
    end
  end
end
