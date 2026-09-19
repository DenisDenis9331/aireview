require 'aireview/stage_chains'

RSpec.describe Aireview::StageChains do
  def settings(generate: {}, critique: {})
    {
      'generate' => {provider: 'gemini', model: 'g', fallbacks: [], max_prompt_chars: 1000}.merge(generate),
      'critique' => {provider: 'gemini', model: 'c', fallbacks: [], max_prompt_chars: 2000}.merge(critique)
    }
  end

  it 'builds the primary model first and the fallbacks in order, inheriting provider and limit' do
    plan = described_class.build(settings(generate: {
      fallbacks: ['r1', 'ollama/qwen:7b', {'provider' => 'ollama', 'model' => 'q2', 'max_prompt_chars' => 500}]
    }))

    expect(plan.chain(:generate).map(&:to_s)).to eq(%w[gemini/g gemini/r1 ollama/qwen:7b ollama/q2])
    expect(plan.chain(:generate).map(&:max_prompt_chars)).to eq([1000, 1000, 1000, 500])
    expect(plan.chain('critique').map(&:to_s)).to eq(%w[gemini/c])
    expect(plan.primary(:critique).max_prompt_chars).to eq(2000)
  end

  it 'keeps the critique chain independent of the generate answer and never calls it weaker' do
    plan = described_class.build(settings(critique: {fallbacks: ['c2']}))
    generate = plan.primary(:generate)

    expect(plan.critique_chain(after: generate)).to eq(plan.chain(:critique))
    expect(plan.weaker?(plan.chain(:critique).last, generate)).to be(false)
    expect(plan.signature).to be_nil
    expect(plan.rule).to be_nil
    expect(plan.pool?).to be(false)
    expect(plan.pool_stage?(:generate)).to be(false)
    expect(plan.pool_member?('g')).to be(false)
    expect(plan.warnings).to eq([])
  end

  it 'keeps only the primary model when fallbacks are disabled' do
    plan = described_class.build(settings(generate: {fallbacks: %w[r1 r2]}), only_primary: true)
    expect(plan.chain(:generate).map(&:to_s)).to eq(%w[gemini/g])
  end

  it 'tolerates a missing model so that the configuration check can name it' do
    plan = described_class.build(settings(generate: {model: nil}))
    expect(plan.primary(:generate).model).to be_nil
  end

  it 'rejects malformed fallbacks with the setting name' do
    expect { described_class.build(settings(generate: {fallbacks: [{'provider' => 'gemini'}]})) }
      .to raise_error(Aireview::ConfigError, 'llm.generate.fallbacks[0].model is required')
    expect { described_class.build(settings(critique: {fallbacks: [42]})) }
      .to raise_error(Aireview::ConfigError, 'llm.critique.fallbacks[0] must be a model name or a hash with model')
    expect { described_class.build(settings(critique: {fallbacks: [{'model' => 'x', 'max_prompt_chars' => 0}]})) }
      .to raise_error(Aireview::ConfigError, /llm.critique.fallbacks\[0\].max_prompt_chars must be a positive integer/)
    expect { described_class.build(settings).chain(:repair) }.to raise_error(ArgumentError, 'unknown LLM stage :repair')
  end
end
