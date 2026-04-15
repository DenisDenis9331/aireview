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

    def initialize(config:, logger: Logger.new($stderr))
      @config = config
      @logger = logger
      @ruby_llm_configured = false
    end

    def generate(system_prompt:, user_prompt:)
      call_llm(
        stage: 'generate',
        system: system_prompt,
        user: user_prompt,
        model: @config.generate_model,
        temperature: @config.generate_temperature
      )
    end

    def critique(system_prompt:, user_prompt:)
      call_llm(
        stage: 'critique',
        system: system_prompt,
        user: user_prompt,
        model: @config.critique_model,
        temperature: @config.critique_temperature
      )
    end

    private

    def call_llm(stage:, system:, user:, model:, temperature:)
      require 'ruby_llm'

      @config.require_llm_configuration!
      configure_ruby_llm

      attempt = 0

      begin
        attempt += 1
        @logger.info("LLM #{stage} request started (model=#{model}, temperature=#{temperature})")
        chat = RubyLLM.chat(model: model).with_temperature(temperature.to_f)
        chat.with_instructions(system)
        response = Timeout.timeout(@config.llm_timeout.to_f) { chat.ask(user) }
        @logger.info("LLM #{stage} request completed (model=#{model})")
        response.content
      rescue StandardError => e
        raise unless ruby_llm_api_error?(e)

        @logger.warn("LLM #{stage} request failed (model=#{model}): #{e.class}: #{e.message}")

        if transient_llm_error?(e) && attempt <= MAX_TRANSIENT_RETRIES
          retry_delay = transient_retry_delay(error: e, attempt: attempt)
          @logger.warn(
            format(
              'LLM %<stage>s request will sleep %<delay>.1fs before retry%<source>s (attempt %<next_attempt>d/%<max_attempts>d, model=%<model>s)',
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
          waited = monotonic_time - sleep_started_at
          @logger.info(
            format(
              'LLM %<stage>s retry wait completed after %<waited>.1fs (model=%<model>s)',
              stage: stage,
              waited: waited,
              model: model
            )
          )
          retry
        end

        raise ApiError, llm_error_message(e)
      end
    rescue LoadError => e
      @logger.error("LLM #{stage} setup failed: #{e.message}")
      raise ConfigError, "Missing dependency: #{e.message}"
    rescue Timeout::Error
      @logger.warn("LLM #{stage} request timed out after #{@config.llm_timeout} seconds (model=#{model})")
      raise ApiError, "LLM request timed out after #{@config.llm_timeout} seconds. " \
                      "Try again later or switch model via --generate-model/--critique-model."
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

    def configure_ruby_llm
      return if @ruby_llm_configured

      provider = @config.llm_provider.to_s
      api_key = @config.provider_api_key(provider)

      RubyLLM.configure do |config|
        config.http_proxy = @config.llm_http_proxy if Aireview::Utils.present?(@config.llm_http_proxy)

        case provider
        when 'gemini'
          config.gemini_api_key = api_key
          config.gemini_api_base = @config.llm_api_base if Aireview::Utils.present?(@config.llm_api_base)
        when 'openai'
          config.openai_api_key = api_key
          config.openai_api_base = @config.llm_api_base if Aireview::Utils.present?(@config.llm_api_base)
        when 'openrouter'
          config.openrouter_api_key = api_key
          config.openrouter_api_base = @config.llm_api_base if Aireview::Utils.present?(@config.llm_api_base)
        when 'anthropic'
          config.anthropic_api_key = api_key
        when 'ollama'
          config.openai_api_key = api_key || 'ollama'
          config.openai_api_base = @config.llm_api_base || 'http://localhost:11434/v1'
          config.openai_use_system_role = true
        else
          raise ConfigError, "Unsupported LLM provider: #{provider.inspect}"
        end
      end

      @ruby_llm_configured = true
    end
  end
end
