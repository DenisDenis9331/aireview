# frozen_string_literal: true
require 'timeout'
require_relative 'errors'
require_relative 'utils'

module Aireview
  # Один запрос к одной модели с одним ключом через RubyLLM. Повторами,
  # ключами и резервами занимается LlmRouter: встроенные ретраи
  # RubyLLM/Faraday (по умолчанию 3) выключены, иначе каждая попытка
  # роутера превращалась бы в четыре HTTP-запроса и жгла квоту до того,
  # как ошибка дойдёт до классификатора.
  class LlmClient
    # Что стадия отправляет модели; одинаково для всех маршрутов стадии.
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

    # Возвращает ответ RubyLLM (content — текст или структура по схеме).
    # Ошибка запроса пробрасывается как есть — её классифицирует LlmFailure.
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
      @logger.info("LLM #{stage} request completed (model=#{model})")
      response
    rescue Timeout::Error
      @logger.warn("LLM #{stage} request timed out after #{timeout.round} seconds (model=#{model})")
      raise
    end

    private

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

    # Контекст RubyLLM на стадию, провайдера и номер ключа: смена ключа —
    # это другой контекст, а не правка глобального конфига.
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

    def configure_remote_provider(ruby_config, provider, api_key)
      ruby_config.public_send("#{provider}_api_key=", api_key)
      return unless Aireview::Utils.present?(@config.llm_api_base)

      ruby_config.public_send("#{provider}_api_base=", @config.llm_api_base)
    end
  end
end
