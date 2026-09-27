# frozen_string_literal: true

require 'aireview/llm_client'
require 'aireview/model_candidate'
require 'aireview/output_schemas'

# The real RubyLLM 2 request, built by chat.render without the network: RubyLLM 2
# no longer replaces the temperature for OpenAI reasoning models as 1.x did,
# and gpt-5 with temperature: 0 would get a BadRequest, fatal for the router.
RSpec.describe 'LlmClient request as RubyLLM renders it' do
  let(:config) do
    instance_double('Aireview::Config', llm_api_base: nil, ollama_api_base: 'http://localhost:11434/v1',
                                        llm_http_proxy: nil, llm_timeout: 60)
  end
  let(:client) { Aireview::LlmClient.new(config: config, logger: Logger.new(File::NULL)) }
  let(:prompt) do
    Aireview::LlmClient::Prompt.new(stage: 'critique', system: 'system', user: 'user', temperature: 0,
                                    schema: Aireview::CritiqueOutputSchema)
  end

  def payload(provider, model, api_base: nil)
    candidate = Aireview::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: 1, api_base: api_base)
    chat = client.prepare(prompt, candidate: candidate, key: 'key')
    chat.ask_later('probe')
    chat.render
  end

  it 'leaves the temperature out for the models that reject it, by the registry' do
    expect(payload('openai', 'gpt-5')).not_to have_key(:temperature)
    expect(payload('openai', 'o3')).not_to have_key(:temperature)
    expect(payload('openrouter', 'openai/gpt-5')).not_to have_key(:temperature)
  end

  it 'leaves it out by the name where the registry does not say, as RubyLLM 1.x did' do
    expect(payload('openai', 'gpt-5.9-next')).not_to have_key(:temperature)
    expect(payload('openai', 'gpt-4o-search-preview')).not_to have_key(:temperature)
    expect(payload('openai', 'gpt-4o-mini-search-preview-2025-03-11')).not_to have_key(:temperature)
  end

  it 'sends it to the models that take it and to a server of your own' do
    expect(payload('openai', 'gpt-4o')[:temperature]).to eq(0.0)
    expect(payload('anthropic', 'claude-sonnet-4-5')[:temperature]).to eq(0.0)
    expect(payload('gemini', 'gemini-2.5-flash').dig(:generationConfig, :temperature)).to eq(0.0)
    expect(payload('openai', 'qwen3-coder', api_base: 'http://gpu1:8000/v1')[:temperature]).to eq(0.0)
  end
end
