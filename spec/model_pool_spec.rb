require 'aireview/model_pool'

RSpec.describe Aireview::ModelPool do
  let(:items) { ['gemini-pro', 'gemini-flash', {'provider' => 'gemini', 'model' => 'gemini-lite', 'max_prompt_chars' => 500}, 'ollama/qwen:7b'] }
  let(:limits) { {'generate' => 1000, 'critique' => 2000} }

  def pool(**options)
    described_class.new(**{items: items, provider: 'gemini', limits: limits}.merge(options))
  end

  def names(chain)
    chain.map(&:to_s)
  end

  it 'rotates the pool to the generate start and keeps the whole pool for critique' do
    plan = pool(starts: {'generate' => 'gemini-flash'})

    expect(names(plan.chain(:generate))).to eq(%w[gemini/gemini-flash gemini/gemini-lite ollama/qwen:7b gemini/gemini-pro])
    expect(names(plan.chain(:critique))).to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-lite ollama/qwen:7b])
    expect(plan.chain(:generate).map(&:max_prompt_chars)).to eq([1000, 500, 1000, 1000])
    expect(plan.chain(:critique).map(&:max_prompt_chars)).to eq([2000, 2000, 500, 2000])
    expect(plan.primary(:generate).model).to eq('gemini-flash')
    expect(plan.pool?).to be(true)
    expect(plan.pool_stage?(:critique)).to be(true)
    expect(plan.pool_member?('ollama/qwen:7b')).to be(true)
    expect(plan.pool_member?('nope')).to be(false)
    expect(plan.start_used?(:generate)).to be(true)
    expect(plan.start_used?(:critique)).to be(false)
  end

  it 'limits the critique chain to the models not below the one that answered in generate' do
    plan = pool
    lite = plan.chain(:generate)[2]

    expect(names(plan.critique_chain(after: lite))).to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-lite])
    expect(names(plan.critique_chain(after: plan.chain(:generate).first))).to eq(%w[gemini/gemini-pro])
    expect(plan.weaker?(plan.chain(:critique)[3], lite)).to be(true)
    expect(plan.weaker?(plan.chain(:critique)[0], lite)).to be(false)
    expect(plan.rule).to eq('not_below_generate')
    expect(plan.signature).to eq(
      'models' => %w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-lite ollama/qwen:7b],
      'generate_start' => nil, 'critique_start' => nil, 'rank' => 'not_below_generate', 'allow_weaker' => false
    )
  end

  it 'appends the weaker models with allow_weaker and ignores the rank with rank: any' do
    lenient = pool(allow_weaker: true)
    flash = lenient.chain(:generate)[1]
    expect(names(lenient.critique_chain(after: flash)))
      .to eq(%w[gemini/gemini-pro gemini/gemini-flash gemini/gemini-lite ollama/qwen:7b])
    expect(lenient.rule).to eq('not_below_generate, weaker allowed')

    any = pool(rank: 'any')
    expect(any.critique_chain(after: flash)).to eq(any.chain(:critique))
    expect(any.rule).to eq('any')
  end

  it 'puts an explicit critique start first only when the rank allows it' do
    plan = pool(starts: {'critique' => 'gemini-lite'})
    flash = plan.chain(:generate)[1]
    lite = plan.chain(:generate)[2]

    expect(names(plan.critique_chain(after: flash))).to eq(%w[gemini/gemini-pro gemini/gemini-flash])
    expect(plan.warnings).to eq([
      'llm.critique.start gemini-lite is below the model that answered in generate and allow_weaker is off, ignoring it'
    ])
    expect(names(plan.critique_chain(after: lite))).to eq(%w[gemini/gemini-lite gemini/gemini-pro gemini/gemini-flash])
    expect(names(plan.chain(:critique))).to eq(%w[gemini/gemini-lite ollama/qwen:7b gemini/gemini-pro gemini/gemini-flash])
  end

  it 'takes a stage out of the pool when it has its own chain, without the rank rule' do
    own = Aireview::StageChains.build({'critique' => {provider: 'ollama', model: 'big', fallbacks: [], max_prompt_chars: 100}})
    plan = pool(own_chains: own)

    expect(names(plan.chain(:critique))).to eq(%w[ollama/big])
    expect(plan.critique_chain(after: plan.chain(:generate).first)).to eq(plan.chain(:critique))
    expect(plan.pool_stage?(:generate)).to be(true)
    expect(plan.pool_stage?(:critique)).to be(false)
    expect(plan.rule).to be_nil
    expect(plan.signature).to be_nil
  end

  it 'falls back to the pool head for an inherited start that the pool no longer contains' do
    plan = pool(starts: {'generate' => 'gone', 'critique' => 'gemini-flash'}, inherited_starts: %w[generate critique])

    expect(plan.primary(:generate).model).to eq('gemini-pro')
    expect(plan.start_used?(:generate)).to be(false)
    expect(plan.start_used?(:critique)).to be(true)
    expect(plan.warnings).to eq(['llm.generate.start gone is not in the overriding llm.models, starting from gemini/gemini-pro'])
    expect { pool(starts: {'generate' => 'gone'}) }
      .to raise_error(Aireview::ConfigError, 'gone is not in llm.models: gemini/gemini-pro, gemini/gemini-flash, gemini/gemini-lite, ollama/qwen:7b')
  end

  it 'keeps only the head of each chain when fallbacks are disabled' do
    plan = pool(starts: {'generate' => 'gemini-flash'}, only_primary: true)
    expect(names(plan.chain(:generate))).to eq(%w[gemini/gemini-flash])
    expect(names(plan.critique_chain(after: plan.chain(:generate).first))).to eq(%w[gemini/gemini-pro])
  end

  it 'validates the items and the rank up front' do
    expect { pool(items: %w[a a]) }.to raise_error(Aireview::ConfigError, 'llm.models has duplicates: gemini/a')
    expect { pool(items: []) }.to raise_error(Aireview::ConfigError, 'llm.models must not be empty')
    expect { pool(items: [{'provider' => 'gemini'}]) }.to raise_error(Aireview::ConfigError, 'llm.models[0].model is required')
    expect { pool(rank: 'better') }.to raise_error(Aireview::ConfigError, /llm.critique.rank must be one of not_below_generate, any/)
  end
end
