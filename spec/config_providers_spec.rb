# frozen_string_literal: true

require 'tmpdir'
require 'aireview/config'

# A pool of models from several providers and servers of your own, ordered
# by strength: the keys of each provider come from its own variables, and a
# server of your own never gets a provider's key.
RSpec.describe 'Config with several providers' do
  def load(env: {}, yaml: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
      Aireview::Config.load(cwd: dir, env: env, logger: Logger.new(nil))
    end
  end

  let(:keys) do
    {'GEMINI_API_KEY' => 'g', 'OPENAI_API_KEYS' => 'o1,o2', 'ANTHROPIC_API_KEY' => 'a', 'OPENROUTER_API_KEY' => 'r'}
  end
  let(:mixed) { 'anthropic/claude-opus-4.5,openai/gpt-5,gemini/gemini-3.8-flash,openrouter/qwen/qwen3-coder' }

  it 'reads the keys of every provider from its own variables' do
    config = load(env: keys)

    expect(config.provider_api_keys('gemini')).to eq(['g'])
    expect(config.provider_api_keys('openai')).to eq(%w[o1 o2])
    expect(config.provider_api_keys('anthropic')).to eq(['a'])
    expect(config.provider_api_keys('openrouter')).to eq(['r'])
    expect(Aireview::Config.env_names).to include('OPENAI_API_KEY', 'OPENAI_API_KEYS', 'ANTHROPIC_API_KEY',
                                                  'ANTHROPIC_API_KEYS', 'OPENROUTER_API_KEY', 'OPENROUTER_API_KEYS')
  end

  it 'orders a mixed pool as written, the provider named in front of each model' do
    config = load(env: keys.merge('LLM_MODELS' => mixed, 'LLM_GENERATE_START' => 'gemini-3.8-flash'))

    expect(config.stage_chain('critique').map(&:to_s))
      .to eq(%w[anthropic/claude-opus-4.5 openai/gpt-5 gemini/gemini-3.8-flash openrouter/qwen/qwen3-coder])
    expect(config.critique_model).to eq('claude-opus-4.5')
    expect(config.generate_model).to eq('gemini-3.8-flash')
    expect { config.require_llm_configuration! }.not_to raise_error
  end

  it 'wants the key of every provider in the pool' do
    config = load(env: keys.except('ANTHROPIC_API_KEY').merge('LLM_MODELS' => mixed))

    expect { config.require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /API key is required for provider "anthropic"/)
  end

  describe 'servers of your own' do
    let(:yaml) do
      <<~YAML
        llm:
          models:
            - provider: anthropic
              model: claude-opus-4.5
            - provider: openai
              model: qwen3-coder
              api_base: http://gpu1:8000/v1
            - provider: openai
              model: qwen3-coder
              api_base: http://gpu2:8000/v1
          generate:
            start: openai/qwen3-coder@http://gpu2:8000/v1
      YAML
    end

    it 'keeps two servers with the same model apart, by the address in the name' do
      config = load(env: {'ANTHROPIC_API_KEY' => 'a'}, yaml: yaml)

      expect(config.stage_chain('generate').map(&:to_s))
        .to eq(%w[openai/qwen3-coder@http://gpu2:8000/v1 anthropic/claude-opus-4.5 openai/qwen3-coder@http://gpu1:8000/v1])
      expect(config.routing.signature['models']).to include('openai/qwen3-coder@http://gpu1:8000/v1')
    end

    it 'tells http and https apart: another scheme is another server' do
      both = "llm:\n  models:\n    - {provider: openai, model: local, api_base: http://gpu/v1}\n" \
             "    - {provider: openai, model: local, api_base: https://gpu/v1}\n"
      https = "llm:\n  models:\n    - {provider: openai, model: local, api_base: https://gpu/v1}\n"
      http = "llm:\n  models:\n    - {provider: openai, model: local, api_base: http://gpu/v1}\n"

      expect(load(yaml: both).stage_chain('generate').map(&:to_s))
        .to eq(%w[openai/local@http://gpu/v1 openai/local@https://gpu/v1])
      expect(load(yaml: https).routing.signature).not_to eq(load(yaml: http).routing.signature)
    end

    it 'starts the critique from a server named as provider/model, as the config check accepts it' do
      pool = <<~YAML
        llm:
          models:
            - {provider: anthropic, model: strong}
            - {provider: openai, model: local, api_base: http://gpu/v1}
            - {provider: ollama, model: small}
          generate:
            start: small
          critique:
            start: openai/local
      YAML
      config = load(env: {'ANTHROPIC_API_KEY' => 'a'}, yaml: pool)
      small = config.stage_chain('generate').first

      expect { config.require_llm_configuration! }.not_to raise_error
      expect(config.routing.critique_chain(after: small).map(&:to_s).first).to eq('openai/local@http://gpu/v1')
      expect(config.routing.warnings).to be_empty
    end

    it 'needs no key for them and never sends them the key of the provider' do
      config = load(env: {'ANTHROPIC_API_KEY' => 'a', 'OPENAI_API_KEY' => 'real-openai-key'}, yaml: yaml)
      server = config.stage_chain('critique').find(&:api_base)

      expect { config.require_llm_configuration! }.not_to raise_error
      expect(config.candidate_api_keys(server)).to eq(['no-key'])
      expect(config.api_key_counts(%w[generate critique])).to eq('anthropic' => 1)

      with_generic = load(env: {'ANTHROPIC_API_KEY' => 'a', 'LLM_API_KEY' => 'server-key'}, yaml: yaml)
      expect(with_generic.candidate_api_keys(server)).to eq(['server-key'])
    end

    it 'takes the address of a stage and of a reserve, and rejects one that is not a URL' do
      stage = "llm:\n  generate:\n    model: qwen3-coder\n    provider: openai\n    api_base: http://gpu1:8000/v1\n" \
              "    fallbacks:\n      - provider: ollama\n        model: qwen2.5-coder:7b\n" \
              "        api_base: http://gpu3:11434/v1\n  critique:\n    model: gemini-3.8-flash\n"
      config = load(env: {'GEMINI_API_KEY' => 'g'}, yaml: stage)

      expect(config.stage_chain('generate').map(&:to_s))
        .to eq(%w[openai/qwen3-coder@http://gpu1:8000/v1 ollama/qwen2.5-coder:7b@http://gpu3:11434/v1])
      expect(config.result_signature['generate']).to eq(['openai', 'qwen3-coder', 0, 'http://gpu1:8000/v1'])
      expect { load(yaml: "llm:\n  models:\n    - model: x\n      api_base: gpu1:8000\n").routing }
        .to raise_error(Aireview::ConfigError, /llm.models\[0\].api_base must be an http\(s\) URL/)
    end
  end
end
