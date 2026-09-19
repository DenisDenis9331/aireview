# frozen_string_literal: true
require 'logger'
require 'socket'
require_relative 'errors'
require_relative 'stages'
require_relative 'llm_failure'
require_relative 'review_pipeline'
require_relative 'result_parser'
require_relative 'llm_client'
require_relative 'output_schemas'

module Aireview
  # `aireview models check`: каждой модели из цепочек обеих стадий — по
  # запросу с боевой схемой generate и critique на крошечном синтетическом
  # MR. Ответ проходит ту же валидацию, что в прогоне: каталог провайдера
  # не спрашиваем, «модель в списке» не значит «наш запрос со схемой на ней
  # пройдёт». Без резервов, карантина и обхода — это проверка, а не ревью.
  class ModelChecker
    PROBE_MERGE_REQUEST = {
      'title' => 'Fix order total',
      'description' => 'The total must include the quantity.',
      'source_branch' => 'fix/order-total',
      'target_branch' => 'master',
      'author' => {'name' => 'aireview'}
    }.freeze
    PROBE_CHANGES = [
      {
        'old_path' => 'app/models/order.rb',
        'new_path' => 'app/models/order.rb',
        'diff' => "@@ -1,5 +1,5 @@\n class Order\n   def total\n-    price * quantity\n+    price\n   end\n"
      }
    ].freeze
    PROBE_CANDIDATE_IDS = ['C1'].freeze
    # ok и skipped не блокируют релиз, всё остальное — блокирует. В строгом
    # режиме (раннер, где Ollama обязана быть) skipped — тоже провал.
    PASSING = %i[ok skipped].freeze
    STRICT_PASSING = %i[ok].freeze

    Result = Struct.new(:candidate, :stage, :status, :detail, :seconds, keyword_init: true) do
      def to_s
        text = seconds ? "#{status} (#{format('%.1fs', seconds)})" : status.to_s
        text = "#{text}: #{detail}" if detail
        "#{candidate.to_s.ljust(32)} #{stage.ljust(8)} #{text}"
      end
    end

    # strict — skipped считается провалом (раннер, где Ollama обязана быть).
    def initialize(config:, out:, strict: false, logger: Logger.new($stderr), **dependencies)
      @config = config
      @out = out
      @strict = strict
      client = dependencies[:client]
      sleeper = dependencies[:sleeper]
      @logger = logger
      @client = client || LlmClient.new(config: config, logger: logger)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @pipeline = ReviewPipeline.new(config: config, logger: logger)
      @parser = ResultParser.new
    end

    # Код выхода: 0 — все модели ответили по схеме (или пропущены), 1 —
    # хотя бы одна нет.
    def run
      @config.require_llm_configuration!
      candidates = STAGES.flat_map { |stage| @config.stage_chain(stage) }.uniq(&:to_s)
      prompts = probe_prompts
      @out.puts("Checking #{candidates.size} model(s) with the generate and critique schemas")
      results = candidates.flat_map do |candidate|
        STAGES.map { |stage| check(candidate, stage, prompts).tap { |result| @out.puts(result) } }
      end
      summary(results)
    end

    private

    def probe_prompts
      dry_run = @pipeline.dry_run_prompts(merge_request: PROBE_MERGE_REQUEST, changes: PROBE_CHANGES, critique: true)
      {'generate' => dry_run[:generate_prompt], 'critique' => dry_run[:critique_prompt]}
    end

    def check(candidate, stage, prompts)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw = probe_with_one_retry(candidate, stage, prompts[stage])
      @parser.parse(raw, expected: stage, critique_candidate_ids: PROBE_CANDIDATE_IDS)
      Result.new(candidate: candidate, stage: stage, status: :ok,
                 seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
    rescue JSON::ParserError, ResultParser::SchemaError => e
      Result.new(candidate: candidate, stage: stage, status: :invalid,
                 detail: "LLM returned invalid #{stage} result: #{e.message}")
    rescue StandardError => e
      Result.new(candidate: candidate, stage: stage, status: failure_status(candidate, e), detail: e.message)
    end

    # Минутный лимит — не повод считать модель сломанной: один повтор по
    # подсказке провайдера, дальше «не удалось проверить».
    def probe_with_one_retry(candidate, stage, prompt)
      probe(candidate, stage, prompt)
    rescue StandardError => e
      raise unless LlmFailure.classify(e) == :rate_limit

      delay = LlmFailure.retry_after_seconds(e.message) || LlmRouter::RATE_LIMIT_BASE_DELAY
      @logger.warn("Model check: #{candidate} rate limited, retrying once in #{delay.round}s")
      @sleeper.call(delay)
      probe(candidate, stage, prompt)
    end

    def probe(candidate, stage, prompt)
      request = LlmClient::Prompt.new(
        stage: stage, system: prompt[:system_prompt], user: prompt[:user_prompt], temperature: 0,
        schema: stage == 'critique' ? CritiqueOutputSchema : GenerateOutputSchema
      )
      key = @config.provider_api_keys(candidate.provider).first
      @client.request(request, candidate: candidate, key: key, timeout: @config.llm_timeout.to_f).content
    end

    # missing — модели нет у провайдера; unverified — провайдер не смог
    # ответить сейчас (перегрузка, квота, таймаут); skipped — Ollama не
    # запущена там, где идёт проверка; failed — всё остальное.
    def failure_status(candidate, error)
      return :skipped if candidate.provider == 'ollama' && connection_failed?(error)

      case LlmFailure.classify(error)
      when :unavailable then :missing
      when :rate_limit, :daily_quota, :overloaded, :timeout then :unverified
      else :failed
      end
    end

    def connection_failed?(error)
      return true if error.is_a?(Errno::ECONNREFUSED) || error.is_a?(SocketError)

      defined?(Faraday::ConnectionFailed) && error.is_a?(Faraday::ConnectionFailed)
    end

    def summary(results)
      counts = results.group_by(&:status).transform_values(&:size)
      passed = results.all? { |result| passing_statuses.include?(result.status) }
      totals = counts.map { |status, count| "#{count} #{status}" }.join(', ')
      @out.puts("Result: #{totals} -> #{passed ? 'PASSED' : 'FAILED'}")
      passed ? 0 : 1
    end

    def passing_statuses
      @strict ? STRICT_PASSING : PASSING
    end
  end
end
