# frozen_string_literal: true
require 'set'
require_relative 'errors'
require_relative 'llm_failure'
require_relative 'model_state'

module Aireview
  # Обход пула моделей и ключей стадии. Перегрузка — свойство модели,
  # квота — свойство «ключ + модель», поэтому по 503 меняется модель, по
  # квоте — ключ. Перегруженная модель уходит в карантин и пропускается,
  # пока он не истёк; когда цепочка пройдена, обход идёт по кругу по
  # моделям с истёкшим карантином. Ограничители: общий бюджет времени
  # прогона и предел отправленных запросов на модель в стадии (ModelState).
  class LlmRouter # rubocop:disable Metrics/ClassLength
    Route = Struct.new(:candidate, :candidate_index, :key, :key_index, :key_count, keyword_init: true) do
      def fallback?
        candidate_index.positive?
      end

      def to_s
        key_count > 1 ? "#{candidate} (key #{key_index + 1}/#{key_count})" : candidate.to_s
      end
    end

    # Запись журнала визита к маршруту — для сообщения об ошибке: либо вид
    # отказа с числом запросов, либо заметка, почему маршрут пропущен.
    Visit = Struct.new(:route, :kind, :tries, :error, :note, keyword_init: true) do
      def to_s
        "#{route}: #{note || "#{LlmRouter::KIND_LABELS.fetch(kind)} after #{tries} attempt(s)"}"
      end
    end

    Slot = Struct.new(:candidate, :index)
    # Ключ, с которого следующая модель того же провайдера продолжает обход.
    Carry = Struct.new(:provider, :key_index)
    Delay = Struct.new(:seconds, :source)

    SWITCH_HINT = 'Try again later or switch model via --generate-model/--critique-model.'

    KIND_LABELS = {
      daily_quota: 'daily quota exhausted',
      rate_limit: 'rate limited',
      overloaded: 'overloaded',
      timeout: 'timed out',
      unavailable: 'model unavailable'
    }.freeze

    MAX_ATTEMPTS_PER_MODEL = ModelState::MAX_REQUESTS_PER_STAGE
    # Первая неудача за визит к модели даёт один короткий повтор, вторая —
    # карантин и переход к следующей модели.
    SHORT_RETRY_DELAY = 30.0
    SHORT_RETRY_JITTER_RANGE = 0.85..1.15
    RATE_LIMIT_BASE_DELAY = 2.0
    RATE_LIMIT_JITTER_RANGE = 2.0..5.0
    PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE = 2.0..2.4
    RETRY_WAIT_LOG_FORMAT = 'LLM %<stage>s request will sleep %<delay>.1fs before retry%<source>s ' \
                            '(request %<next_request>d/%<max_requests>d of the model in this stage, model=%<model>s)'

    # clock и sleeper подменяются в тестах: расписание проверяется без
    # реальных ожиданий.
    def initialize(config:, logger:, routing: nil, clock: nil, sleeper: nil)
      @config = config
      @routing = routing || config.routing
      @logger = logger
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @models = Hash.new { |states, name| states[name] = ModelState.new }
      @cursor = {}
      @used = {}
      @deadline = nil
    end

    # Блок получает маршрут и таймаут запроса, делает запрос и возвращает
    # ответ. Ошибка блока классифицируется, дальше — повтор, другой ключ,
    # другая модель или ApiError, когда маршруты кончились. pinned — только
    # модель, ответившая в этой стадии последней (починка JSON): её отказ —
    # RouteExhaustedError, стадия перезапускается на другой модели.
    def call(stage:, request_chars:, pinned: false, &request)
      @deadline ||= now + @config.llm_time_budget
      visits = []
      noted = Set.new
      carry = nil
      loop do
        slots = available_slots(stage, request_chars, pinned, visits, noted)
        slot = slots.empty? ? nil : ready_slot(stage, slots, visits)
        raise exhausted_error(stage, visits, pinned) unless slot

        status, value = try_candidate(stage, slot, visits, carry, &request)
        return value if status == :ok

        carry = value
      end
    end

    # Стадии, ответившие не основной моделью: для строки в отчёте.
    def fallback_models
      @used.select { |_, route| route.fallback? }.transform_values { |route| route.candidate.to_s }
    end

    # Модель, ответившая в стадии последней, и её место в цепочке.
    def answered(stage)
      route = @used[stage.to_s]
      return nil unless route

      "#{route.candidate} (#{route.candidate_index + 1}/#{chain_for(stage.to_s).size})"
    end

    # Критика ответила моделью ниже generate по пулу — для строки в отчёте.
    def critique_weaker?
      generate = @used['generate']
      critique = @used['critique']
      return false unless generate && critique

      @routing.weaker?(critique.candidate, generate.candidate)
    end

    # Исключает ответившую модель до конца стадии: результат от неё негоден
    # (не JSON, не та схема) и после починки тоже. Следующий запрос стадии
    # уйдёт другой модели. Возвращает исключённую модель; nil — исключать нечего.
    def exclude_answered(stage:, reason:)
      route = @used[stage.to_s]
      return nil unless route

      state(route.candidate).exclude_for_stage(stage, reason)
      @logger.warn("LLM #{stage}: #{route.candidate} excluded for this stage: #{reason}")
      route.candidate
    end

    def remaining_time
      @deadline ? @deadline - now : @config.llm_time_budget.to_f
    end

    private

    def state(candidate)
      @models[candidate.to_s]
    end

    # Модели, которые ещё можно пробовать, в порядке обхода. Пропущенная
    # модель попадает в журнал один раз за вызов, и только если её там ещё
    # нет с ошибкой этого же вызова.
    def available_slots(stage, request_chars, pinned, visits, noted)
      chain = pinned ? pinned_chain(stage) : ordered_chain(stage)
      chain.filter_map do |candidate, index|
        note = skip_reason(stage, candidate, request_chars)
        next Slot.new(candidate, index) unless note

        note_skip(visits, noted, candidate, index, note)
        nil
      end
    end

    def note_skip(visits, noted, candidate, index, note)
      return unless noted.add?([index, note])
      return if visits.any? { |visit| visit.error && visit.route.candidate == candidate }

      visits << Visit.new(route: bare_route(candidate, index), note: note)
    end

    def bare_route(candidate, index)
      Route.new(candidate: candidate, candidate_index: index, key_count: 1)
    end

    def skip_reason(stage, candidate, request_chars)
      if request_chars > candidate.max_prompt_chars
        "skipped, request #{request_chars} chars over max_prompt_chars=#{candidate.max_prompt_chars}"
      else
        state(candidate).skip_reason(stage)
      end
    end

    # Первая модель без карантина; если все в карантине — ждём ближайшего
    # освобождения, когда это помещается в бюджет. nil — не помещается.
    def ready_slot(stage, slots, visits)
      ensure_time_left!(stage, bare_route(slots.first.candidate, slots.first.index), visits)
      moment = now
      ready = slots.find { |slot| state(slot.candidate).quarantine_left(moment) <= 0 }
      return ready if ready

      slot = slots.min_by { |item| state(item.candidate).quarantine_left(moment) }
      wait = state(slot.candidate).quarantine_left(moment)
      if wait > remaining_time
        visits << Visit.new(route: bare_route(slot.candidate, slot.index),
                            note: format('quarantined for another %.0fs, over the time budget', wait))
        return nil
      end

      @logger.warn(format('LLM %<stage>s: every model is quarantined, waiting %<wait>.0fs for %<model>s',
                          stage: stage, wait: wait, model: slot.candidate))
      pause(wait)
      slot
    end

    # При :next_model отдаёт текущий ключ: перегрузка — свойство модели, и
    # следующая модель того же провайдера продолжает с того же ключа, а не
    # возвращается к первому, у которого квота могла уже кончиться.
    #
    # Каждый визит либо отправляет запрос, либо исключает модель: иначе обход
    # по кругу не остановится. Модель, у которой все ключи выбыли по суточной
    # квоте, исключается до конца прогона.
    def try_candidate(stage, slot, visits, carry, &request)
      routes = candidate_routes(stage, slot, carry)
      tried = false
      routes.each do |route|
        next if quota_exhausted?(stage, route, visits)

        tried = true
        log_switch(stage, route, visits)
        status, response = try_route(stage, route, visits, &request)
        return [:ok, remember(stage, route, response)] if status == :ok
        return [:next_model, Carry.new(route.candidate.provider, route.key_index)] if status == :next_model
      end
      state(slot.candidate).exclude('daily quota exhausted on every key') unless tried
      [:next_model, carry]
    end

    # Ключи начинаются с перенесённого (после перегрузки — текущий ключ,
    # после ответа — ответивший), остальные идут следом: квота привязана к
    # сочетанию «ключ + модель», ошибка на одной модели не списывает ключ
    # для другой.
    def candidate_routes(stage, slot, carry)
      keys = @config.provider_api_keys(slot.candidate.provider)
      routes = keys.each_with_index.map do |key, key_index|
        Route.new(candidate: slot.candidate, candidate_index: slot.index, key: key,
                  key_index: key_index, key_count: keys.size)
      end
      routes.rotate(start_key(stage, slot, carry))
    end

    def start_key(stage, slot, carry)
      return carry.key_index if carry && carry.provider == slot.candidate.provider

      cursor_candidate, cursor_key = @cursor.fetch(stage, [0, 0])
      cursor_candidate == slot.index ? cursor_key : 0
    end

    # Визит к маршруту: запросы до ответа, повтора или отказа. try — номер
    # запроса в этом визите, счётчик модели на стадию ведёт ModelState.
    def try_route(stage, route, visits)
      model = state(route.candidate)
      try = 0
      loop do
        return [:next_model, nil] unless requests_left?(stage, route)

        try += 1
        ensure_time_left!(stage, route, visits)
        model.record_request(stage)
        begin
          return [:ok, yield(route, request_timeout)]
        rescue StandardError => e
          decision = handle_failure(stage, route, try, e, visits)
          return [decision, nil] unless decision == :retry
        end
      end
    end

    # :retry — пауза выдержана, можно повторять; иначе решение для маршрута.
    def handle_failure(stage, route, try, error, visits)
      kind = LlmFailure.classify(error)
      raise error if kind == :unhandled

      @logger.warn("LLM #{stage} request failed (#{route}): #{error.class}: #{error.message}")
      decision, delay = decide(kind, try, error)
      raise ApiError, single_route_message(error) if decision == :fail

      if decision == :retry
        return :retry if requests_left?(stage, route) && waited_before_retry?(stage, route, delay)

        decision = give_up(kind)
      end
      record_failure(stage, route, kind, decision, error)
      visits << Visit.new(route: route, kind: kind, tries: try, error: error)
      decision
    end

    def requests_left?(stage, route)
      return true if state(route.candidate).requests_left?(stage)

      @logger.warn("LLM #{stage}: #{route.candidate} has used its #{MAX_ATTEMPTS_PER_MODEL} attempts")
      false
    end

    # :retry с паузой, :next_key, :next_model или :fail.
    def decide(kind, try, error)
      case kind
      when :fatal then [:fail]
      when :unavailable then [:next_model]
      when :daily_quota then [:next_key]
      when :rate_limit then try == 1 ? [:retry, rate_limit_delay(error)] : [:next_key]
      else try == 1 ? [:retry, short_delay] : [:next_model]
      end
    end

    def give_up(kind)
      kind == :rate_limit ? :next_key : :next_model
    end

    # Суточная квота помечает ключ у модели, отсутствующая модель — модель
    # на весь прогон, перегрузка и таймаут — карантин, минутный лимит —
    # карантин на время подсказки провайдера (следующий ключ пробуется
    # сразу, карантин действует только на следующий визит к модели).
    def record_failure(stage, route, kind, decision, error)
      model = state(route.candidate)
      case kind
      when :daily_quota then model.exhaust_key(route.key_index)
      when :unavailable then model.exclude('model unavailable earlier in this run')
      when :rate_limit then quarantine(stage, route, rate_limit_delay(error).seconds)
      when :overloaded, :timeout then quarantine(stage, route, @config.overloaded_quarantine) if decision == :next_model
      end
    end

    def quarantine(stage, route, seconds)
      state(route.candidate).quarantine(now + seconds)
      @logger.warn(format('LLM %<stage>s: %<model>s quarantined for %<seconds>.0fs',
                          stage: stage, model: route.candidate, seconds: seconds))
    end

    def short_delay
      Delay.new(SHORT_RETRY_DELAY * rand(SHORT_RETRY_JITTER_RANGE), '')
    end

    def rate_limit_delay(error)
      hint = LlmFailure.retry_after_seconds(error.message)
      return Delay.new(RATE_LIMIT_BASE_DELAY + rand(RATE_LIMIT_JITTER_RANGE), '') unless hint

      multiplier = rand(PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE)
      Delay.new(hint * multiplier, format(' (provider retry hint %<hint>.1fs, multiplier %<multiplier>.2fx)',
                                          hint: hint, multiplier: multiplier))
    end

    # false — пауза не помещается в бюджет времени, повтора не будет.
    def waited_before_retry?(stage, route, delay)
      if delay.seconds > remaining_time
        @logger.warn(
          format('LLM %<stage>s: no time budget left for a %<delay>.0fs pause (%<left>.0fs remaining, %<route>s)',
                 stage: stage, delay: delay.seconds, left: [remaining_time, 0].max, route: route)
        )
        return false
      end

      @logger.warn(
        format(RETRY_WAIT_LOG_FORMAT, stage: stage, delay: delay.seconds, source: delay.source,
                                      next_request: state(route.candidate).sent(stage) + 1,
                                      max_requests: MAX_ATTEMPTS_PER_MODEL, model: route.candidate.model)
      )
      started_at = now
      pause(delay.seconds)
      @logger.info(format('LLM %<stage>s retry wait completed after %<waited>.1fs (model=%<model>s)',
                          stage: stage, waited: now - started_at, model: route.candidate.model))
      true
    end

    def ensure_time_left!(stage, route, visits)
      return if remaining_time >= 1

      visits << Visit.new(route: route, note: 'no time budget left')
      raise ApiError, "LLM time budget of #{@config.llm_time_budget}s is exhausted. " \
                      "#{exhausted_message(stage, visits)}"
    end

    def request_timeout
      [@config.llm_timeout.to_f, remaining_time].min
    end

    def quota_exhausted?(stage, route, visits)
      return false unless state(route.candidate).key_exhausted?(route.key_index)

      @logger.info("LLM #{stage}: skipping #{route}, daily quota exhausted earlier in this run")
      visits << Visit.new(route: route, note: 'daily quota exhausted earlier in this run')
      true
    end

    # Ответившая модель не перегружена, какой бы ключ ни ответил: карантин,
    # выставленный по другому ключу той же модели, снимается.
    def remember(stage, route, response)
      @cursor[stage] = [route.candidate_index, route.key_index]
      @used[stage] = route
      state(route.candidate).lift_quarantine
      response
    end

    def log_switch(stage, route, visits)
      return if visits.empty?

      @logger.warn("LLM #{stage}: switching to #{route} after #{visits.last}")
    end

    # --- порядок обхода моделей ---

    # Следующий запрос стадии (например, починка JSON) начинается с модели,
    # которая ответила; остальные остаются в резерве после неё.
    def ordered_chain(stage)
      start_candidate, = @cursor.fetch(stage, [0, 0])
      chain_for(stage).each_with_index.to_a.rotate(start_candidate)
    end

    # Цепочка критики зависит от того, какая модель ответила в generate:
    # при общем пуле критика не опускается ниже неё. Считается один раз на
    # стадию, чтобы починка и перезапуск шли по той же цепочке.
    def chain_for(stage)
      @chains ||= {}
      @chains[stage] ||= build_chain(stage)
    end

    # Предупреждения плана, возникшие при построении цепочки (например,
    # проигнорированный critique.start), CLI при старте ещё не видел —
    # печатает роутер.
    def build_chain(stage)
      known = @routing.warnings.size
      chain = if stage == 'critique' && @used['generate']
                @routing.critique_chain(after: @used['generate'].candidate)
              else
                @routing.chain(stage)
              end
      @routing.warnings.drop(known).each { |warning| @logger.warn(warning) }
      chain
    end

    def pinned_chain(stage)
      route = @used[stage]
      raise ApiError, "LLM #{stage}: no model has answered yet, nothing to pin" unless route

      [[route.candidate, route.candidate_index]]
    end

    # --- тексты ошибок ---

    def exhausted_error(stage, visits, pinned)
      (pinned ? RouteExhaustedError : ApiError).new(exhausted_message(stage, visits))
    end

    # Одна ошибка на одном маршруте — короткое сообщение про неё; иначе
    # перечень маршрутов с причинами.
    def exhausted_message(stage, visits)
      return single_route_message(visits.first.error) if visits.size == 1 && visits.first.error

      "LLM #{stage} request failed on every configured route: #{visits.join('; ')}. #{SWITCH_HINT}"
    end

    def single_route_message(error)
      case LlmFailure.classify(error)
      when :timeout
        "LLM request timed out after #{@config.llm_timeout} seconds. #{SWITCH_HINT}"
      when :overloaded
        "LLM service is temporarily unavailable or overloaded: #{error.message}. #{SWITCH_HINT}"
      when :rate_limit, :daily_quota
        "LLM rate limit exceeded: #{error.message}. #{SWITCH_HINT}"
      when :unavailable
        "LLM model is unavailable: #{error.message}. #{SWITCH_HINT}"
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

    def now
      @clock.call
    end

    def pause(seconds)
      @sleeper.call(seconds)
    end
  end
end
