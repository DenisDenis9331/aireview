# frozen_string_literal: true

require 'tmpdir'
require 'aireview/config'

RSpec.describe Aireview::ConfigJev do
  def load(env: {}, yaml: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
      Aireview::Config.load(cwd: dir, env: {'GEMINI_API_KEY' => 'g'}.merge(env), logger: Logger.new(nil))
    end
  end

  it 'is off by default, with a pinned model and provisional thresholds' do
    config = load

    expect(config.jev_shadow?).to be(false)
    expect(config.jev_model).to eq('jev-1.13.0')
    expect(config.jev_timeout).to eq(10)
    expect(config.jev_thresholds).to eq(keep_above: 0.5, enough_context: 0.5, version_claim: 0.5, duplicate: 0.5)
    expect(config.warnings).to be_empty
  end

  it 'reads the shadow switch, the model and the key from the environment' do
    config = load(env: {'LLM_JEV_SHADOW' => 'true', 'LLM_JEV_MODEL' => 'jev-1.14.0', 'JEV_API_KEY' => 'j'})

    expect(config.jev_shadow?).to be(true)
    expect(config.jev_model).to eq('jev-1.14.0')
    expect(config.jev_api_key).to eq('j')
    expect(config.warnings).to be_empty
  end

  it 'reads thresholds from .aireview.yml and rejects values outside 0..1' do
    config = load(yaml: "llm:\n  jev:\n    shadow: true\n    keep_above: 0.7\n    timeout: 5\n")

    expect(config.jev_thresholds).to include(keep_above: 0.7, duplicate: 0.5)
    expect(config.jev_timeout).to eq(5)
    expect { load(yaml: "llm:\n  jev:\n    duplicate: 1.5\n").jev_thresholds }
      .to raise_error(Aireview::ConfigError, /llm.jev.duplicate must be a number from 0 to 1/)
  end

  it 'rejects a shadow switch that is not a boolean' do
    expect { load(env: {'LLM_JEV_SHADOW' => 'maybe'}) }.to raise_error(Aireview::ConfigError, /LLM_JEV_SHADOW/)
    expect { load(yaml: "llm:\n  jev:\n    shadow: yes please\n").jev_shadow? }
      .to raise_error(Aireview::ConfigError, /llm.jev.shadow must be true or false/)
  end

  it 'warns in shadow mode about a missing key and an alias instead of a version' do
    warnings = load(env: {'LLM_JEV_SHADOW' => 'true', 'LLM_JEV_MODEL' => 'jev-latest'}).warnings

    expect(warnings).to include(/JEV_API_KEY is not set: Jev is skipped/, /"jev-latest" is an alias/)
  end

  it 'keeps the shadow out of the review key' do
    expect(load(env: {'LLM_JEV_SHADOW' => 'true', 'JEV_API_KEY' => 'j'}).result_signature)
      .to eq(load.result_signature)
  end
end

RSpec.describe 'Jev as the critique engine in the config' do
  def load(env: {}, yaml: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
      Aireview::Config.load(cwd: dir, env: env, logger: Logger.new(nil))
    end
  end

  let(:ollama_jev) do
    {'LLM_PROVIDER' => 'ollama', 'LLM_GENERATE_MODEL' => 'qwen2.5-coder:7b', 'LLM_CRITIQUE_ENGINE' => 'jev',
     'JEV_API_KEY' => 'j'}
  end

  it 'defaults to the model engine with the model fallback' do
    config = load(env: {'GEMINI_API_KEY' => 'g'})

    expect(config.critique_engine).to eq('model')
    expect(config.jev_fallback).to eq('model')
    expect(config.jev_critique?).to be(false)
    expect(config.llm_stages).to eq(%w[generate critique])
    expect(config.llm_stages(critique: false)).to eq(%w[generate])
    expect(config.jev_signature).to be_nil
  end

  it 'reads the engine, the fallback and the keep threshold from env, YAML and the CLI' do
    from_env = load(env: {'LLM_CRITIQUE_ENGINE' => 'jev', 'LLM_JEV_FALLBACK' => 'fail', 'LLM_JEV_KEEP_ABOVE' => '0.7'})
    from_yaml = load(yaml: "llm:\n  critique:\n    engine: jev\n  jev:\n    fallback: fail\n")
    from_cli = load.with_overrides(critique_engine: 'jev')

    expect([from_env, from_yaml, from_cli].map(&:critique_engine)).to eq(%w[jev jev jev])
    expect(from_env.jev_fallback).to eq('fail')
    expect(from_env.jev_thresholds[:keep_above]).to eq(0.7)
    expect(from_env.jev_signature).to eq(['jev', 'jev-1.13.0', 0.7, 0.5, 0.5, 0.5, 'fail'])
    expect(from_cli.jev_fallback).to eq('model')
  end

  it 'rejects unknown engines, fallbacks and a threshold that is not a number' do
    expect { load(env: {'LLM_CRITIQUE_ENGINE' => 'llm'}).critique_engine }
      .to raise_error(Aireview::ConfigError, /llm.critique.engine must be one of model, jev, got "llm"/)
    expect { load(env: {'LLM_JEV_FALLBACK' => 'skip'}).jev_fallback }
      .to raise_error(Aireview::ConfigError, /llm.jev.fallback must be one of model, fail/)
    expect { load(env: {'LLM_JEV_KEEP_ABOVE' => '0,7'}).jev_thresholds }
      .to raise_error(Aireview::ConfigError, /llm.jev.keep_above must be a number from 0 to 1, got "0,7"/)
  end

  it 'needs an LLM critique only when Jev can fall back to it' do
    fallback_model = load(env: {'LLM_CRITIQUE_ENGINE' => 'jev'})
    fallback_fail = load(env: {'LLM_CRITIQUE_ENGINE' => 'jev', 'LLM_JEV_FALLBACK' => 'fail'})

    expect(fallback_model.llm_stages).to eq(%w[generate critique])
    expect(fallback_fail.llm_stages).to eq(%w[generate])
    expect(fallback_fail.llm_stages(critique: false)).to eq(%w[generate])
    expect(fallback_fail.jev_critique?(critique: false)).to be(false)
  end

  it 'starts generate on Ollama with Jev and no fallback without a Gemini key' do
    config = load(env: ollama_jev.merge('LLM_JEV_FALLBACK' => 'fail'))

    expect { config.require_llm_configuration! }.not_to raise_error
  end

  it 'still wants the key of the LLM critique when Jev falls back to it' do
    config = load(env: ollama_jev.merge('LLM_CRITIQUE_PROVIDER' => 'gemini', 'LLM_CRITIQUE_MODEL' => 'gemini-3.8-flash'))

    expect { config.require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /critique: API key is required for provider "gemini"/)
  end

  it 'wants a Jev key and a pinned version, but not with --no-critique' do
    no_key = load(env: ollama_jev.merge('JEV_API_KEY' => '', 'LLM_JEV_FALLBACK' => 'fail'))
    alias_model = load(env: ollama_jev.merge('LLM_JEV_MODEL' => 'jev-latest', 'LLM_JEV_FALLBACK' => 'fail'))

    expect { no_key.require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /engine is jev, but JEV_API_KEY is not set/)
    expect { alias_model.require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /"jev-latest" is an alias; with llm.critique.engine: jev pin a version/)
    expect { no_key.require_llm_configuration!(critique: false) }.not_to raise_error
  end

  it 'builds the pool without a critique policy when no LLM critique can run' do
    yaml = <<~YAML
      llm:
        models: [gemini-3.8-flash, gemini-3.7-flash]
        critique:
          start: gemini-9-missing
          rank: any
    YAML
    env = {'GEMINI_API_KEY' => 'g', 'JEV_API_KEY' => 'j', 'LLM_CRITIQUE_ENGINE' => 'jev'}

    expect { load(env: env, yaml: yaml).require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /gemini-9-missing is not in llm.models/)
    without_policy = load(env: env.merge('LLM_JEV_FALLBACK' => 'fail'), yaml: yaml)
    expect { without_policy.require_llm_configuration! }.not_to raise_error
    expect(without_policy.routing.signature)
      .to eq('models' => %w[gemini/gemini-3.8-flash gemini/gemini-3.7-flash], 'generate_start' => nil)
  end

  it 'does not validate the settings of a critique that cannot run' do
    limit = "llm:\n  critique:\n    max_prompt_chars: 0\n    rank: bogus\n"
    env = {'GEMINI_API_KEY' => 'g', 'JEV_API_KEY' => 'j', 'LLM_GENERATE_MODEL' => 'g1', 'LLM_CRITIQUE_MODEL' => 'c1'}

    expect { load(env: env, yaml: limit).require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /llm.critique.max_prompt_chars must be a positive integer/)
    jev_fail = env.merge('LLM_CRITIQUE_ENGINE' => 'jev', 'LLM_JEV_FALLBACK' => 'fail')
    expect { load(env: jev_fail, yaml: limit).require_llm_configuration! }.not_to raise_error

    pool = "llm:\n  models: [g1, g2]\n  critique:\n    rank: bogus\n"
    expect { load(env: {'GEMINI_API_KEY' => 'g'}, yaml: pool).require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /llm.critique.rank must be one of/)
    no_critique = load(env: {'GEMINI_API_KEY' => 'g'}, yaml: pool).with_overrides(no_critique: true)
    expect { no_critique.require_llm_configuration!(critique: false) }.not_to raise_error
    expect(no_critique.llm_stages).to eq(%w[generate])
    expect(no_critique.critique_model).to be_nil
  end

  it 'warns that the shadow is ignored when Jev already decides' do
    expect(load(env: {'LLM_CRITIQUE_ENGINE' => 'jev', 'LLM_JEV_SHADOW' => 'true'}).warnings)
      .to include('llm.jev.shadow is ignored: Jev already decides as the critique engine')
  end
end
