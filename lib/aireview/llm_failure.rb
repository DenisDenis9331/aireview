# frozen_string_literal: true
require 'json'
require 'timeout'

module Aireview
  # Classifies an LLM request error. Answers only "what is it"; the decision
  # to retry, switch the key or the model belongs to LlmRouter.
  #
  # :daily_quota — the project's daily quota for the model, retries are useless;
  # :rate_limit  — a per-minute limit, passes after the hinted time;
  # :overloaded  — 503 / "high demand" on the model;
  # :timeout     — no answer for longer than LLM_TIMEOUT;
  # :unavailable — the provider has no such model: retired, a typo, not pulled into Ollama;
  # :fatal       — an API error that reserves do not cure;
  # :unhandled   — not a provider error, re-raised as is.
  module LlmFailure
    KINDS = %i[daily_quota rate_limit overloaded timeout unavailable fatal unhandled].freeze
    # Only by the provider's text about the model: a bare 404 is also what a
    # wrong LLM_API_BASE or proxy answers, and the next model will not help.
    # Ollama: `model 'x' not found` (through /v1) and `model "x" not found,
    # try pulling it first` (older versions and /api).
    UNAVAILABLE_MODEL_TEXT = Regexp.union(
      /\bmodels?\/[\w.:-]+ is not found\b/i,
      /\bis not supported for generateContent\b/i,
      /\bmodel ['"][^'"]+['"] not found\b/i
    )
    QUOTA_FAILURE_TYPE = 'type.googleapis.com/google.rpc.QuotaFailure'
    DAILY_QUOTA_ID = /PerDay/i
    DAILY_QUOTA_TEXT = /\bper\s+day\b|\bdaily\b/i
    RETRY_AFTER = /retry\s+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b/i

    module_function

    # Quota details are checked before the exception class: RubyLLM turns a
    # 429 mentioning input_token into ContextLengthExceededError, although
    # it is an exhausted token quota, not an oversized request.
    def classify(error)
      return :timeout if transport_timeout?(error)
      return :unhandled unless ruby_llm_error?(error)

      quota_kind(error) || model_kind(error) || (overloaded?(error) ? :overloaded : :fatal)
    end

    def model_kind(error)
      :unavailable if error.message.to_s.match?(UNAVAILABLE_MODEL_TEXT)
    end

    # The outer Timeout.timeout and Faraday's transport timeouts: the latter
    # inherit neither Timeout::Error nor RubyLLM::Error.
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

    # Google puts the kind of quota into QuotaFailure.violations[].quotaId
    # (GenerateRequestsPerDay… / …PerMinute…). The free_tier_requests metric
    # is the same for both, it cannot tell them apart. The message text is
    # the fallback signal when there is no response body.
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

    private_class_method :model_kind, :transport_timeout?, :overloaded?, :ruby_llm_error?, :quota_kind,
                         :daily_quota_id?, :quota_ids, :response_body
  end
end
