# frozen_string_literal: true
require 'json'
require 'timeout'
require_relative 'errors'
require_relative 'utils'

module Aireview
  # One request to one model with one key through RubyLLM. Retries, keys and
  # reserves belong to LlmRouter: the built-in RubyLLM/Faraday retries (3 by
  # default) are off, otherwise every router attempt would turn into four
  # HTTP requests and burn quota before the error reaches the classifier.
  class LlmClient
    # What a stage sends to the model; the same for every route of the stage.
    Prompt = Struct.new(:stage, :system, :user, :temperature, :schema, keyword_init: true) do
      def chars
        system.length + user.length
      end
    end

    def initialize(config:, logger: Logger.new($stderr))
      @config = config
      @logger = logger
      @contexts = {}
    end

    # Returns the RubyLLM answer; read it with LlmClient.content. A request
    # error is re-raised as is — LlmFailure classifies it.
    def request(prompt, candidate:, key:, timeout:, key_index: 0)
      load_ruby_llm
      stage = prompt.stage.to_s
      model = candidate.model
      @logger.info("LLM #{stage} request started (model=#{model}, temperature=#{prompt.temperature})")
      chat = build_chat(context: context(stage, candidate.provider, key, key_index), stage: stage,
                        model: model, provider: candidate.provider)
      chat = configure_reasoning(chat: chat, model: model, provider: candidate.provider)
        .with_temperature(prompt.temperature.to_f)
        .with_schema(prompt.schema)
      chat.with_instructions(prompt.system)
      response = Timeout.timeout(timeout) { chat.ask(prompt.user) }
      @logger.info("LLM #{stage} request completed (model=#{model}#{token_counts(response)})")
      response
    rescue Timeout::Error
      @logger.warn("LLM #{stage} request timed out after #{timeout.round} seconds (model=#{model})")
      raise
    end

    # The answer as RubyLLM 1.x gave it under a schema: the parsed JSON when
    # the text is JSON, the text itself otherwise (the pipeline repairs it).
    # RubyLLM 2 always returns the text, and a Hash that breaks the schema
    # would go to a repair request instead of the next model. An empty
    # answer stays an empty String (Message#parsed would turn it into nil);
    # JSON null becomes nil, as in 1.x.
    def self.content(response)
      content = response.content
      return content unless content.is_a?(String) && !content.empty?

      response.parsed
    rescue JSON::ParserError
      content
    end

    private

    # Token counts as the provider reported them, one line per attempt. They
    # are not summed: Gemini already counts thinking into output. Input is
    # what was not read from or written to a cache; the prompt size is
    # input + cache_read + cache_write, and a retry of the same prompt on
    # Gemini is often served from its implicit cache.
    def token_counts(response)
      tokens = response.tokens
      cached = {cache_read: tokens.cache_read, cache_write: tokens.cache_write}.reject { |_, count| count.to_i.zero? }
      counts = {input: tokens.input, output: tokens.output, thinking: tokens.thinking}.compact.merge(cached)
      return '' if counts.empty?

      ", tokens: #{counts.map { |name, count| "#{name}=#{count}" }.join(' ')}"
    end

    def load_ruby_llm
      require 'ruby_llm'
    rescue LoadError => e
      @logger.error("LLM setup failed: #{e.message}")
      raise ConfigError, "Missing dependency: #{e.message}"
    end

    def configure_reasoning(chat:, model:, provider:)
      return chat unless provider == 'ollama' && model.start_with?('gpt-oss:')

      chat.with_thinking(effort: :low)
    end

    def build_chat(context:, stage:, model:, provider:)
      context.chat(model: model, provider: provider.to_sym)
    rescue RubyLLM::ModelNotFoundError
      @logger.warn(
        "LLM #{stage}: model not found in RubyLLM registry; " \
        "using fallback with incomplete model metadata " \
        "(model=#{model}, provider=#{provider})"
      )
      context.chat(model: model, provider: provider.to_sym, assume_model_exists: true)
    end

    # A RubyLLM context per stage, provider and key index: switching the key
    # is another context, not an edit of the global config.
    def context(stage, provider, key, key_index)
      @contexts[[stage, provider, key_index]] ||= build_context(provider.to_s, key)
    end

    def build_context(provider, api_key)
      RubyLLM.context do |ruby_config|
        configure_http_proxy(ruby_config)
        ruby_config.request_timeout = @config.llm_timeout.to_f
        ruby_config.max_retries = 0
        configure_provider(ruby_config, provider, api_key)
      end
    end

    def configure_http_proxy(ruby_config)
      return unless Aireview::Utils.present?(@config.llm_http_proxy)

      ruby_config.http_proxy = @config.llm_http_proxy
    end

    def configure_provider(ruby_config, provider, api_key)
      case provider
      when 'gemini', 'openai', 'openrouter'
        configure_remote_provider(ruby_config, provider, api_key)
      when 'anthropic'
        ruby_config.anthropic_api_key = api_key
      when 'ollama'
        ruby_config.ollama_api_base = @config.ollama_api_base
      else
        raise ConfigError, "Unsupported LLM provider: #{provider.inspect}"
      end
    end

    # RubyLLM 2 sends OpenAI requests to the Responses API; a compatible
    # server behind LLM_API_BASE usually has Chat Completions only.
    def configure_remote_provider(ruby_config, provider, api_key)
      ruby_config.public_send("#{provider}_api_key=", api_key)
      ruby_config.openai_protocol = :chat_completions if provider == 'openai'
      return unless Aireview::Utils.present?(@config.llm_api_base)

      ruby_config.public_send("#{provider}_api_base=", @config.llm_api_base)
    end
  end
end
