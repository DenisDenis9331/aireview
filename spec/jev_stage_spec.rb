# frozen_string_literal: true

require 'stringio'
require 'aireview/jev_stage'

RSpec.describe Aireview::JevStage do
  let(:log) { StringIO.new }
  let(:fallback) { 'model' }
  let(:config) do
    instance_double('Aireview::Config', jev_model: 'jev-1.13.0', jev_fallback: fallback,
                                        critique_model: 'gemini-3.8-flash', jev_thresholds: {duplicate: 0.5})
  end
  let(:critic) { instance_double('Aireview::JevCritic') }
  let(:stage) { described_class.new(config: config, critic: critic, logger: Logger.new(log)) }
  let(:candidates) do
    %w[C1 C2 C3].map { |id| {'id' => id, 'severity' => 'major', 'problem' => "Problem #{id}"} }
  end
  let(:llm_calls) { [] }
  # The LLM Critique keeps everything it gets and marks it as refined.
  let(:llm_critique) do
    lambda do |subset|
      llm_calls << subset.map { |candidate| candidate['id'] }
      subset.map { |candidate| candidate.merge('problem' => "#{candidate['problem']} (refined)") }
    end
  end

  def assessment(id, decision, reason = decision.to_s)
    Aireview::JevCritic::Assessment.new(id: id, decision: decision, reason: reason, answers: {real_issue: 0.9})
  end

  def jev_decides(decisions, answers = {})
    result = Aireview::JevCritic::Result.new(
      assessments: decisions.map { |id, decision| assessment(id, decision) },
      answers: answers, requests: 1, model: 'jev-1.13.0'
    )
    allow(critic).to receive(:assess).with(context: :context, candidates: candidates, dedupe: false)
                                     .and_return(result)
  end

  def run
    stage.run(context: :context, candidates: candidates, llm_critique: llm_critique)
  end

  it 'keeps what Jev keeps, unrefined, and asks the LLM nothing when Jev judged everything' do
    jev_decides({'C1' => :keep, 'C2' => :reject, 'C3' => :keep})

    outcome = run

    expect(outcome.accepted).to eq([candidates[0], candidates[2]])
    expect(outcome.note).to eq(:jev)
    expect(llm_calls).to be_empty
    expect(log.string).to include('Critique (jev) reject C2: reject (real_issue=0.9)')
  end

  it 'sends only the candidates Jev could not judge to the LLM critique, in generate order' do
    jev_decides({'C1' => :unverifiable, 'C2' => :keep, 'C3' => :unverifiable})

    outcome = run

    expect(llm_calls).to eq([%w[C1 C3]])
    expect(outcome.accepted.map { |candidate| candidate['problem'] })
      .to eq(['Problem C1 (refined)', 'Problem C2', 'Problem C3 (refined)'])
    expect(outcome.note).to eq(:jev_partial)
  end

  it 'drops duplicates once, over what Jev and the LLM kept together' do
    jev_decides({'C1' => :keep, 'C2' => :unverifiable, 'C3' => :reject},
                {'duplicate_of_C2' => {'choice' => 'C1', 'confidence' => 0.9}})
    llm_critique = lambda do |subset|
      subset.map { |candidate| candidate.merge('severity' => 'critical') }
    end

    outcome = stage.run(context: :context, candidates: candidates, llm_critique: llm_critique)

    expect(outcome.accepted.map { |candidate| candidate['id'] }).to eq(%w[C2])
    expect(log.string).to include('Critique reject C1: duplicate of C2 (Jev)')
  end

  it 'lets the LLM critique take over everything when Jev fails' do
    allow(critic).to receive(:assess).and_raise(Aireview::JevError.new('Jev API error 529: overloaded', status: 529))

    outcome = run

    expect(llm_calls).to eq([%w[C1 C2 C3]])
    expect(outcome.note).to eq(:jev_failed)
    expect(log.string).to include('Jev critique failed, the LLM critique takes over')
  end

  context 'with llm.jev.fallback: fail' do
    let(:fallback) { 'fail' }

    it 'rejects what Jev could not judge instead of asking the LLM' do
      jev_decides({'C1' => :keep, 'C2' => :unverifiable, 'C3' => :unverifiable})

      outcome = run

      expect(outcome.accepted).to eq([candidates[0]])
      expect(outcome.note).to eq(:jev)
      expect(llm_calls).to be_empty
      expect(log.string).to include('Critique reject C2, C3: Jev could not judge them and llm.jev.fallback is fail')
    end

    it 'fails the run when Jev fails' do
      allow(critic).to receive(:assess).and_raise(Aireview::JevError.new('Jev request failed: timeout'))

      expect { run }.to raise_error(Aireview::JevError, /llm.jev.fallback is fail: Jev request failed: timeout/)
      expect(llm_calls).to be_empty
    end
  end
end
