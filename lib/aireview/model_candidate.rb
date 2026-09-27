# frozen_string_literal: true
require_relative 'errors'

module Aireview
  # Providers a "provider/name" string may start with. An OpenRouter name
  # carries a slash of its own, so in a string it always goes with the
  # prefix: openrouter/anthropic/claude-sonnet-4.5.
  KNOWN_PROVIDERS = %w[gemini ollama openai anthropic openrouter].freeze

  # A model in a stage chain: provider, name, request size limit and, for a
  # server of your own, its address. Compared by provider, name and address
  # — the limit depends on the stage.
  ModelCandidate = Struct.new(:provider, :model, :max_prompt_chars, :api_base, keyword_init: true) do
    # The address is part of the name, scheme included: two servers with the
    # same model (http and https ones too) are two models for quarantine,
    # reserves and the review key.
    def to_s
      name = "#{provider}/#{model}"
      api_base ? "#{name}@#{api_base.chomp('/')}" : name
    end

    # Every way a start or a CLI override may name this model: bare,
    # "provider/name", or the full name with the address. One list for the
    # config check and for picking the model, so they cannot disagree.
    def names
      [model.to_s, "#{provider}/#{model}", to_s].uniq
    end

    def same_model?(other)
      to_s == other.to_s
    end

    # Models sharing keys: a provider's own API, or one server of your own.
    def key_source
      api_base ? "#{provider}@#{api_base}" : provider.to_s
    end

    # api_base of a model or a stage: an http(s) address or nothing.
    def self.api_base(value, name)
      return nil if value.nil? || value.to_s.strip.empty?
      return value.to_s.strip if value.to_s.strip.match?(%r{\Ahttps?://\S+\z})

      raise ConfigError, "#{name} must be an http(s) URL, got #{value.inspect}"
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
