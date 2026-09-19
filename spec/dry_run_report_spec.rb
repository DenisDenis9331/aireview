require 'stringio'
require 'aireview/dry_run_report'
require 'aireview/context_budget'

RSpec.describe Aireview::DryRunReport do
  let(:out) { StringIO.new }

  def dry_run(overrides = {})
    {
      generate_prompt: {system_prompt: 'gs', user_prompt: 'gu'},
      critique_prompt: {system_prompt: 'cs', user_prompt: 'cu'},
      generate_model: 'gemini-3.7-flash', generate_temperature: 0.1,
      critique_model: 'gemini-3.8-flash', critique_temperature: 0,
      generate_fallbacks: %w[gemini/gemini-3.6-flash gemini/gemini-3.5-flash],
      critique_fallbacks: [],
      sources: {
        generate: {model: 'image defaults', provider: 'image defaults', fallbacks: 'image defaults'},
        critique: {model: '.aireview.yml', provider: 'env', fallbacks: nil}
      },
      config_paths: {'image defaults' => '/app/config/defaults.yml', '.aireview.yml' => '/repo/.aireview.yml'},
      warnings: [],
      api_keys: {'gemini' => 2},
      time_budget: 1800,
      coverage: Aireview::ContextBudget::Coverage.empty,
      sizes: {sections: 10, diff: 20, diff_budget: 100, hunks_shown: 1, hunks_total: 1, stages: {}}
    }.merge(overrides)
  end

  def settings(overrides = {})
    described_class.new(out).render(dry_run(overrides))
    out.string.split("\n=== CONTEXT ===").first.chomp
  end

  it 'prints where each model, provider and fallback list came from' do
    expect(settings).to eq(<<~TEXT.chomp)
      === LLM SETTINGS ===
      Config: image defaults /app/config/defaults.yml, .aireview.yml /repo/.aireview.yml
      Generate: gemini-3.7-flash temperature=0.1 (model from image defaults, provider from image defaults)
        fallbacks: gemini/gemini-3.6-flash -> gemini/gemini-3.5-flash (fallbacks from image defaults)
      Critique: gemini-3.8-flash temperature=0 (model from .aireview.yml, provider from env)
      API keys: gemini 2
      Time budget: 1800s
    TEXT
  end

  it 'lists provider warnings after the settings' do
    warning = 'generate: provider "ollama" comes from env, but fallbacks without an explicit provider ' \
              'come from image defaults and now inherit it: gemini-3.6-flash'
    expect(settings(warnings: [warning])).to end_with("Time budget: 1800s\n  warnings: #{warning}")
  end

  it 'stays quiet about sources and paths when there are none' do
    text = settings(sources: {}, config_paths: {}, critique_prompt: nil)
    expect(text).to eq(<<~TEXT.chomp)
      === LLM SETTINGS ===
      Generate: gemini-3.7-flash temperature=0.1
        fallbacks: gemini/gemini-3.6-flash -> gemini/gemini-3.5-flash
      Critique: disabled
      API keys: gemini 2
      Time budget: 1800s
    TEXT
  end
end
