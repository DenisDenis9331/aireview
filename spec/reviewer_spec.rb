require 'aireview/reviewer'
require 'aireview/config_fallbacks'
require 'stringio'
require 'json'

RSpec.describe Aireview::Reviewer do
  let(:config) do
    instance_double(
      'Aireview::Config',
      require_llm_configuration!: true,
      generate_provider: generate_provider,
      critique_provider: critique_provider,
      provider_api_key: 'secret-key',
      llm_api_base: 'https://llm.example.test',
      ollama_api_base: 'http://localhost:11434/v1',
      llm_http_proxy: 'http://127.0.0.1:8888',
      llm_temperature: 0.2,
      generate_model: 'gemini-3.7-flash',
      generate_temperature: 0.3,
      critique_model: 'gemini-3.8-flash',
      critique_temperature: 0,
      llm_timeout: 60,
      llm_time_budget: 1_800
    )
  end

  let(:generate_provider) { 'gemini' }
  let(:critique_provider) { 'gemini' }
  let(:generate_model) { 'gemini-3.7-flash' }
  let(:critique_model) { 'gemini-3.8-flash' }
  let(:generate_fallbacks) { [] }
  let(:critique_fallbacks) { [] }
  let(:gemini_keys) { ['secret-key'] }
  let(:fallback_chat) { instance_double('RubyLLM::Chat') }
  let(:fallback_response) { instance_double('RubyLLM::Message', content: 'fallback body') }

  def candidate(provider, model, max_prompt_chars: 400_000)
    Aireview::ConfigFallbacks::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: max_prompt_chars)
  end
  let(:logger) { Logger.new(nil) }
  let(:generate_chat) { instance_double('RubyLLM::Chat') }
  let(:critique_chat) { instance_double('RubyLLM::Chat') }
  let(:generate_response) { instance_double('RubyLLM::Message', content: 'generate body') }
  let(:critique_response) { instance_double('RubyLLM::Message', content: 'critique body') }
  let(:context_configs) { [] }
  let(:contexts) { [] }
  let(:ruby_config_class) do
    Struct.new(
      :default_model,
      :http_proxy,
      :request_timeout,
      :max_retries,
      :gemini_api_key,
      :gemini_api_base,
      :openai_api_key,
      :openai_api_base,
      :openrouter_api_key,
      :openrouter_api_base,
      :anthropic_api_key,
      :ollama_api_base,
      keyword_init: true
    )
  end
  let(:global_ruby_config) do
    ruby_config_class.new(
      default_model: 'global-model',
      http_proxy: 'http://global-proxy.example.test',
      request_timeout: 300,
      max_retries: 3,
      gemini_api_key: 'global-gemini-key',
      gemini_api_base: 'https://global-gemini.example.test',
      openai_api_key: 'global-openai-key',
      openai_api_base: 'https://global-openai.example.test',
      openrouter_api_key: 'global-openrouter-key',
      openrouter_api_base: 'https://global-openrouter.example.test',
      anthropic_api_key: 'global-anthropic-key',
      ollama_api_base: 'http://global-ollama.example.test'
    )
  end

  before do
    allow_any_instance_of(described_class).to receive(:require).with('ruby_llm').and_return(true)
    allow(config).to receive(:stage_chain) do |stage|
      if stage.to_s == 'generate'
        [candidate(generate_provider, generate_model), *generate_fallbacks]
      else
        [candidate(critique_provider, critique_model), *critique_fallbacks]
      end
    end
    allow(config).to receive(:provider_api_keys) { |provider| provider.to_s == 'ollama' ? [nil] : gemini_keys }
    stub_const('RubyLLM', Module.new)
    stub_const('RubyLLM::Error', Class.new(StandardError) do
      attr_reader :response

      def initialize(response = nil, message = nil)
        response, message = nil, response if response.is_a?(String)
        @response = response
        super(message || response&.body)
      end
    end)
    stub_const('RubyLLM::ServiceUnavailableError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::OverloadedError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::RateLimitError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::ContextLengthExceededError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::ModelNotFoundError', Class.new(StandardError))
    RubyLLM.singleton_class.attr_accessor :config
    RubyLLM.config = global_ruby_config

    allow(RubyLLM).to receive(:context) do |&block|
      context_config = RubyLLM.config.dup
      block.call(context_config)
      context = instance_double('RubyLLM::Context')
      allow(context).to receive(:chat)
        .with(model: 'gemini-3.7-flash', provider: anything)
        .and_return(generate_chat)
      allow(context).to receive(:chat)
        .with(model: 'gemini-3.8-flash', provider: anything)
        .and_return(critique_chat)
      allow(context).to receive(:chat)
        .with(model: 'gemini-3.6-flash', provider: anything)
        .and_raise(RubyLLM::ModelNotFoundError)
      allow(context).to receive(:chat)
        .with(model: 'gemini-3.6-flash', provider: anything, assume_model_exists: true)
        .and_return(generate_chat)
      allow(context).to receive(:chat)
        .with(model: 'gpt-oss:20b', provider: anything)
        .and_return(critique_chat)
      allow(context).to receive(:chat)
        .with(model: 'gemini-fallback', provider: anything)
        .and_return(fallback_chat)
      context_configs << context_config
      contexts << context
      context
    end

    allow(generate_chat).to receive(:with_temperature).with(0.3).and_return(generate_chat)
    allow(generate_chat).to receive(:with_schema).with(Aireview::GenerateOutputSchema).and_return(generate_chat)
    allow(generate_chat).to receive(:with_instructions).with('system prompt').and_return(generate_chat)
    allow(generate_chat).to receive(:ask).with('user prompt').and_return(generate_response)
    allow(critique_chat).to receive(:with_temperature).with(0.0).and_return(critique_chat)
    allow(critique_chat).to receive(:with_thinking).with(effort: :low).and_return(critique_chat)
    allow(critique_chat).to receive(:with_schema).with(Aireview::CritiqueOutputSchema).and_return(critique_chat)
    allow(critique_chat).to receive(:with_instructions).with('system prompt').and_return(critique_chat)
    allow(critique_chat).to receive(:ask).with('user prompt').and_return(critique_response)
    allow(fallback_chat).to receive(:with_temperature).and_return(fallback_chat)
    allow(fallback_chat).to receive(:with_schema).and_return(fallback_chat)
    allow(fallback_chat).to receive(:with_instructions).and_return(fallback_chat)
    allow(fallback_chat).to receive(:ask).with('user prompt').and_return(fallback_response)
  end

  it 'configures the provider and returns generate content' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('generate body')
    expect(context_configs.first.default_model).to eq('global-model')
    expect(context_configs.first.http_proxy).to eq('http://127.0.0.1:8888')
    expect(context_configs.first.gemini_api_key).to eq('secret-key')
    expect(context_configs.first.gemini_api_base).to eq('https://llm.example.test')
  end

  it 'uses a known model without bypassing the registry' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('generate body')
    expect(contexts.first)
      .to have_received(:chat)
      .with(model: 'gemini-3.7-flash', provider: :gemini)
    expect(generate_chat).to have_received(:with_temperature).with(0.3)
    expect(generate_chat).to have_received(:with_schema).with(Aireview::GenerateOutputSchema)
  end

  it 'uses critique model and temperature for the critique pass' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('critique body')
    expect(contexts.first)
      .to have_received(:chat)
      .with(model: 'gemini-3.8-flash', provider: :gemini)
    expect(critique_chat).to have_received(:with_temperature).with(0.0)
    expect(critique_chat).to have_received(:with_schema).with(Aireview::CritiqueOutputSchema)
  end

  it 'creates one isolated context per stage' do
    reviewer = described_class.new(config: config, logger: logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
    reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(RubyLLM).to have_received(:context).twice
    expect(context_configs.first).not_to equal(context_configs.last)
  end

  it 'retries an unknown model with an explicit provider' do
    allow(config).to receive(:stage_chain).with('generate').and_return([candidate('gemini', 'gemini-3.6-flash')])
    log_output = StringIO.new
    reviewer = described_class.new(config: config, logger: Logger.new(log_output))

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(contexts.first)
      .to have_received(:chat)
      .with(model: 'gemini-3.6-flash', provider: :gemini)
    expect(contexts.first)
      .to have_received(:chat)
      .with(model: 'gemini-3.6-flash', provider: :gemini, assume_model_exists: true)
    expect(log_output.string).to include(
      'LLM generate: model not found in RubyLLM registry; ' \
      'using fallback with incomplete model metadata ' \
      '(model=gemini-3.6-flash, provider=gemini)'
    )
  end

  it 'sets the RubyLLM request timeout from LLM_TIMEOUT and leaves retries to the router' do
    reviewer = described_class.new(config: config, logger: logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(context_configs.first.request_timeout).to eq(60.0)
    expect(context_configs.first.max_retries).to eq(0)
    expect(global_ruby_config.max_retries).to eq(3)
  end

  it 'logs stage start and completion for generate requests' do
    log_output = StringIO.new
    stage_logger = Logger.new(log_output)
    reviewer = described_class.new(config: config, logger: stage_logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(log_output.string).to include('LLM generate request started (model=gemini-3.7-flash, temperature=0.3)')
    expect(log_output.string).to include('LLM generate request completed (model=gemini-3.7-flash)')
  end

  def overloaded_error
    RubyLLM::ServiceUnavailableError.new('This model is currently experiencing high demand')
  end

  def quota_error(quota_id, message: 'You exceeded your current quota. Please retry in 55s.',
                  error_class: RubyLLM::RateLimitError)
    body = {
      'error' => {
        'code' => 429,
        'status' => 'RESOURCE_EXHAUSTED',
        'message' => message,
        'details' => [
          {'@type' => 'type.googleapis.com/google.rpc.QuotaFailure',
           'violations' => [{'quotaMetric' => 'generativelanguage.googleapis.com/generate_content_free_tier_requests',
                             'quotaId' => quota_id}]}
        ]
      }
    }
    error_class.new(Struct.new(:body).new(JSON.generate(body)), message)
  end

  def quiet_router(reviewer)
    router = reviewer.router
    allow(router).to receive(:sleep)
    allow(router).to receive(:rand).with(Aireview::LlmRouter::OVERLOADED_RETRY_JITTER_RANGE).and_return(1.0)
    allow(router).to receive(:rand).with(Aireview::LlmRouter::SHORT_RETRY_JITTER_RANGE).and_return(1.0)
    allow(router).to receive(:rand).with(Aireview::LlmRouter::PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE).and_return(2.0)
    router
  end

  context 'when the LLM service is temporarily unavailable' do
    it 'retries on a growing schedule and eventually succeeds' do
      log_output = StringIO.new
      reviewer = described_class.new(config: config, logger: Logger.new(log_output))
      router = quiet_router(reviewer)
      allow(router).to receive(:rand)
        .with(Aireview::LlmRouter::OVERLOADED_RETRY_JITTER_RANGE)
        .and_return(1.0, 1.1, 0.9, 1.0)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise overloaded_error if attempts <= 4

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(5)
      expect(router).to have_received(:sleep).with(120.0).once
      expect(router).to have_received(:sleep).with(330.0).once
      expect(router).to have_received(:sleep).with(270.0).once
      expect(router).to have_received(:sleep).with(300.0).once
      expect(log_output.string).to include(
        'LLM generate request will sleep 120.0s before retry (overloaded backoff 120s, multiplier 1.00x) ' \
        '(attempt 2/5, model=gemini-3.7-flash)'
      )
      expect(log_output.string).to include(
        'LLM generate request will sleep 300.0s before retry (overloaded backoff 300s, multiplier 1.00x) ' \
        '(attempt 5/5, model=gemini-3.7-flash)'
      )
      expect(reviewer.fallback_models).to eq({})
    end

    it 'raises a friendly API error once the schedule is exhausted' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(
        Aireview::ApiError,
        /LLM service is temporarily unavailable or overloaded: This model is currently experiencing high demand/
      )

      expect(generate_chat).to have_received(:ask).with('user prompt').exactly(5).times
      expect(router).to have_received(:sleep).with(120.0).once
      expect(router).to have_received(:sleep).with(300.0).exactly(3).times
    end

    context 'with a fallback model' do
      let(:generate_fallbacks) { [candidate('gemini', 'gemini-fallback')] }

      it 'gives the primary one short retry and then switches to the fallback with the same key' do
        log_output = StringIO.new
        reviewer = described_class.new(config: config, logger: Logger.new(log_output))
        router = quiet_router(reviewer)
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(generate_chat).to have_received(:ask).with('user prompt').twice
        expect(router).to have_received(:sleep).with(30.0).once
        expect(log_output.string).to include(
          'LLM generate request will sleep 30.0s before retry (attempt 2/2, model=gemini-3.7-flash)'
        )
        expect(log_output.string).to include(
          'LLM generate: switching to gemini/gemini-fallback after gemini/gemini-3.7-flash: overloaded after 2 attempt(s)'
        )
        expect(reviewer.fallback_models).to eq('generate' => 'gemini/gemini-fallback')
        expect(context_configs.size).to eq(1)
      end

      it 'gives the last model the full schedule and lists every route in the error' do
        reviewer = described_class.new(config: config, logger: logger)
        router = quiet_router(reviewer)
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)
        allow(fallback_chat).to receive(:ask).with('user prompt').and_raise(Timeout::Error)

        expect do
          reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
        end.to raise_error(
          Aireview::ApiError,
          'LLM generate request failed on every configured route: ' \
          'gemini/gemini-3.7-flash: overloaded after 2 attempt(s); ' \
          'gemini/gemini-fallback: timed out after 5 attempt(s). ' \
          'Try again later or switch model via --generate-model/--critique-model.'
        )
        expect(router).to have_received(:sleep).with(30.0).once
        expect(router).to have_received(:sleep).with(120.0).once
        expect(router).to have_received(:sleep).with(300.0).exactly(3).times
      end

      it 'skips a fallback whose prompt limit is smaller than the request' do
        log_output = StringIO.new
        allow(config).to receive(:stage_chain).with('generate').and_return(
          [candidate('gemini', 'gemini-3.7-flash'), candidate('gemini', 'gemini-fallback', max_prompt_chars: 10)]
        )
        reviewer = described_class.new(config: config, logger: Logger.new(log_output))
        quiet_router(reviewer)
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)

        expect do
          reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
        end.to raise_error(Aireview::ApiError, /gemini-fallback: skipped, request 24 chars over max_prompt_chars=10/)
        expect(fallback_chat).not_to have_received(:ask)
        expect(generate_chat).to have_received(:ask).exactly(5).times
      end

      it 'starts the repair request from the model that answered but keeps falling back' do
        reviewer = described_class.new(config: config, logger: logger)
        quiet_router(reviewer)
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)

        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
        second = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(second).to eq('fallback body')
        expect(generate_chat).to have_received(:ask).twice
        expect(fallback_chat).to have_received(:ask).twice
      end
    end
  end

  context 'when the daily quota is exhausted' do
    let(:gemini_keys) { %w[key-one key-two] }

    it 'switches to the next key without sleeping and remembers the exhausted pair' do
      log_output = StringIO.new
      reviewer = described_class.new(config: config, logger: Logger.new(log_output))
      router = quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier') if attempts == 1

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(3)
      expect(router).not_to have_received(:sleep)
      expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
      expect(log_output.string).to include(
        'LLM generate: switching to gemini/gemini-3.7-flash (key 2/2) after ' \
        'gemini/gemini-3.7-flash (key 1/2): daily quota exhausted after 1 attempt(s)'
      )
      expect(log_output.string).not_to include('key-one', 'key-two')
      expect(reviewer.fallback_models).to eq({})
    end

    it 'switches keys on an exhausted token quota even when RubyLLM reports it as a context length error' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        if attempts == 1
          raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier',
                            message: 'Quota exceeded for metric: generate_content_free_tier_input_token_count',
                            error_class: RubyLLM::ContextLengthExceededError)
        end

        generate_response
      end

      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(attempts).to eq(2)
      expect(router).not_to have_received(:sleep)
      expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
    end

    it 'treats a per-minute quota as a rate limit and retries with the provider hint' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise quota_error('GenerateRequestsPerMinutePerProjectPerModel-FreeTier') if attempts == 1

        generate_response
      end

      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(attempts).to eq(2)
      expect(router).to have_received(:sleep).with(110.0).once
      expect(context_configs.size).to eq(1)
    end

    it 'falls back on the message text when the response carries no quota details' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      allow(generate_chat).to receive(:ask).with('user prompt')
        .and_raise(RubyLLM::RateLimitError, 'Quota exceeded: 20 requests per day')

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(Aireview::ApiError, /key 1\/2\): daily quota exhausted.*key 2\/2\): daily quota exhausted/)
      expect(router).not_to have_received(:sleep)
    end

    context 'with a fallback model' do
      let(:generate_fallbacks) { [candidate('gemini', 'gemini-fallback')] }

      it 'moves to the next model with the first key once every key is exhausted' do
        reviewer = described_class.new(config: config, logger: logger)
        quiet_router(reviewer)
        allow(generate_chat).to receive(:ask).with('user prompt')
          .and_raise(quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier'))

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(generate_chat).to have_received(:ask).twice
        expect(fallback_chat).to have_received(:ask).once
        expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
        expect(reviewer.fallback_models).to eq('generate' => 'gemini/gemini-fallback')
      end

      it 'keeps the earlier key in reserve for the next model: its quota is per key and model' do
        reviewer = described_class.new(config: config, logger: logger)
        quiet_router(reviewer)
        attempts = 0
        allow(generate_chat).to receive(:ask).with('user prompt') do
          attempts += 1
          raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier') if attempts == 1

          raise overloaded_error
        end
        fallback_attempts = 0
        allow(fallback_chat).to receive(:ask).with('user prompt') do
          fallback_attempts += 1
          raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier') if fallback_attempts == 1

          fallback_response
        end

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(fallback_attempts).to eq(2)
        expect(contexts.last).to have_received(:chat).with(model: 'gemini-fallback', provider: :gemini)
        expect(contexts.first).to have_received(:chat).with(model: 'gemini-fallback', provider: :gemini)
      end

      it 'handles a quota on the first key and an overload on the second by moving to the next model' do
        reviewer = described_class.new(config: config, logger: logger)
        router = quiet_router(reviewer)
        attempts = 0
        allow(generate_chat).to receive(:ask).with('user prompt') do
          attempts += 1
          raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier') if attempts == 1

          raise overloaded_error
        end

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(attempts).to eq(3)
        expect(router).to have_received(:sleep).with(30.0).once
        expect(fallback_chat).to have_received(:ask).once
        expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
        expect(contexts.last).to have_received(:chat).with(model: 'gemini-fallback', provider: :gemini)
        expect(contexts.first).not_to have_received(:chat).with(model: 'gemini-fallback', provider: :gemini)
      end
    end
  end

  context 'when the LLM request is rate limited' do
    it 'retries with provider delay plus jitter and eventually succeeds' do
      log_output = StringIO.new
      reviewer = described_class.new(config: config, logger: Logger.new(log_output))
      router = quiet_router(reviewer)
      allow(router).to receive(:monotonic_time).and_return(0.0, 100.0, 100.0, 100.0, 100.0, 111.0)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry in 5.5s.' if attempts == 1

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(2)
      expect(router).to have_received(:sleep).with(11.0).once
      expect(log_output.string).to include(
        'LLM generate request will sleep 11.0s before retry (provider retry hint 5.5s, multiplier 2.00x) ' \
        '(attempt 2/4, model=gemini-3.7-flash)'
      )
      expect(log_output.string).to include('LLM generate retry wait completed after 11.0s (model=gemini-3.7-flash)')
    end

    it 'parses retry-after hints written in seconds' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry after 45 seconds.' if attempts == 1

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(2)
      expect(router).to have_received(:sleep).with(90.0).once
    end

    it 'starts the next request from the key that answered and keeps the earlier one in reserve' do
      allow(config).to receive(:provider_api_keys).with('gemini').and_return(%w[key-one key-two])
      reviewer = described_class.new(config: config, logger: logger)
      quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        case attempts
        when 1, 2 then raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry in 5s.'
        when 4 then raise quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier')
        else generate_response
        end
      end

      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      # key-one: два лимита в первом прогоне и ответ во втором; key-two: ответ в первом и квота во втором.
      expect(attempts).to eq(5)
      expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
      expect(contexts.first).to have_received(:chat).with(model: 'gemini-3.7-flash', provider: :gemini).exactly(3).times
      expect(contexts.last).to have_received(:chat).with(model: 'gemini-3.7-flash', provider: :gemini).twice
    end

    it 'gives a key one retry and then moves to the next key' do
      allow(config).to receive(:provider_api_keys).with('gemini').and_return(%w[key-one key-two])
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      attempts = 0
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry in 5s.' if attempts <= 2

        generate_response
      end

      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(attempts).to eq(3)
      expect(router).to have_received(:sleep).with(10.0).once
      expect(context_configs.map(&:gemini_api_key)).to eq(%w[key-one key-two])
    end
  end

  context 'when the time budget runs out' do
    let(:generate_fallbacks) { [candidate('gemini', 'gemini-fallback')] }

    it 'skips a pause that does not fit and fails once nothing is left' do
      log_output = StringIO.new
      allow(config).to receive(:llm_time_budget).and_return(100)
      reviewer = described_class.new(config: config, logger: Logger.new(log_output))
      router = quiet_router(reviewer)
      allow(router).to receive(:monotonic_time).and_return(0.0, 80.0, 80.0, 80.0, 80.0, 100.0)
      allow(generate_chat).to receive(:ask).with('user prompt').and_raise(overloaded_error)

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(Aireview::ApiError, /LLM time budget of 100s is exhausted/)
      expect(router).not_to have_received(:sleep)
      expect(log_output.string).to include('LLM generate: no time budget left for a 30s pause (20s remaining')
      expect(fallback_chat).not_to have_received(:ask)
    end

    it 'caps the request timeout by the remaining budget' do
      allow(config).to receive(:llm_time_budget).and_return(100)
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      allow(router).to receive(:monotonic_time).and_return(0.0, 70.0, 70.0)
      allow(Timeout).to receive(:timeout).with(30.0).and_return(generate_response)

      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(Timeout).to have_received(:timeout).with(30.0)
    end
  end

  context 'when the LLM context is too long' do
    it 'does not retry' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)
      allow(generate_chat).to receive(:ask)
        .with('user prompt')
        .and_raise(RubyLLM::ContextLengthExceededError, 'context is too long')

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(
        Aireview::ApiError,
        /LLM context limit exceeded: context is too long/
      )

      expect(generate_chat).to have_received(:ask).with('user prompt').once
      expect(router).not_to have_received(:sleep)
    end
  end

  context 'when the LLM request times out' do
    before do
      allow(Timeout).to receive(:timeout).with(60.0).and_raise(Timeout::Error)
    end

    it 'raises a friendly API error after the overloaded schedule' do
      reviewer = described_class.new(config: config, logger: logger)
      router = quiet_router(reviewer)

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(
        Aireview::ApiError,
        'LLM request timed out after 60 seconds. Try again later or switch model via --generate-model/--critique-model.'
      )
      expect(router).to have_received(:sleep).exactly(4).times
    end

    context 'with a fallback model' do
      let(:generate_fallbacks) { [candidate('gemini', 'gemini-fallback')] }

      it 'switches to the fallback model' do
        allow(Timeout).to receive(:timeout).and_call_original
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(Timeout::Error)
        reviewer = described_class.new(config: config, logger: logger)
        quiet_router(reviewer)

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(reviewer.fallback_models).to eq('generate' => 'gemini/gemini-fallback')
      end

      it 'treats a Faraday transport timeout the same way' do
        stub_const('Faraday::TimeoutError', Class.new(StandardError))
        allow(Timeout).to receive(:timeout).and_call_original
        allow(generate_chat).to receive(:ask).with('user prompt').and_raise(Faraday::TimeoutError, 'execution expired')
        reviewer = described_class.new(config: config, logger: logger)
        router = quiet_router(reviewer)

        result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

        expect(result).to eq('fallback body')
        expect(router).to have_received(:sleep).with(30.0).once
      end
    end
  end

  describe 'provider combinations' do
    [
      ['API to API', 'gemini', 'gemini'],
      ['Ollama to Ollama', 'ollama', 'ollama'],
      ['API to Ollama', 'gemini', 'ollama'],
      ['Ollama to API', 'ollama', 'gemini']
    ].each do |name, generate_value, critique_value|
      context name do
        let(:generate_provider) { generate_value }
        let(:critique_provider) { critique_value }

        it 'routes both stages without changing the global RubyLLM config' do
          global_config_before = global_ruby_config.to_h
          reviewer = described_class.new(config: config, logger: logger)

          reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
          reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

          expect(contexts.first)
            .to have_received(:chat)
            .with(model: 'gemini-3.7-flash', provider: generate_value.to_sym)
          expect(contexts.last)
            .to have_received(:chat)
            .with(model: 'gemini-3.8-flash', provider: critique_value.to_sym)
          expect(generate_chat).to have_received(:with_schema).with(Aireview::GenerateOutputSchema)
          expect(critique_chat).to have_received(:with_schema).with(Aireview::CritiqueOutputSchema)
          expect(global_ruby_config.to_h).to eq(global_config_before)
        end
      end
    end
  end

  context 'with ollama provider' do
    let(:generate_provider) { 'ollama' }

    it 'uses the native Ollama provider and API base' do
      reviewer = described_class.new(config: config, logger: logger)
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(contexts.first)
        .to have_received(:chat)
        .with(model: 'gemini-3.7-flash', provider: :ollama)
      expect(context_configs.first.ollama_api_base).to eq('http://localhost:11434/v1')
      expect(context_configs.first.openai_api_key).to eq(global_ruby_config.openai_api_key)
      expect(context_configs.first.openai_api_base).to eq(global_ruby_config.openai_api_base)
      expect(config).not_to have_received(:provider_api_key).with('ollama')
    end
  end

  context 'with an Ollama gpt-oss model' do
    let(:critique_provider) { 'ollama' }

    it 'limits reasoning so structured output is not exhausted by thinking tokens' do
      allow(config).to receive(:stage_chain).with('critique').and_return([candidate('ollama', 'gpt-oss:20b')])
      reviewer = described_class.new(config: config, logger: logger)

      reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(critique_chat).to have_received(:with_thinking).with(effort: :low)
      expect(critique_chat).to have_received(:with_schema).with(Aireview::CritiqueOutputSchema)
    end
  end

  context 'with openrouter provider' do
    let(:generate_provider) { 'openrouter' }

    it 'configures OpenRouter credentials and API base' do
      reviewer = described_class.new(config: config, logger: logger)
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(context_configs.first.openrouter_api_key).to eq('secret-key')
      expect(context_configs.first.openrouter_api_base).to eq('https://llm.example.test')
    end
  end
end
