# frozen_string_literal: true

require 'stringio'
require 'aireview'

RSpec.describe Aireview::DryRunPrompts do
  let(:merge_request) do
    {'title' => 'Fix totals', 'description' => 'Tax must stay', 'source_branch' => 'fix',
     'target_branch' => 'main', 'author' => {'name' => 'Denis'}}
  end
  let(:changes) { [{'old_path' => 'a.rb', 'new_path' => 'a.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"}] }

  def build(jev: nil, critique: true)
    llm = {'generate' => {'model' => 'gemini-3.7-flash'}, 'critique' => {'model' => 'gemini-3.8-flash'}}
    llm = llm.merge('critique' => llm['critique'].merge('engine' => 'jev'), 'jev' => jev) if jev
    config = Aireview::Config.new({'llm' => llm, 'jev_api_key' => 'j'}, logger: Logger.new(nil))
    context_builder = Aireview::ContextBuilder.new(config: config, logger: Logger.new(nil))
    described_class.new(config: config, context_builder: context_builder, logger: Logger.new(nil))
      .build(merge_request: merge_request, changes: changes, critique: critique)
  end

  it 'has no Jev part with the model engine' do
    dry_run = build

    expect(dry_run).to include(jev_questions: nil, jev_critique: nil)
    expect(dry_run[:critique_prompt]).not_to be_nil
    expect(dry_run[:sizes][:stages].keys).to eq(%w[generate critique])
  end

  it 'shows the Jev request for the stub candidate and keeps the LLM critique while Jev can fall back to it' do
    dry_run = build(jev: {})

    expect(dry_run[:critique_prompt]).not_to be_nil
    expect(dry_run[:jev_questions].keys).to eq(Aireview::JevCritic::DECISION_QUESTIONS)
    expect(dry_run[:jev_critique]).to include(model: 'jev-1.13.0', key: true, fallback: 'model')
    expect(dry_run[:jev_critique][:state]['candidates'].keys).to eq(%w[C1])
    expect(dry_run[:jev_critique][:state]['requirements']).to include('Tax must stay')
    expect(dry_run[:jev_critique][:questions].keys).to include('real_issue_C1', 'enough_context_C1')
  end

  it 'has no LLM critique prompt and budgets for generate only when Jev cannot fall back' do
    dry_run = build(jev: {'fallback' => 'fail'})

    expect(dry_run[:critique_prompt]).to be_nil
    expect(dry_run[:sizes][:stages].keys).to eq(%w[generate])
    expect(dry_run[:sources].keys).to eq(%i[generate])
    expect(dry_run[:critique_fallbacks]).to eq([])
    expect(dry_run[:critique_rule]).to be_nil
  end

  it 'has neither critique with --no-critique' do
    expect(build(jev: {}, critique: false)).to include(critique_prompt: nil, jev_questions: nil, jev_critique: nil)
  end

  it 'prints the Jev engine, its fallback and its request' do
    out = StringIO.new
    Aireview::DryRunReport.new(out).render(build(jev: {}))

    expect(out.string).to include('Critique: jev jev-1.13.0 (key set; fallback: model; keep_above=0.5')
    expect(out.string).to include('Critique fallback: gemini-3.8-flash')
    expect(out.string).to include('=== JEV STATE ===', '=== JEV QUESTIONS ===', '"real_issue_C1"')
    expect(out.string).not_to include('Critique: disabled')

    out = StringIO.new
    Aireview::DryRunReport.new(out).render(build(jev: {'fallback' => 'fail'}))
    expect(out.string).to include('fallback: fail').and include('=== JEV STATE ===')
    expect(out.string).not_to include('Critique fallback', 'Critique: disabled', '=== CRITIQUE SYSTEM PROMPT ===')
  end
end
