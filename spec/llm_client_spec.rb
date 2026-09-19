require 'stringio'
require 'aireview/llm_client'
require 'aireview/model_candidate'
require 'aireview/output_schemas'

# The RubyLLM boundary: one request to one model with one key. The RubyLLM
# context is stubbed explicitly, chat is a double; the spec never touches the network.
RSpec.describe Aireview::LlmClient do
  let(:config) do
    instance_double(
      'Aireview::Config',
      llm_api_base: 'https://llm.example.test',
      ollama_api_base: 'http://localhost:11434/v1',
      llm_http_proxy: 'http://127.0.0.1:8888',
      llm_timeout: 60
    )
  end
  let(:log_output) { StringIO.new }
  let(:client) { described_class.new(config: config, logger: Logger.new(log_output)) }
  let(:context_configs) { [] }
  let(:contexts) { [] }
  let(:chat) { instance_double('RubyLLM::Chat') }
  let(:response) { instance_double('RubyLLM::Message', content: 'body') }
  let(:context_config_class) do
    Struct.new(:http_proxy, :request_timeout, :max_retries, :gemini_api_key, :gemini_api_base, :ollama_api_base,
               :openai_api_key, :openai_api_base, :openrouter_api_key, :openrouter_api_base, :anthropic_api_key,
               keyword_init: true)
  end
  let(:prompt) do
    described_class::Prompt.new(stage: 'generate', system: 'system prompt', user: 'user prompt',
                                temperature: 0.3, schema: Aireview::GenerateOutputSchema)
  end

  def candidate(provider, model)
    Aireview::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: 400_000)
  end

  def request(**options)
    client.request(prompt, **{candidate: candidate('gemini', 'gemini-3.7-flash'), key: 'secret-key', timeout: 45.0}
      .merge(options))
  end

  before do
    allow(RubyLLM).to receive(:context) do |&block|
      context_config = context_config_class.new(max_retries: 3)
      block.call(context_config)
      context = instance_double('RubyLLM::Context')
      allow(context).to receive(:chat).and_return(chat)
      context_configs << context_config
      contexts << context
      context
    end
    allow(chat).to receive(:with_temperature).and_return(chat)
    allow(chat).to receive(:with_schema).and_return(chat)
    allow(chat).to receive(:with_thinking).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:ask).with('user prompt').and_return(response)
  end

  it 'sends the prompt to the model with its schema and temperature within the given timeout' do
    allow(Timeout).to receive(:timeout).with(45.0).and_call_original

    expect(request).to eq(response)
    expect(contexts.first).to have_received(:chat).with(model: 'gemini-3.7-flash', provider: :gemini)
    expect(chat).to have_received(:with_temperature).with(0.3)
    expect(chat).to have_received(:with_schema).with(Aireview::GenerateOutputSchema)
    expect(chat).to have_received(:with_instructions).with('system prompt')
    expect(Timeout).to have_received(:timeout).with(45.0)
    expect(log_output.string).to include('LLM generate request started (model=gemini-3.7-flash, temperature=0.3)')
    expect(log_output.string).to include('LLM generate request completed (model=gemini-3.7-flash)')
  end

  it 'builds an isolated context with the key, base, proxy and timeout, and leaves retries to the router' do
    global_key = RubyLLM.config.gemini_api_key
    request

    expect(context_configs.first.to_h.compact).to eq(
      http_proxy: 'http://127.0.0.1:8888', request_timeout: 60.0, max_retries: 0,
      gemini_api_key: 'secret-key', gemini_api_base: 'https://llm.example.test'
    )
    expect(RubyLLM.config.gemini_api_key).to eq(global_key)
  end

  it 'reuses the context of a stage, provider and key, and builds another for another key' do
    request
    request
    request(key: 'second-key', key_index: 1)
    client.request(prompt.dup.tap { |p| p.stage = 'critique' }, candidate: candidate('gemini', 'gemini-3.7-flash'),
                                                                key: 'secret-key', timeout: 45.0)

    expect(RubyLLM).to have_received(:context).exactly(3).times
    expect(context_configs.map(&:gemini_api_key)).to eq(%w[secret-key second-key secret-key])
  end

  it 'retries a model unknown to the RubyLLM registry with an explicit provider' do
    context = instance_double('RubyLLM::Context')
    allow(RubyLLM).to receive(:context).and_return(context)
    allow(context).to receive(:chat).with(model: 'gemini-x', provider: :gemini).and_raise(RubyLLM::ModelNotFoundError)
    allow(context).to receive(:chat).with(model: 'gemini-x', provider: :gemini, assume_model_exists: true).and_return(chat)

    expect(request(candidate: candidate('gemini', 'gemini-x'))).to eq(response)
    expect(log_output.string).to include(
      'LLM generate: model not found in RubyLLM registry; using fallback with incomplete model metadata ' \
      '(model=gemini-x, provider=gemini)'
    )
  end

  it 'lets a timeout through after logging it' do
    allow(Timeout).to receive(:timeout).with(45.0).and_raise(Timeout::Error)

    expect { request }.to raise_error(Timeout::Error)
    expect(log_output.string).to include('LLM generate request timed out after 45 seconds (model=gemini-3.7-flash)')
  end

  it 'lets provider errors through untouched for the classifier' do
    allow(chat).to receive(:ask).and_raise(RubyLLM::ServiceUnavailableError.new('high demand'))

    expect { request }.to raise_error(RubyLLM::ServiceUnavailableError, 'high demand')
  end

  context 'with Ollama' do
    it 'uses the native provider with its API base and no key' do
      request(candidate: candidate('ollama', 'qwen2.5-coder:7b'), key: nil)

      expect(contexts.first).to have_received(:chat).with(model: 'qwen2.5-coder:7b', provider: :ollama)
      expect(context_configs.first.ollama_api_base).to eq('http://localhost:11434/v1')
      expect(context_configs.first.gemini_api_key).to be_nil
    end

    it 'limits the reasoning of gpt-oss so structured output is not exhausted by thinking tokens' do
      request(candidate: candidate('ollama', 'gpt-oss:20b'), key: nil)
      expect(chat).to have_received(:with_thinking).with(effort: :low)

      request(candidate: candidate('ollama', 'qwen2.5-coder:7b'), key: nil)
      expect(chat).to have_received(:with_thinking).once
    end
  end

  # Providers reachable through LLM_PROVIDER + LLM_API_KEY although the image
  # defaults do not carry them: the key and the API base go into that provider's fields.
  describe 'other providers' do
    it 'configures OpenRouter and OpenAI with the generic key and API base' do
      request(candidate: candidate('openrouter', 'openrouter/auto'), key: 'router-key')
      request(candidate: candidate('openai', 'gpt-x'), key: 'openai-key')

      expect(context_configs[0].to_h.compact).to include(openrouter_api_key: 'router-key',
                                                          openrouter_api_base: 'https://llm.example.test')
      expect(context_configs[0].gemini_api_key).to be_nil
      expect(context_configs[1].to_h.compact).to include(openai_api_key: 'openai-key',
                                                          openai_api_base: 'https://llm.example.test')
      expect(contexts[0]).to have_received(:chat).with(model: 'openrouter/auto', provider: :openrouter)
    end

    it 'configures Anthropic with the key only' do
      request(candidate: candidate('anthropic', 'claude-x'), key: 'anthropic-key')

      expect(context_configs.first.to_h.compact).to eq(http_proxy: 'http://127.0.0.1:8888', request_timeout: 60.0,
                                                       max_retries: 0, anthropic_api_key: 'anthropic-key')
    end

    it 'leaves the API base alone when none is configured' do
      allow(config).to receive(:llm_api_base).and_return(nil)
      request

      expect(context_configs.first.gemini_api_base).to be_nil
    end
  end

  it 'rejects an unknown provider' do
    expect { request(candidate: candidate('mistral', 'm')) }
      .to raise_error(Aireview::ConfigError, 'Unsupported LLM provider: "mistral"')
  end

  it 'turns a missing ruby_llm into a configuration error' do
    allow(client).to receive(:require).with('ruby_llm').and_raise(LoadError, 'cannot load such file -- ruby_llm')

    expect { request }.to raise_error(Aireview::ConfigError, 'Missing dependency: cannot load such file -- ruby_llm')
  end
end
