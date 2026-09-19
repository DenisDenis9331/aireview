# frozen_string_literal: true

module Aireview
  KNOWN_PROVIDERS = %w[gemini ollama].freeze

  # Модель в цепочке стадии: провайдер, имя и предел размера запроса.
  # Сравнивается по провайдеру и имени — предел зависит от стадии.
  ModelCandidate = Struct.new(:provider, :model, :max_prompt_chars, keyword_init: true) do
    def to_s
      "#{provider}/#{model}"
    end

    def same_model?(other)
      to_s == other.to_s
    end

    # Строка «провайдер/имя» или просто имя (провайдер отделён слэшем,
    # потому что теги Ollama содержат двоеточие), либо хеш с model.
    def self.parse_item(item)
      return item unless item.is_a?(String)

      provider, model = item.split('/', 2)
      return {'provider' => provider, 'model' => model} if model && KNOWN_PROVIDERS.include?(provider)

      {'model' => item}
    end
  end
end
