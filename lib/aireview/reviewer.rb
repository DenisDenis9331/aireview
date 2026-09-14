# frozen_string_literal: true
require_relative 'errors'
require_relative 'output_schemas'
require_relative 'utils'
require_relative 'llm_router'
require 'timeout'

module Aireview
  class Reviewer
    attr_reader :router

    def initialize(config:, logger: Logger.new($stderr), router: nil)
      @config = config
      @logger = logger
      @router = router || LlmRouter.new(config: config, logger: logger)
      @llm_contexts = {}
    end

    def generate(system_prompt:, user_prompt:)
      call_llm(
        stage: 'generate',
        system: system_prompt,
        user: user_prompt,
        options: {temperature: @config.generate_temperature, schema: GenerateOutputSchema}
      )
    end

    def critique(system_prompt:, user_prompt:)
      call_llm(
        stage: 'critique',
        system: system_prompt,
        user: user_prompt,
        options: {temperature: @config.critique_temperature, schema: CritiqueOutputSchema}
      )
    end

    # Стадии, ответившие запасной моделью, для строки в отчёте.
    def fallback_models
      @router.fallback_models
    end

    private

    def call_llm(stage:, system:, user:, options:)
      require 'ruby_llm'

      @config.require_llm_configuration!
      response = @router.call(stage: stage, request_chars: system.length + user.length) do |route, timeout|
        perform_llm_request(
          context: llm_context(stage, route),
          stage: stage,
          system: system,
          user: user,
          options: options.merge(model: route.candidate.model, provider: route.candidate.provider, timeout: timeout)
        )
      end
      response.content
    rescue LoadError => e
      @logger.error("LLM #{stage} setup failed: #{e.message}")
      raise ConfigError, "Missing dependency: #{e.message}"
    end

    def perform_llm_request(context:, stage:, system:, user:, options:)
      model = options[:model]
      temperature = options[:temperature]
      @logger.info("LLM #{stage} request started (model=#{model}, temperature=#{temperature})")
      chat = build_chat(context: context, stage: stage, model: model, provider: options[:provider])
      chat = configure_reasoning(chat: chat, model: model, provider: options[:provider])
        .with_temperature(temperature.to_f)
        .with_schema(options[:schema])
      chat.with_instructions(system)
      response = Timeout.timeout(options[:timeout]) { chat.ask(user) }
      @logger.info("LLM #{stage} request completed (model=#{model})")
      response
    rescue Timeout::Error
      @logger.warn("LLM #{stage} request timed out after #{options[:timeout].round} seconds (model=#{model})")
      raise
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

    # Контекст RubyLLM на стадию, провайдера и номер ключа: смена ключа —
    # это другой контекст, а не правка глобального конфига.
    def llm_context(stage, route)
      cache_key = [stage, route.candidate.provider, route.key_index]
      @llm_contexts[cache_key] ||= build_llm_context(route.candidate.provider.to_s, route.key)
    end

    # Повторами занимается роутер: встроенные ретраи RubyLLM/Faraday (по
    # умолчанию 3) превратили бы каждую нашу попытку в четыре HTTP-запроса и
    # жгли бы квоту до того, как ошибка дойдёт до классификатора.
    def build_llm_context(provider, api_key)
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

    def configure_remote_provider(ruby_config, provider, api_key)
      ruby_config.public_send("#{provider}_api_key=", api_key)
      return unless Aireview::Utils.present?(@config.llm_api_base)

      ruby_config.public_send("#{provider}_api_base=", @config.llm_api_base)
    end
  end
end
