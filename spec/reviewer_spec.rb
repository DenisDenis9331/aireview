require 'aireview/reviewer'
require 'stringio'

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
      generate_model: 'gemini-2.5-pro',
      generate_temperature: 0.3,
      critique_model: 'gemini-2.5-flash-lite',
      critique_temperature: 0,
      llm_timeout: 60
    )
  end

  let(:generate_provider) { 'gemini' }
  let(:critique_provider) { 'gemini' }
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
    stub_const('RubyLLM', Module.new)
    stub_const('RubyLLM::Error', Class.new(StandardError))
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
        .with(model: 'gemini-2.5-pro', provider: anything)
        .and_return(generate_chat)
      allow(context).to receive(:chat)
        .with(model: 'gemini-2.5-flash-lite', provider: anything)
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
      .with(model: 'gemini-2.5-pro', provider: :gemini)
    expect(generate_chat).to have_received(:with_temperature).with(0.3)
    expect(generate_chat).to have_received(:with_schema).with(Aireview::GenerateOutputSchema)
  end

  it 'uses critique model and temperature for the critique pass' do
    reviewer = described_class.new(config: config, logger: logger)
    result = reviewer.critique(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(result).to eq('critique body')
    expect(contexts.first)
      .to have_received(:chat)
      .with(model: 'gemini-2.5-flash-lite', provider: :gemini)
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
    allow(config).to receive(:generate_model).and_return('gemini-3.6-flash')
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

  it 'sets the RubyLLM request timeout from LLM_TIMEOUT' do
    reviewer = described_class.new(config: config, logger: logger)

    reviewer.generate(system_prompt: 'system prompt', user_prompt: 'user prompt')

    expect(context_configs.first.request_timeout).to eq(60.0)
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
            .with(model: 'gemini-2.5-pro', provider: generate_value.to_sym)
          expect(contexts.last)
            .to have_received(:chat)
            .with(model: 'gemini-2.5-flash-lite', provider: critique_value.to_sym)
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
        .with(model: 'gemini-2.5-pro', provider: :ollama)
      expect(context_configs.first.ollama_api_base).to eq('http://localhost:11434/v1')
      expect(context_configs.first.openai_api_key).to eq(global_ruby_config.openai_api_key)
      expect(context_configs.first.openai_api_base).to eq(global_ruby_config.openai_api_base)
      expect(config).not_to have_received(:provider_api_key).with('ollama')
    end
  end

  context 'with an Ollama gpt-oss model' do
    let(:critique_provider) { 'ollama' }

    it 'limits reasoning so structured output is not exhausted by thinking tokens' do
      allow(config).to receive(:critique_model).and_return('gpt-oss:20b')
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
