require 'aireview/reviewer'
require 'stringio'

RSpec.describe Aireview::Reviewer do
  let(:config) do
    instance_double(
      'Aireview::Config',
      require_llm_configuration!: true,
      llm_provider: provider,
      provider_api_key: 'secret-key',
      llm_api_base: 'https://llm.example.test',
      llm_http_proxy: 'http://127.0.0.1:8888',
      llm_temperature: 0.2,
      generate_model: 'gemini-2.5-pro',
      generate_temperature: 0.3,
      critique_model: 'gemini-2.5-flash-lite',
      critique_temperature: 0,
      llm_timeout: 60
    )
  end

  let(:provider) { 'gemini' }
  let(:logger) { Logger.new(nil) }
  let(:generate_chat) { instance_double('RubyLLM::Chat') }
  let(:critique_chat) { instance_double('RubyLLM::Chat') }
  let(:generate_response) { instance_double('RubyLLM::Message', content: 'generate body') }
  let(:critique_response) { instance_double('RubyLLM::Message', content: 'critique body') }

  before do
    allow_any_instance_of(described_class).to receive(:require).with('ruby_llm').and_return(true)
    stub_const('RubyLLM', Module.new)
    stub_const('RubyLLM::Error', Class.new(StandardError))
    stub_const('RubyLLM::ServiceUnavailableError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::OverloadedError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::RateLimitError', Class.new(RubyLLM::Error))
    stub_const('RubyLLM::ContextLengthExceededError', Class.new(RubyLLM::Error))
    RubyLLM.singleton_class.attr_accessor :configured

    allow(RubyLLM).to receive(:configure) do |&block|
      config_object = Struct.new(
        :default_model,
        :http_proxy,
        :gemini_api_key,
        :gemini_api_base,
        :openai_api_key,
        :openai_api_base,
        :openai_use_system_role,
        :openrouter_api_key,
        :openrouter_api_base,
        :anthropic_api_key
      ).new
      block.call(config_object)
      RubyLLM.configured = config_object
    end

    allow(RubyLLM).to receive(:chat).with(model: 'gemini-2.5-pro').and_return(generate_chat)
    allow(RubyLLM).to receive(:chat).with(model: 'gemini-2.5-flash-lite').and_return(critique_chat)
    allow(generate_chat).to receive(:with_temperature).with(0.3).and_return(generate_chat)
    allow(generate_chat).to receive(:with_instructions).with('system prompt').and_return(generate_chat)
    allow(generate_chat).to receive(:ask).with('user prompt').and_return(generate_response)
    allow(critique_chat).to receive(:with_temperature).with(0.0).and_return(critique_chat)
    allow(critique_chat).to receive(:with_instructions).with('system prompt').and_return(critique_chat)
    allow(critique_chat).to receive(:ask).with('user prompt').and_return(critique_response)
  end

  it 'configures the provider and returns generate content' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('generate body')
    expect(RubyLLM.configured.default_model).to be_nil
    expect(RubyLLM.configured.http_proxy).to eq('http://127.0.0.1:8888')
    expect(RubyLLM.configured.gemini_api_key).to eq('secret-key')
    expect(RubyLLM.configured.gemini_api_base).to eq('https://llm.example.test')
  end

  it 'uses generate model and temperature for the generate pass' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('generate body')
    expect(RubyLLM).to have_received(:chat).with(model: 'gemini-2.5-pro')
    expect(generate_chat).to have_received(:with_temperature).with(0.3)
  end

  it 'uses critique model and temperature for the critique pass' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('critique body')
    expect(RubyLLM).to have_received(:chat).with(model: 'gemini-2.5-flash-lite')
    expect(critique_chat).to have_received(:with_temperature).with(0.0)
  end

  it 'configures RubyLLM once per reviewer instance' do
    reviewer = described_class.new(config: config, logger: logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
    reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(RubyLLM).to have_received(:configure).once
  end

  it 'logs stage start and completion for generate requests' do
    log_output = StringIO.new
    stage_logger = Logger.new(log_output)
    reviewer = described_class.new(config: config, logger: stage_logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(log_output.string).to include('LLM generate request started (model=gemini-2.5-pro, temperature=0.3)')
    expect(log_output.string).to include('LLM generate request completed (model=gemini-2.5-pro)')
  end

  context 'when the LLM service is temporarily unavailable' do
    it 'raises a friendly API error' do
      reviewer = described_class.new(config: config, logger: logger)
      allow(reviewer).to receive(:rand).with(described_class::OVERLOADED_RETRY_DELAY_RANGE).and_return(120.0, 135.0)
      allow(reviewer).to receive(:sleep)
      allow(generate_chat).to receive(:ask)
        .with('user prompt')
        .and_raise(RubyLLM::ServiceUnavailableError, 'This model is currently experiencing high demand')

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(
        Aireview::ApiError,
        /LLM service is temporarily unavailable or overloaded: This model is currently experiencing high demand/
      )

      expect(generate_chat).to have_received(:ask).with('user prompt').exactly(3).times
      expect(reviewer).to have_received(:sleep).with(120.0).once
      expect(reviewer).to have_received(:sleep).with(135.0).once
    end
  end

  context 'when the LLM request is rate limited' do
    it 'retries with provider delay plus jitter and eventually succeeds' do
      log_output = StringIO.new
      retry_logger = Logger.new(log_output)
      reviewer = described_class.new(config: config, logger: retry_logger)
      attempts = 0
      allow(reviewer).to receive(:rand).with(described_class::PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE).and_return(2.0)
      allow(reviewer).to receive(:sleep)
      allow(reviewer).to receive(:monotonic_time).and_return(100.0, 111.0)
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry in 5.5s.' if attempts == 1

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(2)
      expect(reviewer).to have_received(:sleep).with(11.0).once
      expect(log_output.string).to include('LLM generate request will sleep 11.0s before retry (provider retry hint 5.5s, multiplier 2.00x)')
      expect(log_output.string).to include('LLM generate retry wait completed after 11.0s (model=gemini-2.5-pro)')
    end

    it 'parses retry-after hints written in seconds' do
      reviewer = described_class.new(config: config, logger: logger)
      attempts = 0
      allow(reviewer).to receive(:rand).with(described_class::PROVIDER_RETRY_DELAY_MULTIPLIER_RANGE).and_return(2.0)
      allow(reviewer).to receive(:sleep)
      allow(generate_chat).to receive(:ask).with('user prompt') do
        attempts += 1
        raise RubyLLM::RateLimitError, 'Quota exceeded. Please retry after 45 seconds.' if attempts == 1

        generate_response
      end

      result = reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(result).to eq('generate body')
      expect(attempts).to eq(2)
      expect(reviewer).to have_received(:sleep).with(90.0).once
    end
  end

  context 'when the LLM context is too long' do
    it 'does not retry' do
      reviewer = described_class.new(config: config, logger: logger)
      allow(reviewer).to receive(:sleep)
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
      expect(reviewer).not_to have_received(:sleep)
    end
  end

  context 'when the LLM request times out' do
    before do
      allow(Timeout).to receive(:timeout).with(60.0).and_raise(Timeout::Error)
    end

    it 'raises a friendly API error' do
      reviewer = described_class.new(config: config, logger: logger)

      expect do
        reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')
      end.to raise_error(
        Aireview::ApiError,
        'LLM request timed out after 60 seconds. Try again later or switch model via --generate-model/--critique-model.'
      )
    end
  end

  context 'with ollama provider' do
    let(:provider) { 'ollama' }

    before do
      allow(config).to receive(:provider_api_key).with('ollama').and_return(nil)
    end

    it 'uses openai-compatible configuration defaults' do
      reviewer = described_class.new(config: config, logger: logger)
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(RubyLLM.configured.openai_api_key).to eq('ollama')
      expect(RubyLLM.configured.openai_api_base).to eq('https://llm.example.test')
      expect(RubyLLM.configured.openai_use_system_role).to eq(true)
    end
  end

  context 'with openrouter provider' do
    let(:provider) { 'openrouter' }

    it 'configures OpenRouter credentials and API base' do
      reviewer = described_class.new(config: config, logger: logger)
      reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

      expect(RubyLLM.configured.openrouter_api_key).to eq('secret-key')
      expect(RubyLLM.configured.openrouter_api_base).to eq('https://llm.example.test')
    end
  end
end
