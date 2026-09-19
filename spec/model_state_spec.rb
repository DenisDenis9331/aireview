require 'aireview/model_state'

RSpec.describe Aireview::ModelState do
  let(:state) { described_class.new }

  it 'counts sent requests per stage against one limit for every key' do
    3.times { state.record_request(:generate) }

    expect(state.sent(:generate)).to eq(3)
    expect(state.requests_left?(:generate)).to be(false)
    expect(state.requests_left?(:critique)).to be(true)
    expect(state.skip_reason(:generate)).to eq('attempt limit of 3 reached')
    expect(state.skip_reason(:critique)).to be_nil
  end

  it 'quarantines until a moment in time without touching the counter' do
    state.record_request(:generate)
    state.quarantine(150.0)

    expect(state.quarantine_left(30.0)).to eq(120.0)
    expect(state.quarantine_left(200.0)).to eq(0)
    expect(state.sent(:generate)).to eq(1)
    expect(state.skip_reason(:generate)).to be_nil

    state.lift_quarantine
    expect(state.quarantine_left(30.0)).to eq(0)
  end

  it 'excludes for the run or for one stage, with the reason' do
    state.exclude_for_stage(:generate, 'invalid result')
    expect(state.skip_reason(:generate)).to eq('excluded for this stage: invalid result')
    expect(state.skip_reason(:critique)).to be_nil

    state.exclude('model unavailable earlier in this run')
    expect(state.skip_reason(:critique)).to eq('model unavailable earlier in this run')
    expect(state.excluded_reason).to eq('model unavailable earlier in this run')
  end

  it 'remembers keys whose daily quota is exhausted separately from the quarantine' do
    state.exhaust_key(0)

    expect(state.key_exhausted?(0)).to be(true)
    expect(state.key_exhausted?(1)).to be(false)
    expect(state.quarantine_left(0.0)).to eq(0)
    expect(state.skip_reason(:generate)).to be_nil
  end
end
