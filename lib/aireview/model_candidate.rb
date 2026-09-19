# frozen_string_literal: true

module Aireview
  KNOWN_PROVIDERS = %w[gemini ollama].freeze

  # A model in a stage chain: provider, name and request size limit.
  # Compared by provider and name — the limit depends on the stage.
  ModelCandidate = Struct.new(:provider, :model, :max_prompt_chars, keyword_init: true) do
    def to_s
      "#{provider}/#{model}"
    end

    def same_model?(other)
      to_s == other.to_s
    end

    # A "provider/name" string or a bare name (the provider is separated by
    # a slash because Ollama tags contain a colon), or a hash with model.
    def self.parse_item(item)
      return item unless item.is_a?(String)

      provider, model = item.split('/', 2)
      return {'provider' => provider, 'model' => model} if model && KNOWN_PROVIDERS.include?(provider)

      {'model' => item}
    end
  end
end
