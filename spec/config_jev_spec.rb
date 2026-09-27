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
