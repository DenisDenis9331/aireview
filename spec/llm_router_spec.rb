require 'stringio'
require 'json'
require 'aireview/llm_router'
require 'aireview/stage_chains'
require 'aireview/model_pool'

# Роутер на управляемых часах: sleep двигает время, реальных ожиданий нет.
RSpec.describe Aireview::LlmRouter do
  include_context 'LLM errors'

  let(:now) { {time: 0.0} }
  let(:sleeps) { [] }
  let(:log_output) { StringIO.new }
  let(:models) { %w[gemini-a] }
  let(:keys) { ['key-one'] }
  let(:time_budget) { 1_800 }
  let(:config) do
    instance_double(
      'Aireview::Config',
      llm_timeout: 60,
      llm_time_budget: time_budget,
      overloaded_quarantine: 120
    )
  end
  # Настоящий план: одна цепочка на обе стадии — первая модель основная,
  # остальные запасные в порядке списка.
  let(:routing) do
    chains = %w[generate critique].to_h { |stage| [stage, models.map { |model| candidate(model) }] }
    Aireview::StageChains.new(chains)
  end
  let(:router) do
    described_class.new(
      config: config,
      routing: routing,
      logger: Logger.new(log_output),
      clock: -> { now[:time] },
      sleeper: lambda { |seconds|
        sleeps << seconds
        now[:time] += seconds
      }
    )
  end

  def candidate(model, provider: 'gemini', max_prompt_chars: 400_000)
    Aireview::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: max_prompt_chars)
  end

  before do
    allow(config).to receive(:provider_api_keys) { |provider| provider.to_s == 'ollama' ? [nil] : keys }
    allow(router).to receive(:rand).with(Aireview::LlmRouter::SHORT_RETRY_JITTER_RANGE).and_return(1.0)
    allow(router).to receive(:rand).with(Aireview::LlmRouter::PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE).and_return(2.0)
    allow(router).to receive(:rand).with(Aireview::LlmRouter::RATE_LIMIT_JITTER_RANGE).and_return(3.0)
  end

  # Сценарий — список ответов по моделям: исключение бросается, всё
  # остальное возвращается. Вызовы пишутся как "model@time".
  def run(stage: 'generate', pinned: false, script:)
    calls = []
    result = router.call(stage: stage, request_chars: 10, pinned: pinned) do |route, _timeout|
      calls << "#{route.candidate.model}@#{now[:time].to_i}#{route.key_count > 1 ? "/#{route.key_index + 1}" : ''}"
      answer = script.fetch(route.candidate.model).shift
      raise answer if answer.is_a?(Exception)

      answer
    end
    [result, calls]
  end

  describe 'a single model without fallbacks' do
    it 'sends three requests with a short pause and a quarantine between them, then fails' do
      expect do
        run(script: {'gemini-a' => [overloaded_error, overloaded_error, overloaded_error]})
      end.to raise_error(
        Aireview::ApiError,
        'LLM generate request failed on every configured route: ' \
        'gemini/gemini-a: overloaded after 2 attempt(s); gemini/gemini-a: overloaded after 1 attempt(s). ' \
        'Try again later or switch model via --generate-model/--critique-model.'
      )

      expect(sleeps).to eq([30.0, 120.0])
      expect(log_output.string).to include('gemini/gemini-a quarantined for 120s')
      expect(log_output.string).to include('every model is quarantined, waiting 120s for gemini/gemini-a')
      expect(log_output.string).to include('gemini/gemini-a has used its 3 attempts')
    end

    it 'succeeds on the third request after the quarantine' do
      result, calls = run(script: {'gemini-a' => [overloaded_error, overloaded_error, 'ok']})

      expect(result).to eq('ok')
      expect(calls).to eq(%w[gemini-a@0 gemini-a@30 gemini-a@150])
      expect(router.answered('generate')).to eq('gemini/gemini-a (1/1)')
    end

    it 'does not wait for a quarantine that does not fit the time budget' do
      allow(config).to receive(:llm_time_budget).and_return(100)

      expect do
        run(script: {'gemini-a' => [overloaded_error, overloaded_error]})
      end.to raise_error(Aireview::ApiError, /quarantined for another 120s, over the time budget/)
      expect(sleeps).to eq([30.0])
    end
  end

  describe 'a pool of models' do
    let(:models) { %w[gemini-a gemini-b] }

    it 'moves to the next model after one short retry and comes back once the quarantine expires' do
      result, calls = run(script: {
        'gemini-a' => [overloaded_error, overloaded_error, 'from a'],
        'gemini-b' => [overloaded_error, overloaded_error]
      })

      expect(result).to eq('from a')
      expect(calls).to eq(%w[gemini-a@0 gemini-a@30 gemini-b@30 gemini-b@60 gemini-a@150])
      expect(sleeps).to eq([30.0, 30.0, 90.0])
      expect(router.fallback_models).to eq({})
    end

    it 'ends the stage at once when every model has used its attempts, without waiting for quarantines' do
      expect do
        run(script: {
          'gemini-a' => [overloaded_error, overloaded_error, overloaded_error],
          'gemini-b' => [overloaded_error, overloaded_error, overloaded_error]
        })
      end.to raise_error(Aireview::ApiError, /failed on every configured route/) do |error|
        expect(error.message).to include('gemini/gemini-a: overloaded after 2 attempt(s)')
        expect(error.message).to include('gemini/gemini-b: overloaded after 2 attempt(s)')
        expect(error.message).to include('gemini/gemini-a: overloaded after 1 attempt(s)')
        expect(error.message).not_to include('attempt limit')
      end
      # Последняя модель без привилегий: после третьей неудачи никаких 2/5/5/5 минут.
      expect(sleeps).to eq([30.0, 30.0, 90.0, 30.0])
    end

    it 'skips an unavailable model for the rest of the run without a retry' do
      missing = missing_model_error('gemini-a')
      result, calls = run(script: {'gemini-a' => [missing], 'gemini-b' => ['from b']})
      expect(result).to eq('from b')
      expect(calls).to eq(%w[gemini-a@0 gemini-b@0])
      expect(sleeps).to be_empty
      expect(router.fallback_models).to eq('generate' => 'gemini/gemini-b')

      _, calls = run(stage: 'critique', script: {'gemini-b' => ['critique b']})
      expect(calls).to eq(%w[gemini-b@0])
      expect(log_output.string).to include(
        'LLM generate: switching to gemini/gemini-b after gemini/gemini-a: model unavailable after 1 attempt(s)'
      )
    end

    it 'treats a bare 404 as fatal: a wrong API base answers the same for every model' do
      expect do
        run(script: {'gemini-a' => [RubyLLM::Error.new('404 Not Found')]})
      end.to raise_error(Aireview::ApiError, 'LLM API request failed: 404 Not Found')
    end

    it 'starts the critique from a model still in quarantine only after the others' do
      run(script: {'gemini-a' => [overloaded_error, overloaded_error], 'gemini-b' => ['from b']})
      _, calls = run(stage: 'critique', script: {'gemini-a' => ['never'], 'gemini-b' => ['critique b']})

      expect(calls).to eq(%w[gemini-b@30])
    end

    it 'keeps the attempt counter per stage: generate attempts do not count against critique' do
      run(script: {'gemini-a' => [overloaded_error, overloaded_error], 'gemini-b' => ['from b']})
      now[:time] = 500
      _, calls = run(stage: 'critique', script: {'gemini-a' => ['critique a']})

      expect(calls).to eq(%w[gemini-a@500])
    end
  end

  describe 'a shared pool with a critique rank' do
    let(:models) { %w[gemini-pro gemini-flash gemini-lite] }
    let(:allow_weaker) { false }
    # Настоящий пул: generate стартует со второй модели, критика — не ниже ответившей.
    let(:routing) do
      Aireview::ModelPool.new(items: models, provider: 'gemini', limits: {'generate' => 400_000, 'critique' => 400_000},
                              starts: {'generate' => 'gemini-flash'}, allow_weaker: allow_weaker)
    end

    it 'runs the critique on the first live model not below the one that answered in generate' do
      run(script: {'gemini-flash' => ['from flash']})
      _, calls = run(stage: 'critique', script: {'gemini-pro' => [overloaded_error, overloaded_error], 'gemini-flash' => ['critique']})

      expect(calls).to eq(%w[gemini-pro@0 gemini-pro@30 gemini-flash@30])
      expect(router.answered('critique')).to eq('gemini/gemini-flash (2/2)')
      expect(router.critique_weaker?).to be(false)
      expect(router.fallback_models).to eq('critique' => 'gemini/gemini-flash')
    end

    it 'fails the critique instead of falling below generate when weaker models are not allowed' do
      run(script: {'gemini-flash' => [overloaded_error, overloaded_error], 'gemini-lite' => ['from lite']})

      expect do
        run(stage: 'critique', script: {
          'gemini-pro' => [overloaded_error, overloaded_error, overloaded_error],
          'gemini-flash' => [overloaded_error, overloaded_error, overloaded_error],
          'gemini-lite' => [overloaded_error, overloaded_error, overloaded_error]
        })
      end.to raise_error(Aireview::ApiError, /failed on every configured route/) do |error|
        expect(error.message).to include('gemini/gemini-pro', 'gemini/gemini-flash', 'gemini/gemini-lite')
      end
    end

    context 'with a critique start below the model that answered in generate' do
      let(:routing) do
        Aireview::ModelPool.new(items: models, provider: 'gemini', limits: {'generate' => 400_000, 'critique' => 400_000},
                                starts: {'generate' => 'gemini-flash', 'critique' => 'gemini-lite'})
      end

      it 'logs the warning the plan raises while the critique chain is built' do
        run(script: {'gemini-flash' => ['from flash']})
        expect(log_output.string).not_to include('llm.critique.start')

        _, calls = run(stage: 'critique', script: {'gemini-pro' => ['critique']})

        expect(calls).to eq(%w[gemini-pro@0])
        expect(log_output.string).to include(
          'llm.critique.start gemini-lite is below the model that answered in generate and allow_weaker is off, ignoring it'
        )
        expect(log_output.string.scan('llm.critique.start gemini-lite').size).to eq(1)
      end
    end

    context 'when weaker models are allowed' do
      let(:allow_weaker) { true }

      it 'reports a critique that ran below generate' do
        run(script: {'gemini-flash' => ['from flash']})
        run(stage: 'critique', script: {
          'gemini-pro' => [overloaded_error, overloaded_error], 'gemini-flash' => [overloaded_error, overloaded_error],
          'gemini-lite' => ['weak']
        })

        expect(router.critique_weaker?).to be(true)
      end
    end
  end

  describe 'keys' do
    let(:keys) { %w[key-one key-two] }

    it 'excludes a model whose keys are all out of daily quota instead of looping over them' do
      expect do
        run(script: {'gemini-a' => [daily_quota_error, daily_quota_error]})
      end.to raise_error(Aireview::ApiError, /key 1\/2\): daily quota exhausted.*key 2\/2\): daily quota exhausted/)

      expect do
        run(stage: 'critique', script: {})
      end.to raise_error(Aireview::ApiError, /gemini\/gemini-a: daily quota exhausted on every key/)
    end

    it 'counts attempts across the keys of a model' do
      expect do
        run(script: {'gemini-a' => [daily_quota_error, overloaded_error, overloaded_error]})
      end.to raise_error(Aireview::ApiError, /failed on every configured route/) do |error|
        expect(error.message).to include('gemini/gemini-a (key 1/2): daily quota exhausted after 1 attempt(s)')
        expect(error.message).to include('gemini/gemini-a (key 2/2): overloaded after 2 attempt(s)')
      end

      expect(sleeps).to eq([30.0])
    end

    it 'lifts the quarantine of a model once any of its keys answers' do
      limited = RubyLLM::RateLimitError.new('Quota exceeded. Please retry in 100s.')
      allow(config).to receive(:llm_time_budget).and_return(100)
      _, calls = run(script: {'gemini-a' => [limited, 'bad json']})
      expect(calls).to eq(%w[gemini-a@0/1 gemini-a@0/2])

      _, calls = run(pinned: true, script: {'gemini-a' => ['repaired']})
      expect(calls).to eq(%w[gemini-a@0/2])
      expect(sleeps).to be_empty
    end

    it 'retries a rate limit once with the provider hint, then tries the next key' do
      limited = RubyLLM::RateLimitError.new('Quota exceeded. Please retry in 5s.')
      result, calls = run(script: {'gemini-a' => [limited, limited, 'ok']})

      expect(result).to eq('ok')
      expect(calls).to eq(%w[gemini-a@0/1 gemini-a@10/1 gemini-a@10/2])
      expect(sleeps).to eq([10.0])
    end
  end

  describe 'time budget' do
    let(:models) { %w[gemini-a gemini-b] }

    # Запрос, который висит: каждый вызов двигает часы на 80 секунд.
    def run_slow(seconds:, script:)
      calls = []
      result = router.call(stage: 'generate', request_chars: 10) do |route, timeout|
        calls << [route.candidate.model, timeout]
        now[:time] += seconds
        answer = script.fetch(route.candidate.model).shift
        raise answer if answer.is_a?(Exception)

        answer
      end
      [result, calls]
    end

    it 'skips a pause that does not fit, moves on, and fails once the budget is gone' do
      allow(config).to receive(:llm_time_budget).and_return(100)

      expect do
        run_slow(seconds: 80, script: {'gemini-a' => [overloaded_error], 'gemini-b' => [overloaded_error]})
      end.to raise_error(Aireview::ApiError, /LLM time budget of 100s is exhausted/)

      expect(sleeps).to be_empty
      expect(log_output.string).to include('LLM generate: no time budget left for a 30s pause (20s remaining')
    end

    it 'caps the request timeout by the remaining budget' do
      allow(config).to receive(:llm_time_budget).and_return(100)

      result, calls = run_slow(seconds: 70, script: {'gemini-a' => [daily_quota_error], 'gemini-b' => ['from b']})

      expect(result).to eq('from b')
      # Первый запрос — полный LLM_TIMEOUT, второй — остаток бюджета.
      expect(calls).to eq([['gemini-a', 60.0], ['gemini-b', 30.0]])
    end
  end

  describe 'keys carried between models' do
    let(:models) { %w[gemini-a gemini-b] }
    let(:keys) { %w[key-one key-two] }

    it 'continues the next model of the same provider from the key that was in use' do
      result, calls = run(script: {
        'gemini-a' => [daily_quota_error, overloaded_error, overloaded_error],
        'gemini-b' => [daily_quota_error, 'from b']
      })

      expect(result).to eq('from b')
      # Ключ 1 у модели a выбыл по квоте, ключ 2 перегружен дважды; модель b
      # начинает с ключа 2 (перенос), по квоте на нём переходит к ключу 1.
      expect(calls).to eq(%w[gemini-a@0/1 gemini-a@0/2 gemini-a@30/2 gemini-b@30/2 gemini-b@30/1])
    end

    it 'starts the next request of the stage from the key that answered' do
      run(script: {'gemini-a' => [daily_quota_error, 'first']})
      _, calls = run(script: {'gemini-a' => ['second']})

      expect(calls).to eq(%w[gemini-a@0/2])
    end
  end

  describe 'fatal errors' do
    it 'does not retry a context that is too long and names the remedy' do
      expect do
        run(script: {'gemini-a' => [RubyLLM::ContextLengthExceededError.new('context is too long')]})
      end.to raise_error(Aireview::ApiError,
                         'LLM context limit exceeded: context is too long. Try reducing the MR diff or ignore more paths.')
      expect(sleeps).to be_empty
    end
  end

  describe 'pinned requests' do
    let(:models) { %w[gemini-a gemini-b] }

    it 'sends the repair only to the model that answered and reports its exhaustion as RouteExhaustedError' do
      run(script: {'gemini-a' => ['first']})
      _, calls = run(pinned: true, script: {'gemini-a' => ['repair']})
      expect(calls).to eq(%w[gemini-a@0])

      run(pinned: true, script: {'gemini-a' => ['third']})
      expect do
        run(pinned: true, script: {'gemini-a' => ['never'], 'gemini-b' => ['never']})
      end.to raise_error(Aireview::RouteExhaustedError, /gemini\/gemini-a: attempt limit of 3 reached/)
    end

    it 'fails the run on a fatal error even when pinned' do
      run(script: {'gemini-a' => ['first']})

      expect do
        run(pinned: true, script: {'gemini-a' => [RubyLLM::UnauthorizedError.new('bad key')]})
      end.to raise_error(Aireview::ApiError, 'LLM API request failed: bad key')
    end
  end

  describe 'excluding a model for a stage' do
    let(:models) { %w[gemini-a gemini-b] }

    it 'sends the next request of the stage to another model and keeps the excluded one for other stages' do
      run(script: {'gemini-a' => ['bad json']})
      expect(router.exclude_answered(stage: 'generate', reason: 'invalid result')).to eq(candidate('gemini-a'))

      _, calls = run(script: {'gemini-a' => ['never'], 'gemini-b' => ['from b']})
      expect(calls).to eq(%w[gemini-b@0])

      _, calls = run(stage: 'critique', script: {'gemini-a' => ['critique a']})
      expect(calls).to eq(%w[gemini-a@0])
    end

    it 'lists the exclusion when nothing is left' do
      run(script: {'gemini-a' => ['bad json']})
      router.exclude_answered(stage: 'generate', reason: 'invalid result')
      run(script: {'gemini-b' => ['bad json too']})
      router.exclude_answered(stage: 'generate', reason: 'invalid result')

      expect do
        run(script: {})
      end.to raise_error(
        Aireview::ApiError,
        'LLM generate request failed on every configured route: ' \
        'gemini/gemini-b: excluded for this stage: invalid result; ' \
        'gemini/gemini-a: excluded for this stage: invalid result. ' \
        'Try again later or switch model via --generate-model/--critique-model.'
      )
    end

    it 'returns nil when no model has answered yet' do
      expect(router.exclude_answered(stage: 'generate', reason: 'invalid result')).to be_nil
    end
  end
end
