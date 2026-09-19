# frozen_string_literal: true
require 'set'
require_relative 'errors'
require_relative 'llm_failure'
require_relative 'model_state'

module Aireview
  # Walks the models and keys of a stage. An overload is a property of the
  # model, a quota is a property of "key + model", so a 503 switches the
  # model and a quota switches the key. An overloaded model goes into
  # quarantine and is skipped until it expires; once the chain has been
  # walked, the walk goes round again over the models whose quarantine has
  # expired. Two limits: the time budget of the run and the number of
  # requests sent per model per stage (ModelState).
  class LlmRouter # rubocop:disable Metrics/ClassLength
    Route = Struct.new(:candidate, :candidate_index, :key, :key_index, :key_count, keyword_init: true) do
      def fallback?
        candidate_index.positive?
      end

      def to_s
        key_count > 1 ? "#{candidate} (key #{key_index + 1}/#{key_count})" : candidate.to_s
      end
    end

    # A journal entry about a visit to a route, for the error message: either
    # the kind of failure with the number of requests, or a note on why the
    # route was skipped.
    Visit = Struct.new(:route, :kind, :tries, :error, :note, keyword_init: true) do
      def to_s
        "#{route}: #{note || "#{LlmRouter::KIND_LABELS.fetch(kind)} after #{tries} attempt(s)"}"
      end
    end

    Slot = Struct.new(:candidate, :index)
    # The key the next model of the same provider continues from.
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
    # The first failure of a visit to a model gets one short retry, the
    # second one a quarantine and the next model.
    SHORT_RETRY_DELAY = 30.0
    SHORT_RETRY_JITTER_RANGE = 0.85..1.15
    RATE_LIMIT_BASE_DELAY = 2.0
    RATE_LIMIT_JITTER_RANGE = 2.0..5.0
    PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE = 2.0..2.4
    RETRY_WAIT_LOG_FORMAT = 'LLM %<stage>s request will sleep %<delay>.1fs before retry%<source>s ' \
                            '(request %<next_request>d/%<max_requests>d of the model in this stage, model=%<model>s)'

    # clock and sleeper are injected in tests: the schedule is checked without
    # real waiting.
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

    # The block receives a route and a request timeout, makes the request and
    # returns the answer. An error raised by the block is classified, then
    # comes a retry, another key, another model, or ApiError once the routes
    # are exhausted. pinned — only the model that answered last in this
    # stage (the JSON repair): its failure is RouteExhaustedError, and the
    # stage restarts on another model.
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

    # Stages answered by a model other than the primary one, for the report.
    def fallback_models
      @used.select { |_, route| route.fallback? }.transform_values { |route| route.candidate.to_s }
    end

    # The model that answered last in the stage and its place in the chain.
    def answered(stage)
      route = @used[stage.to_s]
      return nil unless route

      "#{route.candidate} (#{route.candidate_index + 1}/#{chain_for(stage.to_s).size})"
    end

    # Critique answered with a model below Generate in the pool, for the report.
    def critique_weaker?
      generate = @used['generate']
      critique = @used['critique']
      return false unless generate && critique

      @routing.weaker?(critique.candidate, generate.candidate)
    end

    # Excludes the model that answered until the end of the stage: its result
    # is invalid (not JSON, not the schema) even after the repair. The next
    # request of the stage goes to another model. Returns the excluded model;
    # nil — nothing to exclude.
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

    # The models that can still be tried, in walking order. A skipped model
    # enters the journal once per call, and only if it is not already there
    # with an error of this same call.
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

    # The first model not in quarantine; when all are, wait for the nearest
    # release if it fits into the budget. nil — it does not.
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

    # On :next_model hands over the current key: an overload is a property of
    # the model, and the next model of the same provider continues from the
    # same key instead of going back to the first one, whose quota may
    # already be gone.
    #
    # Every visit either sends a request or excludes the model: otherwise the
    # walk round the pool would never stop. A model whose keys are all out of
    # daily quota is excluded until the end of the run.
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

    # The keys start from the carried one (after an overload — the current
    # key, after an answer — the one that answered), the rest follow: a quota
    # is bound to "key + model", a failure on one model does not write the
    # key off for another.
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

    # A visit to a route: requests until an answer, a retry or a refusal. try
    # is the request number within this visit; the per-stage counter of the
    # model is kept by ModelState.
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

    # :retry — the pause has been waited out, retry; otherwise the decision for the route.
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

    # :retry with a delay, :next_key, :next_model or :fail.
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

    # A daily quota marks the key of the model, a missing model marks the
    # model for the whole run, an overload or a timeout quarantines it, a
    # per-minute limit quarantines it for the provider's hint (the next key
    # is tried at once; the quarantine only affects the next visit).
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

    # false — the pause does not fit into the time budget, no retry.
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

    # A model that answered is not overloaded, whichever key answered: a
    # quarantine set through another key of the same model is lifted.
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

    # --- walking order ---

    # The next request of the stage (the JSON repair, for instance) starts
    # from the model that answered; the rest stay in reserve after it.
    def ordered_chain(stage)
      start_candidate, = @cursor.fetch(stage, [0, 0])
      chain_for(stage).each_with_index.to_a.rotate(start_candidate)
    end

    # The critique chain depends on the model that answered in Generate:
    # with a shared pool Critique does not go below it. Computed once per
    # stage so that the repair and a restart walk the same chain.
    def chain_for(stage)
      @chains ||= {}
      @chains[stage] ||= build_chain(stage)
    end

    # Warnings the plan raises while building a chain (an ignored
    # critique.start, for instance) were not there when the CLI started —
    # the router logs them.
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

    # --- error messages ---

    def exhausted_error(stage, visits, pinned)
      (pinned ? RouteExhaustedError : ApiError).new(exhausted_message(stage, visits))
    end

    # One error on one route — a short message about it; otherwise the list
    # of routes with reasons.
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
