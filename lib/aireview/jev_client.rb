# frozen_string_literal: true
require 'json'
require 'logger'
require_relative 'errors'
require_relative 'utils'

module Aireview
  # One evaluation request to Jev (TypeSafe, POST /v1/systemone): a state and
  # named questions in, one answer per question out. RubyLLM does not know
  # Jev and the router is built for text models, so Jev has its own small
  # client: one retry on 429/529, no key rotation, no reserves. A failure is
  # a JevError; the caller decides whether it matters.
  class JevClient
    API_URL = 'https://api.typesafe.ai/v1/'
    OPEN_TIMEOUT = 5
    RETRY_STATUSES = [429, 529].freeze
    RETRY_DELAY = 2
    # retry-after beyond this is not worth waiting for in a review job.
    MAX_RETRY_DELAY = 10

    Result = Struct.new(:model, :answers, :usage, keyword_init: true)

    # Jev goes out the same way as the LLM providers, through
    # LLM_HTTP_PROXY when it is set. dependencies — connection: and sleeper:
    # for tests.
    def initialize(config:, logger: Logger.new($stderr), **dependencies)
      require 'faraday'

      raise ConfigError, 'JEV_API_KEY is required' if Aireview::Utils.blank?(config.jev_api_key)

      @api_key = config.jev_api_key
      @model = config.jev_model
      @logger = logger
      @connection = dependencies[:connection] || build_connection(config.jev_timeout, config.llm_http_proxy)
      @sleeper = dependencies[:sleeper] || ->(seconds) { sleep(seconds) }
    end

    # questions — {key => question}; returns Result with answers under the
    # same keys, each checked against the type of its question.
    def evaluate(state:, questions:)
      body = JSON.generate(model: @model, state: state, questions: questions)
      @logger.info("Jev request started (model=#{@model}, questions=#{questions.size})")
      response = post_with_one_retry(body)
      result = parse(response, questions)
      log_completed(result)
      result
    end

    private

    def build_connection(timeout, proxy)
      Faraday.new(url: API_URL, proxy: Aireview::Utils.presence(proxy)) do |builder|
        builder.options.open_timeout = OPEN_TIMEOUT
        builder.options.timeout = timeout
        builder.adapter Faraday.default_adapter
      end
    end

    def post_with_one_retry(body)
      response = post(body)
      return response unless RETRY_STATUSES.include?(response.status.to_i)

      delay = retry_delay(response)
      @logger.warn("Jev answered #{response.status}, retrying once in #{delay}s")
      @sleeper.call(delay)
      post(body)
    end

    def post(body)
      @connection.post('systemone') do |request|
        request.headers['Authorization'] = "Bearer #{@api_key}"
        request.headers['Content-Type'] = 'application/json'
        request.body = body
      end
    rescue Faraday::Error => e
      raise JevError, "Jev request failed: #{e.class}: #{e.message}"
    end

    def retry_delay(response)
      seconds = Integer(response.headers['retry-after'].to_s, exception: false)
      seconds&.positive? ? [seconds, MAX_RETRY_DELAY].min : RETRY_DELAY
    end

    def parse(response, questions)
      status = response.status.to_i
      unless status.between?(200, 299)
        raise JevError.new("Jev API error #{status}: #{response.body.to_s[0, 500]}", status: status)
      end

      payload = JSON.parse(response.body.to_s)
      answers = payload['answers'] if payload.is_a?(Hash)
      raise JevError, 'Jev returned no answers' unless answers.is_a?(Hash)

      questions.each { |key, question| check_answer!(key, question, answers[key.to_s]) }
      Result.new(model: payload['model'], answers: answers, usage: payload['usage'])
    rescue JSON::ParserError
      raise JevError, "Jev returned invalid JSON: #{response.body.to_s[0, 500]}"
    end

    def check_answer!(key, question, answer)
      type = question[:type] || question['type']
      return if answer.is_a?(Hash) && answer['type'] == type && valid_value?(type, answer)

      raise JevError, "Jev returned an invalid #{type} answer for #{key}: #{answer.inspect}"
    end

    def valid_value?(type, answer)
      case type
      when 'noul' then probability?(answer['noul'])
      when 'choice' then answer['choice'].is_a?(String) && probability?(answer['confidence'])
      else true
      end
    end

    def probability?(value)
      value.is_a?(Numeric) && value.between?(0, 1)
    end

    # The answering version is logged: an alias resolves on the server, and
    # a pinned version that answers as another one breaks the thresholds.
    def log_completed(result)
      tokens = result.usage.is_a?(Hash) ? ", tokens: input=#{result.usage['input_tokens']}" : ''
      @logger.info("Jev request completed (model=#{result.model}#{tokens})")
      return if result.model == @model || !@model.match?(/\Ajev-\d/)

      @logger.warn("Jev answered as #{result.model.inspect}, not the requested #{@model}")
    end
  end
end
