require 'fileutils'
require 'tmpdir'
require 'aireview/config'

# Граница Config → план маршрутизации: YAML/env/CLI превращаются в
# StageChains или ModelPool; сами планы проверяются в своих спеках.
RSpec.describe Aireview::Config, 'routing' do
  let(:pool_yaml) do
    <<~YAML
      llm:
        provider: gemini
        models:
          - gemini-pro
          - gemini-flash
          - provider: gemini
            model: gemini-flash-lite
            max_prompt_chars: 50000
          - ollama/qwen2.5-coder:7b
        generate:
          start: gemini-flash
    YAML
  end

  def load_with(dir, yaml: pool_yaml, env: {})
    File.write(File.join(dir, '.aireview.yml'), yaml)
    Aireview::Config.load(cwd: dir, env: env.merge('GEMINI_API_KEY' => 'k'), logger: Logger.new(nil))
  end

  def names(chain)
    chain.map(&:to_s)
  end

  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  it 'rotates the pool to the generate start and keeps the whole pool for critique' do
    config = load_with(@dir)

    expect(names(config.stage_chain(:generate)))
      .to eq(%w[gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b gemini/gemini-pro])
    expect(names(config.stage_chain(:critique)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b])
    expect(config.generate_model).to eq('gemini-flash')
    expect(config.critique_model).to eq('gemini-pro')
    expect(config.generate_provider).to eq('gemini')
    expect(config.stage_chain(:generate)[1].max_prompt_chars).to eq(50_000)
    expect(config.routing.rule).to eq('not_below_generate')
    expect { config.require_llm_configuration! }.not_to raise_error
  end

  it 'limits the critique chain to models not below the one that answered in generate' do
    config = load_with(@dir)
    flash_lite = config.stage_chain(:generate)[1]

    expect(names(config.routing.critique_chain(after: flash_lite)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite])
    expect(names(config.routing.critique_chain(after: config.stage_chain(:generate).first)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash])
    expect(config.routing.weaker?(config.stage_chain(:critique)[3], flash_lite)).to be(true)
    expect(config.routing.weaker?(config.stage_chain(:critique)[0], flash_lite)).to be(false)
  end

  it 'appends the weaker models when allow_weaker is on and reports the rule' do
    config = load_with(@dir, yaml: "#{pool_yaml}        critique:\n          allow_weaker: true\n".sub("        critique:", "  critique:").sub("          allow_weaker", "    allow_weaker"))
    flash = config.stage_chain(:critique)[1]

    expect(names(config.routing.critique_chain(after: flash)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b])
    expect(config.routing.rule).to eq('not_below_generate, weaker allowed')
  end

  it 'puts an explicit critique start first only when the rank allows it, and ignores the rank with rank: any' do
    yaml = pool_yaml.sub("  critique:\n", '').sub("        generate:\n          start: gemini-flash\n", '')
    log_output = StringIO.new
    File.write(File.join(@dir, '.aireview.yml'), "#{yaml}  critique:\n    start: gemini-flash-lite\n")
    config = Aireview::Config.load(cwd: @dir, env: {'GEMINI_API_KEY' => 'k'}, logger: Logger.new(log_output))
    pro, flash, flash_lite = config.routing.pool

    # Старт ниже ответившей generate не обходит запрет слабой критики.
    expect(names(config.routing.critique_chain(after: flash))).to eq(%w[gemini/gemini-pro gemini/gemini-flash])
    expect(config.warnings).to include(
      'llm.critique.start gemini-flash-lite is below the model that answered in generate and allow_weaker is off, ignoring it'
    )
    # Старт допустим — идёт первым.
    expect(names(config.routing.critique_chain(after: flash_lite)))
      .to eq(%w[gemini/gemini-flash-lite gemini/gemini-pro gemini/gemini-flash])
    # Старт выше generate — тоже первым, остальные по порядку пула.
    File.write(File.join(@dir, '.aireview.yml'), "#{yaml}  critique:\n    start: gemini-flash\n")
    config = Aireview::Config.load(cwd: @dir, env: {'GEMINI_API_KEY' => 'k'}, logger: Logger.new(nil))
    expect(names(config.routing.critique_chain(after: flash_lite)))
      .to eq(%w[gemini/gemini-flash gemini/gemini-pro gemini/gemini-flash-lite])
    expect(pro.to_s).to eq('gemini/gemini-pro')

    config = load_with(@dir, yaml: "#{yaml}  critique:\n    rank: any\n")
    expect(names(config.routing.critique_chain(after: flash))).to eq(names(config.stage_chain(:critique)))
    expect(config.routing.rule).to eq('any')
  end

  it 'leaves a stage on its own chain when it has a model of its own, without the rank rule' do
    config = load_with(@dir, yaml: "#{pool_yaml}  critique:\n    provider: ollama\n    model: qwen2.5-coder:14b\n")

    expect(names(config.stage_chain(:critique))).to eq(%w[ollama/qwen2.5-coder:14b])
    expect(config.routing.critique_chain(after: config.stage_chain(:generate).first))
      .to eq(config.stage_chain(:critique))
    expect(config.routing.rule).to be_nil
    expect(config.routing.pool_stage?('generate')).to be(true)
    expect(config.routing.pool_stage?('critique')).to be(false)
  end

  it 'treats CLI overrides as a start when the model is in the pool and as a single model otherwise' do
    base = load_with(@dir)
    config = base.with_overrides(generate_model: 'gemini-pro', critique_model: 'gemini-outside')

    expect(names(config.stage_chain(:generate)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b])
    expect(names(config.stage_chain(:critique))).to eq(%w[gemini/gemini-outside])
    expect(config.routing.pool_stage?('critique')).to be(false)
    expect(names(base.with_overrides(no_fallbacks: true).stage_chain(:generate))).to eq(%w[gemini/gemini-flash])
  end

  it 'switches a stage between its own chain and the pool on a CLI override' do
    legacy = "#{pool_yaml}  critique:\n    model: legacy\n    fallbacks: [old-reserve]\n"
    base = load_with(@dir, yaml: legacy)
    expect(names(base.stage_chain(:critique))).to eq(%w[gemini/legacy gemini/old-reserve])

    # Модель из пула возвращает стадию в пул: своя model и fallbacks сбрасываются.
    config = base.with_overrides(critique_model: 'gemini-pro')
    expect(config.routing.pool_stage?('critique')).to be(true)
    expect(names(config.stage_chain(:critique)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b])

    # Модель не из пула — одиночная цепочка, старые fallbacks не тянутся.
    config = base.with_overrides(critique_model: 'outside')
    expect(names(config.stage_chain(:critique))).to eq(%w[gemini/outside])

    # Без пула — прежнее поведение: меняется только основная модель, запасные остаются.
    plain = load_with(@dir, yaml: "llm:\n  generate:\n    model: g\n    fallbacks: [r]\n  critique:\n    model: c\n")
    expect(names(plain.with_overrides(generate_model: 'x').stage_chain(:generate))).to eq(%w[gemini/x gemini/r])
  end

  it 'exposes the pool order and policy as a signature for the review key' do
    config = load_with(@dir)
    signature = config.routing.signature

    expect(signature).to eq(
      'models' => %w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-flash-lite ollama/qwen2.5-coder:7b],
      'generate_start' => 'gemini-flash', 'critique_start' => nil,
      'rank' => 'not_below_generate', 'allow_weaker' => false
    )
    expect(load_with(@dir, yaml: "#{pool_yaml}  critique:\n    model: own\n").routing.signature).to be_nil
  end

  it 'builds a plan for a config made from a hash without an explicit provider' do
    config = Aireview::Config.new({'llm' => {'models' => %w[a b]}}, config_path: nil, logger: Logger.new(nil))

    expect(names(config.stage_chain(:generate))).to eq(%w[gemini/a gemini/b])
    expect(config.generate_provider).to eq('gemini')
  end

  it 'lets the CLI replace a start that the current plan rejects' do
    config = load_with(@dir, yaml: "llm:\n  models: [a, b]\n  generate:\n    start: removed\n")
    expect { config.routing }.to raise_error(Aireview::ConfigError, 'removed is not in llm.models: gemini/a, gemini/b')

    fixed = config.with_overrides(generate_model: 'b')
    expect(names(fixed.stage_chain(:generate))).to eq(%w[gemini/b gemini/a])
    outside = config.with_overrides(generate_model: 'other')
    expect(names(outside.stage_chain(:generate))).to eq(%w[gemini/other])
  end

  it 'ignores the start of a stage that left the pool with its own model' do
    config = load_with(@dir, yaml: "llm:\n  models: [a, b]\n  generate:\n    model: own\n    start: removed\n")

    expect(names(config.stage_chain(:generate))).to eq(%w[gemini/own])
    expect(names(config.stage_chain(:critique))).to eq(%w[gemini/a gemini/b])
    expect(config.warnings).to eq([])
  end

  it 'reads the pool and the rule from env' do
    env = {
      'LLM_MODELS' => 'gemini/a, gemini/b,ollama/c',
      'LLM_GENERATE_START' => 'b',
      'LLM_CRITIQUE_RANK' => 'any',
      'LLM_CRITIQUE_ALLOW_WEAKER' => 'true',
      'LLM_CRITIQUE_MODEL' => ''
    }
    config = load_with(@dir, yaml: "llm:\n  provider: gemini\n", env: env)

    expect(names(config.stage_chain(:generate))).to eq(%w[gemini/b ollama/c gemini/a])
    expect(config.routing.instance_variable_get(:@rank)).to eq('any')
    expect(config.routing.instance_variable_get(:@allow_weaker)).to be(true)
    expect { load_with(@dir, env: {'LLM_CRITIQUE_ALLOW_WEAKER' => 'maybe'}) }
      .to raise_error(Aireview::ConfigError, 'LLM_CRITIQUE_ALLOW_WEAKER must be true or false, got "maybe"')
  end

  it 'rejects a bad critique policy before the first request, not after generate' do
    config = load_with(@dir, yaml: "llm:\n  models: [a]\n  critique:\n    rank: better\n")
    expect { config.require_llm_configuration! }
      .to raise_error(Aireview::ConfigError, /llm.critique.rank must be one of/)
  end

  it 'validates the pool, the start and the rank' do
    expect { load_with(@dir, yaml: "llm:\n  models: [a, a]\n").stage_chain(:generate) }
      .to raise_error(Aireview::ConfigError, 'llm.models has duplicates: gemini/a')
    expect { load_with(@dir, yaml: "llm:\n  models: [a]\n  generate:\n    start: b\n").stage_chain(:generate) }
      .to raise_error(Aireview::ConfigError, 'b is not in llm.models: gemini/a')
    expect { load_with(@dir, yaml: "llm:\n  models: [a]\n  critique:\n    rank: better\n").routing }
      .to raise_error(Aireview::ConfigError, /llm.critique.rank must be one of not_below_generate, any/)
    expect { load_with(@dir, yaml: "llm:\n  models:\n    - provider: gemini\n").stage_chain(:generate) }
      .to raise_error(Aireview::ConfigError, 'llm.models[0].model is required')
  end
end
