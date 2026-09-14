# frozen_string_literal: true
require 'json'
require 'timeout'

module Aireview
  # Классификация ошибки LLM-запроса. Отвечает только на вопрос «что это»,
  # решение «повторить, сменить ключ или модель» принимает LlmRouter.
  #
  # :daily_quota — суточная квота проекта на модель, повторы бесполезны;
  # :rate_limit  — минутный лимит, пройдёт через подсказанное время;
  # :overloaded  — 503/«high demand» у модели;
  # :timeout     — ответа нет дольше LLM_TIMEOUT;
  # :fatal       — ошибка API, которую резервы не лечат;
  # :unhandled   — не ошибка провайдера, пробрасывается как есть.
  module LlmFailure
    KINDS = %i[daily_quota rate_limit overloaded timeout fatal unhandled].freeze
    QUOTA_FAILURE_TYPE = 'type.googleapis.com/google.rpc.QuotaFailure'
    DAILY_QUOTA_ID = /PerDay/i
    DAILY_QUOTA_TEXT = /\bper\s+day\b|\bdaily\b/i
    RETRY_AFTER = /retry\s+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b/i

    module_function

    # Сведения о квоте смотрим раньше класса исключения: RubyLLM превращает
    # 429 со словом input_token в ContextLengthExceededError, хотя это
    # исчерпанная токенная квота, а не слишком длинный запрос.
    def classify(error)
      return :timeout if transport_timeout?(error)
      return :unhandled unless ruby_llm_error?(error)

      quota_kind(error) || (overloaded?(error) ? :overloaded : :fatal)
    end

    # Внешний Timeout.timeout и таймауты транспорта Faraday: последние не
    # наследуют ни Timeout::Error, ни RubyLLM::Error.
    def transport_timeout?(error)
      return true if error.is_a?(Timeout::Error) || error.is_a?(Errno::ETIMEDOUT)

      defined?(Faraday::TimeoutError) && error.is_a?(Faraday::TimeoutError)
    end

    def overloaded?(error)
      error.is_a?(RubyLLM::ServiceUnavailableError) || error.is_a?(RubyLLM::OverloadedError)
    end

    def ruby_llm_error?(error)
      defined?(RubyLLM::Error) && error.is_a?(RubyLLM::Error)
    end

    # Google кладёт вид квоты в QuotaFailure.violations[].quotaId
    # (GenerateRequestsPerDay… / …PerMinute…). Метрика free_tier_requests
    # одна и та же у обоих, по ней не различить. Текст сообщения — запасной
    # признак, когда тела ответа нет.
    def quota_kind(error)
      ids = quota_ids(error)
      return daily_quota_id?(ids) ? :daily_quota : :rate_limit unless ids.empty?
      return unless error.is_a?(RubyLLM::RateLimitError)

      error.message.to_s.match?(DAILY_QUOTA_TEXT) ? :daily_quota : :rate_limit
    end

    def daily_quota_id?(ids)
      ids.any? { |id| id.match?(DAILY_QUOTA_ID) }
    end

    def quota_ids(error)
      body = response_body(error)
      details = body.is_a?(Hash) ? Array(body.dig('error', 'details')) : []
      details.flat_map do |detail|
        next [] unless detail.is_a?(Hash) && detail['@type'] == QUOTA_FAILURE_TYPE

        Array(detail['violations']).filter_map { |violation| violation['quotaId'] if violation.is_a?(Hash) }
      end
    end

    def response_body(error)
      body = error.respond_to?(:response) && error.response.respond_to?(:body) ? error.response.body : nil
      return body unless body.is_a?(String)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def retry_after_seconds(message)
      match = message.to_s.match(RETRY_AFTER)
      match[1].to_f if match
    end
  end
end
