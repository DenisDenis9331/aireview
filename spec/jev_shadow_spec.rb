# frozen_string_literal: true

require 'json'
require 'stringio'
require 'aireview/jev_shadow'

RSpec.describe Aireview::JevShadow do
  let(:log) { StringIO.new }
  let(:config) { instance_double('Aireview::Config', jev_api_key: 'j') }
  let(:critic) { instance_double('Aireview::JevCritic') }
  let(:shadow) { described_class.new(config: config, scrub: ->(text) { text }, logger: Logger.new(log), critic: critic) }
  let(:candidates) { [{id: 'C1'}, {id: 'C2'}, {id: 'C3'}] }

  def assessment(id, decision, reason, answers = {real_issue: 0.912})
    Aireview::JevCritic::Assessment.new(id: id, decision: decision, reason: reason, answers: answers)
  end

  it 'logs every Jev decision next to the critique verdict and how often they agree' do
    result = Aireview::JevCritic::Result.new(
      assessments: [
        assessment('C1', :keep, 'real issue', real_issue: 0.912, duplicate_of: {choice: 'none', confidence: 0.9}),
        assessment('C2', :keep, 'real issue'),
        assessment('C3', :unverifiable, 'not enough context in the request')
      ],
      requests: 1, model: 'jev-1.13.0'
    )
    allow(critic).to receive(:assess).with(context: :context, candidates: candidates).and_return(result)

    shadow.run(context: :context, candidates: candidates, accepted: [{id: 'C1'}])

    expect(log.string).to include('Jev shadow C1: keep (real issue; real_issue=0.91 duplicate_of=none/0.9), critique: keep')
    expect(log.string).to include('Jev shadow C2: keep (real issue; real_issue=0.91), critique: reject')
    expect(log.string).to include('Jev shadow C3: unverifiable (not enough context in the request; real_issue=0.91)')
    expect(log.string).to match(
      %r{Jev shadow: agrees with critique on 1 of 2 decided candidate\(s\); keep 2, reject 0, unverifiable 1 \(model=jev-1.13.0, requests=1, \d+\.\ds\)}
    )
  end

  it 'keeps the exact probabilities in a JSON line for choosing thresholds' do
    result = Aireview::JevCritic::Result.new(
      assessments: [assessment('C1', :keep, 'real issue', real_issue: 0.50349,
                                                          duplicate_of: {choice: 'C2', confidence: 0.501})],
      requests: 1, model: 'jev-1.13.0'
    )
    allow(critic).to receive(:assess).and_return(result)

    shadow.run(context: :context, candidates: candidates, accepted: [])
    data = JSON.parse(log.string[/Jev shadow data: (.+)$/, 1])

    expect(log.string).to include('real_issue=0.5 ')
    expect(data).to eq(
      'model' => 'jev-1.13.0',
      'candidates' => [{'id' => 'C1', 'decision' => 'keep', 'reason' => 'real issue', 'critique' => 'reject',
                        'real_issue' => 0.50349, 'duplicate_of' => {'choice' => 'C2', 'confidence' => 0.501}}]
    )
  end

  it 'turns a Jev failure into a warning' do
    allow(critic).to receive(:assess).and_raise(Aireview::JevError.new('Jev API error 529: overloaded', status: 529))

    expect { shadow.run(context: :context, candidates: candidates, accepted: []) }.not_to raise_error
    expect(log.string).to include('WARN').and include('Jev shadow failed, the review is not affected: Jev API error 529')
  end

  it 'does not let a bug in the shadow break the review, and names it' do
    allow(critic).to receive(:assess).and_raise(NoMethodError, "undefined method `dig' for nil")

    expect { shadow.run(context: :context, candidates: candidates, accepted: []) }.not_to raise_error
    expect(log.string).to include("Jev shadow crashed, the review is not affected: NoMethodError: undefined method `dig'")
  end

  it 'is skipped with a warning without a key' do
    config = instance_double('Aireview::Config', jev_api_key: nil)
    shadow = described_class.new(config: config, scrub: ->(text) { text }, logger: Logger.new(log))

    shadow.run(context: :context, candidates: candidates, accepted: [])

    expect(log.string).to include('Jev shadow skipped: JEV_API_KEY is not set')
  end
end
