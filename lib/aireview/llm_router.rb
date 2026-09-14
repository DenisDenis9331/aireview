# frozen_string_literal: true
require 'set'
require_relative 'errors'
require_relative 'llm_failure'

module Aireview
  # Обход цепочки моделей и ключей стадии. Перегрузка — свойство модели,
  # квота — свойство «ключ + модель», поэтому по 503 меняется модель, по
  # квоте — ключ. Всё вместе ограничено общим бюджетом времени прогона.
  class LlmRouter
    Route = Struct.new(:candidate, :candidate_index, :key, :key_index, :key_count, keyword_init: true) do
      def fallback?
        candidate_index.positive?
      end

      def to_s
        key_count > 1 ? "#{candidate} (key #{key_index + 1}/#{key_count})" : candidate.to_s
      end
    end

    Attempt = Struct.new(:route, :kind, :attempts, :error, :note, keyword_init: true) do
      def to_s
        "#{route}: #{note || "#{LlmRouter::KIND_LABELS.fetch(kind)} after #{attempts} attempt(s)"}"
      end
    end

    KIND_LABELS = {
      daily_quota: 'daily quota exhausted',
      rate_limit: 'rate limited',
      overloaded: 'overloaded',
      timeout: 'timed out'
    }.freeze
    SWITCH_HINT = 'Try again later or switch model via --generate-model/--critique-model.'

    # Пока есть куда переключиться, модели дают один короткий повтор; полное
    # расписание получает только последний маршрут стадии.
    SHORT_RETRY_DELAY = 30.0
    SHORT_RETRY_JITTER_RANGE = 0.85..1.15
    MAX_RATE_LIMIT_RETRIES = 3
    RATE_LIMIT_BASE_DELAY = 2.0
    RATE_LIMIT_JITTER_RANGE = 2.0..5.0
    PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE = 2.0..2.4
    OVERLOADED_RETRY_DELAYS = [120.0, 300.0, 300.0, 300.0].freeze
    OVERLOADED_RETRY_JITTER_RANGE = 0.85..1.15
    RETRY_WAIT_LOG_FORMAT = 'LLM %<stage>s request will sleep %<delay>.1fs before retry%<source>s ' \
                            '(attempt %<next_attempt>d/%<max_attempts>d, model=%<model>s)'

    def initialize(config:, logger:)
      @config = config
      @logger = logger
      @exhausted = Set.new
      @cursor = {}
      @used = {}
      @deadline = nil
    end

    # Блок получает маршрут и таймаут запроса, делает запрос и возвращает
    # ответ. Ошибка блока классифицируется, дальше — повтор, другой ключ,
    # другая модель или ApiError, когда маршруты кончились.
    def call(stage:, request_chars:, &request)
      @deadline ||= monotonic_time + @config.llm_time_budget
      attempts = []
      chain = ordered_chain(stage).reject do |candidate, index|
        oversized?(stage, candidate, index, request_chars, attempts)
      end
      carried = nil
      chain.each_with_index do |(candidate, index), position|
        slot = {candidate: candidate, index: index, last_model: position == chain.size - 1}
        status, value = try_candidate(stage, slot, attempts, carried, &request)
        return value if status == :ok

        carried = value
      end

      raise ApiError, exhausted_message(stage, attempts)
    end

    # Стадии, ответившие не основной моделью: для строки в отчёте.
    def fallback_models
      @used.select { |_, route| route.fallback? }.transform_values { |route| route.candidate.to_s }
    end

    def remaining_time
      @deadline ? @deadline - monotonic_time : @config.llm_time_budget.to_f
    end

    private

    # При :next_model отдаёт текущий ключ: перегрузка — свойство модели, и
    # следующая модель того же провайдера продолжает с того же ключа, а не
    # возвращается к первому, у которого квота могла уже кончиться.
    def try_candidate(stage, slot, attempts, carried, &request)
      routes = candidate_routes(stage, slot, carried)
      routes.each_with_index do |route, position|
        next if quota_exhausted?(stage, route, attempts)

        log_switch(stage, route, attempts)
        status, response = try_route(stage, route, attempts,
                                     {last_model: slot[:last_model], last_key: position == routes.size - 1}, &request)
        return [:ok, remember(stage, route, response)] if status == :ok
        return [:next_model, {provider: route.candidate.provider, key_index: route.key_index}] if status == :next_model
      end
      [:next_model, carried]
    end

    # Следующий запрос стадии (например, починка JSON) начинается с модели,
    # которая ответила; остальные остаются в резерве после неё.
    def ordered_chain(stage)
      start_candidate, = @cursor.fetch(stage, [0, 0])
      @config.stage_chain(stage).each_with_index.to_a.rotate(start_candidate)
    end

    # Ключи начинаются с перенесённого (после перегрузки — текущий ключ,
    # после ответа — ответивший), остальные идут следом: квота привязана к
    # сочетанию «ключ + модель», ошибка на одной модели не списывает ключ
    # для другой.
    def candidate_routes(stage, slot, carried)
      candidate = slot[:candidate]
      keys = @config.provider_api_keys(candidate.provider)
      routes = keys.each_with_index.map do |key, key_index|
        Route.new(candidate: candidate, candidate_index: slot[:index], key: key,
                  key_index: key_index, key_count: keys.size)
      end
      routes.rotate(start_key(stage, slot, carried))
    end

    def start_key(stage, slot, carried)
      return carried[:key_index] if carried && carried[:provider] == slot[:candidate].provider

      cursor_candidate, cursor_key = @cursor.fetch(stage, [0, 0])
      cursor_candidate == slot[:index] ? cursor_key : 0
    end

    def try_route(stage, route, attempts, position)
      attempt = 0
      loop do
        attempt += 1
        ensure_time_left!(stage, route, attempts)
        begin
          return [:ok, yield(route, request_timeout)]
        rescue StandardError => e
          kind = LlmFailure.classify(e)
          raise if kind == :unhandled

          @logger.warn("LLM #{stage} request failed (#{route}): #{e.class}: #{e.message}")
          decision, delay = decide(kind, attempt, position, e)
          raise ApiError, single_route_message(e) if decision == :fail

          if decision == :retry
            next if waited_before_retry?(stage, route, delay, attempt)

            decision = give_up(kind)
          end
          @exhausted << exhausted_key(route) if kind == :daily_quota
          attempts << Attempt.new(route: route, kind: kind, attempts: attempt, error: e)
          return [decision, nil]
        end
      end
    end

    # :retry с паузой, :next_key, :next_model или :fail.
    def decide(kind, attempt, position, error)
      case kind
      when :fatal then [:fail]
      when :daily_quota then [:next_key]
      when :rate_limit then rate_limit_decision(attempt, position, error)
      else overloaded_decision(attempt, position)
      end
    end

    def overloaded_decision(attempt, position)
      unless position[:last_model]
        return [:retry, short_delay.merge(max_attempts: 2)] if attempt == 1

        return [:next_model]
      end
      return [:next_model] if attempt > OVERLOADED_RETRY_DELAYS.size

      [:retry, overloaded_delay(attempt)]
    end

    def rate_limit_decision(attempt, position, error)
      max_retries = position[:last_model] && position[:last_key] ? MAX_RATE_LIMIT_RETRIES : 1
      return [:next_key] if attempt > max_retries

      [:retry, rate_limit_delay(attempt, error).merge(max_attempts: max_retries + 1)]
    end

    def give_up(kind)
      %i[overloaded timeout].include?(kind) ? :next_model : :next_key
    end

    def short_delay
      {delay: SHORT_RETRY_DELAY * rand(SHORT_RETRY_JITTER_RANGE)}
    end

    def overloaded_delay(attempt)
      base_delay = OVERLOADED_RETRY_DELAYS.fetch(attempt - 1, OVERLOADED_RETRY_DELAYS.last)
      multiplier = rand(OVERLOADED_RETRY_JITTER_RANGE)
      {
        delay: base_delay * multiplier,
        source: format(' (overloaded backoff %<base>.0fs, multiplier %<multiplier>.2fx)',
                       base: base_delay, multiplier: multiplier),
        max_attempts: OVERLOADED_RETRY_DELAYS.size + 1
      }
    end

    def rate_limit_delay(attempt, error)
      hint = LlmFailure.retry_after_seconds(error.message)
      return {delay: (RATE_LIMIT_BASE_DELAY * (2**(attempt - 1))) + rand(RATE_LIMIT_JITTER_RANGE)} unless hint

      multiplier = rand(PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE)
      {
        delay: hint * multiplier,
        source: format(' (provider retry hint %<hint>.1fs, multiplier %<multiplier>.2fx)',
                       hint: hint, multiplier: multiplier)
      }
    end

    # false — пауза не помещается в бюджет времени, повтора не будет.
    def waited_before_retry?(stage, route, retry_delay, attempt)
      delay = retry_delay[:delay]
      if delay > remaining_time
        @logger.warn(
          format('LLM %<stage>s: no time budget left for a %<delay>.0fs pause (%<left>.0fs remaining, %<route>s)',
                 stage: stage, delay: delay, left: [remaining_time, 0].max, route: route)
        )
        return false
      end

      @logger.warn(
        format(RETRY_WAIT_LOG_FORMAT, stage: stage, delay: delay, source: retry_delay[:source].to_s,
                                      next_attempt: attempt + 1, max_attempts: retry_delay[:max_attempts] || 2,
                                      model: route.candidate.model)
      )
      started_at = monotonic_time
      sleep(delay)
      @logger.info(format('LLM %<stage>s retry wait completed after %<waited>.1fs (model=%<model>s)',
                          stage: stage, waited: monotonic_time - started_at, model: route.candidate.model))
      true
    end

    def ensure_time_left!(stage, route, attempts)
      return if remaining_time >= 1

      attempts << Attempt.new(route: route, note: 'no time budget left')
      raise ApiError, "LLM time budget of #{@config.llm_time_budget}s is exhausted. " \
                      "#{exhausted_message(stage, attempts)}"
    end

    def request_timeout
      [@config.llm_timeout.to_f, remaining_time].min
    end

    def oversized?(stage, candidate, index, request_chars, attempts)
      return false if request_chars <= candidate.max_prompt_chars

      note = "skipped, request #{request_chars} chars over max_prompt_chars=#{candidate.max_prompt_chars}"
      @logger.warn("LLM #{stage}: #{candidate} #{note}")
      attempts << Attempt.new(route: Route.new(candidate: candidate, candidate_index: index, key_count: 1), note: note)
      true
    end

    def quota_exhausted?(stage, route, attempts)
      return false unless @exhausted.include?(exhausted_key(route))

      @logger.info("LLM #{stage}: skipping #{route}, daily quota exhausted earlier in this run")
      attempts << Attempt.new(route: route, note: 'daily quota exhausted earlier in this run')
      true
    end

    def remember(stage, route, response)
      @cursor[stage] = [route.candidate_index, route.key_index]
      @used[stage] = route
      response
    end

    def exhausted_key(route)
      [route.candidate.provider, route.key_index, route.candidate.model]
    end

    def log_switch(stage, route, attempts)
      return if attempts.empty?

      @logger.warn("LLM #{stage}: switching to #{route} after #{attempts.last}")
    end

    def exhausted_message(stage, attempts)
      single = attempts.size == 1 && attempts.first.error
      return single_route_message(attempts.first.error) if single

      "LLM #{stage} request failed on every configured route: #{attempts.join('; ')}. #{SWITCH_HINT}"
    end

    def single_route_message(error)
      case LlmFailure.classify(error)
      when :timeout
        "LLM request timed out after #{@config.llm_timeout} seconds. #{SWITCH_HINT}"
      when :overloaded
        "LLM service is temporarily unavailable or overloaded: #{error.message}. #{SWITCH_HINT}"
      when :rate_limit, :daily_quota
        "LLM rate limit exceeded: #{error.message}. #{SWITCH_HINT}"
      else
        fatal_message(error)
      end
    end

    def fatal_message(error)
      if defined?(RubyLLM::ContextLengthExceededError) && error.is_a?(RubyLLM::ContextLengthExceededError)
        "LLM context limit exceeded: #{error.message}. Try reducing the MR diff or ignore more paths."
      else
        "LLM API request failed: #{error.message}"
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
