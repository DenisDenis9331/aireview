# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'
require 'timeout'

module Aireview
  class Reviewer
    MAX_TRANSIENT_RETRIES = 2
    TRANSIENT_RETRY_BASE_DELAY = 2.0
    TRANSIENT_RETRY_JITTER_RANGE = 2.0..5.0
    PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE = 2.0..2.4
    OVERLOADED_RETRY_DELAY_RANGE = 90.0..150.0
    RETRY_WAIT_LOG_FORMAT = 'LLM %<stage>s request will sleep %<delay>.1fs before retry%<source>s ' \
                            '(attempt %<next_attempt>d/%<max_attempts>d, model=%<model>s)'

    def initialize(config:, logger: Logger.new($stderr))
      @config = config
      @logger = logger
      @llm_contexts = {}
    end

    def generate(system_prompt:, user_prompt:)
      call_llm(
        stage: 'generate',
        system: system_prompt,
        user: user_prompt,
        options: {
          model: @config.generate_model,
          temperature: @config.generate_temperature,
          provider: @config.generate_provider
        }
      )
    end

    def critique(system_prompt:, user_prompt:)
      call_llm(
        stage: 'critique',
        system: system_prompt,
        user: user_prompt,
        options: {
          model: @config.critique_model,
          temperature: @config.critique_temperature,
          provider: @config.critique_provider
        }
      )
    end

    private

    def call_llm(stage:, system:, user:, options:)
      require 'ruby_llm'

      @config.require_llm_configuration!
      context = llm_context(stage, options[:provider])
      response = request_with_retries(stage: stage, model: options[:model]) do
        perform_llm_request(
          context: context,
          stage: stage,
          system: system,
          user: user,
          options: options
        )
      end
      response.content
    rescue LoadError => e
      @logger.error("LLM #{stage} setup failed: #{e.message}")
      raise ConfigError, "Missing dependency: #{e.message}"
    rescue Timeout::Error
      @logger.warn(
        "LLM #{stage} request timed out after #{@config.llm_timeout} seconds (model=#{options[:model]})"
      )
      raise ApiError, "LLM request timed out after #{@config.llm_timeout} seconds. " \
                      "Try again later or switch model via --generate-model/--critique-model."
    end

    def perform_llm_request(context:, stage:, system:, user:, options:)
      model = options[:model]
      temperature = options[:temperature]
      @logger.info("LLM #{stage} request started (model=#{model}, temperature=#{temperature})")
      chat = context.chat(
        model: model,
        provider: options[:provider].to_sym,
        assume_model_exists: true
      ).with_temperature(temperature.to_f)
      chat.with_instructions(system)
      response = Timeout.timeout(@config.llm_timeout.to_f) { chat.ask(user) }
      @logger.info("LLM #{stage} request completed (model=#{model})")
      response
    end

    def request_with_retries(stage:, model:)
      attempt = 0

      begin
        attempt += 1
        yield
      rescue StandardError => e
        raise unless ruby_llm_api_error?(e)

        @logger.warn("LLM #{stage} request failed (model=#{model}): #{e.class}: #{e.message}")
        raise ApiError, llm_error_message(e) unless retry_llm_request?(e, attempt)

        wait_before_retry(error: e, attempt: attempt, stage: stage, model: model)
        retry
      end
    end

    def retry_llm_request?(error, attempt)
      transient_llm_error?(error) && attempt <= MAX_TRANSIENT_RETRIES
    end

    def wait_before_retry(error:, attempt:, stage:, model:)
      retry_delay = transient_retry_delay(error: error, attempt: attempt)
      @logger.warn(
        format(
          RETRY_WAIT_LOG_FORMAT,
          stage: stage,
          delay: retry_delay[:delay],
          source: retry_delay_source(retry_delay),
          next_attempt: attempt + 1,
          max_attempts: MAX_TRANSIENT_RETRIES + 1,
          model: model
        )
      )
      sleep_started_at = monotonic_time
      sleep(retry_delay[:delay])
      log_retry_wait_completed(stage, model, monotonic_time - sleep_started_at)
    end

    def log_retry_wait_completed(stage, model, waited)
      @logger.info(
        format(
          'LLM %<stage>s retry wait completed after %<waited>.1fs (model=%<model>s)',
          stage: stage,
          waited: waited,
          model: model
        )
      )
    end

    def ruby_llm_api_error?(error)
      defined?(RubyLLM::Error) && error.is_a?(RubyLLM::Error)
    end

    def transient_llm_error?(error)
      error.is_a?(RubyLLM::RateLimitError) ||
        error.is_a?(RubyLLM::ServiceUnavailableError) ||
        error.is_a?(RubyLLM::OverloadedError)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def transient_retry_delay(error:, attempt:)
      provider_delay = retry_after_seconds(error.message)
      if provider_delay
        multiplier = rand(PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE)
        return {
          delay: provider_delay * multiplier,
          provider_delay: provider_delay,
          multiplier: multiplier,
          strategy: :provider_hint
        }
      end

      if overloaded_llm_error?(error)
        return {
          delay: rand(OVERLOADED_RETRY_DELAY_RANGE),
          provider_delay: nil,
          multiplier: nil,
          strategy: :overloaded
        }
      end

      base_delay = TRANSIENT_RETRY_BASE_DELAY * (2**(attempt - 1))
      {
        delay: base_delay + rand(TRANSIENT_RETRY_JITTER_RANGE),
        provider_delay: nil,
        multiplier: nil,
        strategy: :fallback
      }
    end

    def retry_delay_source(retry_delay)
      return ' (overloaded backoff)' if retry_delay[:strategy] == :overloaded
      return '' unless retry_delay[:provider_delay]

      format(
        ' (provider retry hint %<provider_delay>.1fs, multiplier %<multiplier>.2fx)',
        provider_delay: retry_delay[:provider_delay],
        multiplier: retry_delay[:multiplier]
      )
    end

    def overloaded_llm_error?(error)
      error.is_a?(RubyLLM::ServiceUnavailableError) ||
        error.is_a?(RubyLLM::OverloadedError)
    end

    def retry_after_seconds(message)
      match = message.to_s.match(/retry\s+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b/i)
      match[1].to_f if match
    end

    def llm_error_message(error)
      case error
      when RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
        "LLM service is temporarily unavailable or overloaded: #{error.message}. " \
        "Try again later or switch model via --generate-model/--critique-model."
      when RubyLLM::RateLimitError
        "LLM rate limit exceeded: #{error.message}. " \
        "Try again later or switch model via --generate-model/--critique-model."
      when RubyLLM::ContextLengthExceededError
        "LLM context limit exceeded: #{error.message}. Try reducing the MR diff or ignore more paths."
      else
        "LLM API request failed: #{error.message}"
      end
    end

    def llm_context(stage, provider)
      @llm_contexts[stage] ||= build_llm_context(provider.to_s)
    end

    def build_llm_context(provider)
      api_key = @config.provider_api_key(provider) unless provider == 'ollama'

      RubyLLM.context do |ruby_config|
        configure_http_proxy(ruby_config)
        ruby_config.request_timeout = @config.llm_timeout.to_f
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
