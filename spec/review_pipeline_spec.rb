require 'aireview/review_pipeline'
require 'stringio'

RSpec.describe Aireview::ReviewPipeline do
  let(:config) do
    instance_double(
      'Aireview::Config',
      require_models!: true,
      require_llm_configuration!: true,
      review_instructions: nil,
      review_language: 'en',
      secret_patterns: [],
      secret_files: [],
      max_prompt_chars: 400_000,
      max_diff_chars: 120_000,
      max_mr_description_chars: 8_000,
      max_jira_description_chars: 8_000,
      max_jira_comment_chars: 2_000,
      generate_model: 'gemini-generate',
      generate_temperature: 0.3,
      critique_model: 'gemini-critique',
      critique_temperature: 0,
      llm_time_budget: 1_800,
      overloaded_quarantine: 120,
      routing: instance_double('Aireview::StageChains', rule: nil, signature: nil),
      warnings: [],
      fallback_names: [],
      stage_model_source: nil,
      stage_fallbacks_source: nil,
      stage_provider_source: 'built-in',
      layer_paths: {},
      api_key_counts: {'gemini' => 1},
      jev_shadow?: false
    ).tap { |double| allow_model_engine(double) }
  end

  let(:reviewer) do
    instance_double('Aireview::Reviewer', fallback_models: {}, answered_model: nil, exclude_answered_model: nil,
                                          finish_reason: nil, critique_weaker?: false)
  end
  let(:logger) { Logger.new(nil) }
  let(:pipeline) { described_class.new(config: config, reviewer: reviewer, logger: logger) }

  let(:merge_request) do
    {
      'title' => 'Fix order total',
      'description' => 'AIR-1',
      'source_branch' => 'fix/order-total',
      'target_branch' => 'main',
      'author' => { 'name' => 'Denis' }
    }
  end

  let(:changes) do
    [
      {
        'old_path' => 'app/models/order.rb',
        'new_path' => 'app/models/order.rb',
        'diff' => "@@ -10,3 +10,3 @@\n-total = subtotal + tax\n+total = subtotal\n"
      }
    ]
  end

  let(:candidates) do
    [
      finding('C1', category: 'bug', problem: 'Tax is no longer included'),
      finding('C2', category: 'task_mismatch', problem: 'Jira requires discounts'),
      finding('C3', category: 'maintainability', problem: 'Name is unclear')
    ]
  end

  def finding(id, category:, problem:, severity: 'major')
    {
      id: id,
      file: 'app/models/order.rb',
      line: 12,
      quoted_code: 'total = subtotal',
      problem: problem,
      why: "#{problem} can break checkout",
      suggestion: 'Keep the previous calculation or update the requirement',
      category: category,
      severity: severity
    }
  end

  def generate_result(candidates)
    JSON.generate(
      summary: 'MR recalculates order totals during checkout.',
      candidates: candidates
    )
  end

  def structured_generate_result(candidates)
    {
      'summary' => 'MR recalculates order totals during checkout.',
      'candidates' => candidates.map { |candidate| candidate.transform_keys(&:to_s) }
    }
  end

  it 'renders only candidates accepted by critique' do
    allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C2', decision: 'reject', reason: 'not supported by diff' },
          { id: 'C3', decision: 'reject', reason: 'not actionable' }
        ]
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('MR recalculates order totals during checkout.')
    expect(result).to include('Tax is no longer included')
    expect(result).not_to include('Jira requires discounts')
    expect(result).not_to include('Name is unclear')
    expect(result).to include('needs attention')
  end

  describe 'Jev shadow' do
    let(:jev_shadow) { instance_double('Aireview::JevShadow', run: nil) }
    let(:verdicts) do
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C2', decision: 'reject', reason: 'not supported by diff' },
          { id: 'C3', decision: 'reject', reason: 'not actionable' }
        ]
      )
    end

    def shadow_pipeline
      described_class.new(config: config, reviewer: reviewer, jev_shadow: jev_shadow, logger: logger)
    end

    before do
      allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
      allow(reviewer).to receive(:critique).and_return(verdicts)
    end

    it 'gets the checked candidates and what the critique kept, and does not change the report' do
      without_shadow = shadow_pipeline.run(merge_request: merge_request, changes: changes)
      allow(config).to receive(:jev_shadow?).and_return(true)

      with_shadow = shadow_pipeline.run(merge_request: merge_request, changes: changes)

      expect(jev_shadow).to have_received(:run) do |context:, candidates:, accepted:|
        expect(context.diff_text).to include('total = subtotal')
        expect(candidates.map { |candidate| candidate['id'] }).to eq(%w[C1 C2 C3])
        expect(accepted.map { |candidate| candidate['id'] }).to eq(%w[C1])
      end
      expect(with_shadow).to eq(without_shadow)
    end

    it 'does not run when it is off, without critique or without candidates' do
      shadow_pipeline.run(merge_request: merge_request, changes: changes)
      allow(config).to receive(:jev_shadow?).and_return(true)
      shadow_pipeline.run(merge_request: merge_request, changes: changes, critique: false)
      allow(reviewer).to receive(:generate).and_return(generate_result([]))
      shadow_pipeline.run(merge_request: merge_request, changes: changes)

      expect(jev_shadow).not_to have_received(:run)
    end

    it 'shows the shadow settings in dry-run without the key' do
      allow(config).to receive_messages(jev_shadow?: true, jev_model: 'jev-1.13.0', jev_api_key: 'secret',
                                        jev_thresholds: {keep_above: 0.5})

      dry_run = shadow_pipeline.dry_run_prompts(merge_request: merge_request, changes: changes)

      expect(dry_run[:jev_shadow]).to eq(model: 'jev-1.13.0', key: true, thresholds: {keep_above: 0.5})
      expect(shadow_pipeline.dry_run_prompts(merge_request: merge_request, changes: changes, critique: false))
        .to include(jev_shadow: nil)
    end
  end

  describe 'Jev as the critique engine' do
    # Calls the LLM critique of the pipeline for the candidates it names, as
    # JevStage does with the ones Jev could not judge.
    let(:stage_class) do
      Class.new do
        attr_reader :calls

        def initialize(outcome, send_to_llm: [])
          @outcome = outcome
          @send_to_llm = send_to_llm
          @calls = 0
        end

        def run(context:, candidates:, llm_critique:)
          @calls += 1
          subset = candidates.select { |candidate| @send_to_llm.include?(candidate['id']) }
          kept = subset.empty? ? [] : llm_critique.call(subset)
          Aireview::JevStage::Outcome.new(accepted: @outcome.accepted + kept, note: @outcome.note)
        end
      end
    end
    let(:jev_shadow) { instance_double('Aireview::JevShadow', run: nil) }

    def jev_pipeline(stage)
      described_class.new(config: config, reviewer: reviewer, logger: logger, jev_stage: stage, jev_shadow: jev_shadow)
    end

    before do
      allow(config).to receive(:jev_critique?).and_return(true)
      allow(config).to receive(:jev_shadow?).and_return(true)
      allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
    end

    it 'renders what Jev kept with the Jev note, without the LLM critique and the shadow' do
      kept = JSON.parse(JSON.generate(candidates.first))
      stage = stage_class.new(Aireview::JevStage::Outcome.new(accepted: [kept], note: :jev))
      allow(reviewer).to receive(:critique)

      result = jev_pipeline(stage).run(merge_request: merge_request, changes: changes)

      expect(result).to include('Tax is no longer included')
      expect(result).not_to include('Jira requires discounts')
      expect(result).to include('The findings were checked by Jev, a fast classifier, without refining their wording.')
      expect(reviewer).not_to have_received(:critique)
      expect(jev_shadow).not_to have_received(:run)
    end

    it 'gives the LLM critique only the candidates Jev passes on' do
      stage = stage_class.new(Aireview::JevStage::Outcome.new(accepted: [], note: :jev_partial), send_to_llm: %w[C2])
      prompts = []
      allow(reviewer).to receive(:critique) do |**prompt|
        prompts << prompt[:user_prompt]
        JSON.generate(verdicts: [{id: 'C2', decision: 'keep', reason: 'confirmed'}])
      end

      result = jev_pipeline(stage).run(merge_request: merge_request, changes: changes)

      expect(prompts.size).to eq(1)
      expect(prompts.first).to include('"id": "C2"')
      expect(prompts.first).not_to include('"id": "C1"', '"id": "C3"')
      expect(result).to include('Jira requires discounts')
      expect(result).to include('those Jev could not judge were checked by the LLM critique')
    end

    it 'is not used with --no-critique' do
      stage = stage_class.new(Aireview::JevStage::Outcome.new(accepted: [], note: :jev))
      allow(config).to receive(:jev_critique?) { |critique: true| critique }

      result = jev_pipeline(stage).run(merge_request: merge_request, changes: changes, critique: false)

      expect(stage.calls).to eq(0)
      expect(result).not_to include('Jev')
    end
  end

  it 'renders ok when critique rejects every candidate' do
    allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: candidates.map { |candidate| { id: candidate[:id], decision: 'reject', reason: 'not confirmed' } }
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('MR recalculates order totals during checkout.')
    expect(result).to include('None found.')
    expect(result).to include('ok')
  end

  it 'processes structured Hash responses without JSON parsing or repair' do
    allow(reviewer).to receive(:generate).and_return(structured_generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      {
        'verdicts' => [
          { 'id' => 'C1', 'decision' => 'keep', 'reason' => 'confirmed by diff' }
        ]
      }
    )
    allow(JSON).to receive(:parse).and_call_original

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(JSON).not_to have_received(:parse)
    expect(reviewer).to have_received(:generate).once
    expect(reviewer).to have_received(:critique).once
    expect(result).to include('Tax is no longer included')
  end

  it 'continues processing JSON strings without repair' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).to have_received(:generate).once
    expect(result).to include('Tax is no longer included')
  end

  it 'rejects an invalid structured generate result without repair' do
    invalid_result = structured_generate_result([{ file: 'app/models/order.rb' }])
    allow(reviewer).to receive(:generate).and_return(invalid_result)

    expect do
      pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    end.to raise_error(
      Aireview::ParseError,
      /invalid generate result: each generate candidate must include a non-empty id/
    )
    expect(reviewer).to have_received(:generate).once
  end

  it 'rejects malformed structured generate candidates without repair' do
    allow(reviewer).to receive(:generate).and_return(
      { 'summary' => 'Malformed result', 'candidates' => [nil] }
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    end.to raise_error(
      Aireview::ParseError,
      /invalid generate result: each generate candidate must be an object/
    )
    expect(reviewer).to have_received(:generate).once
  end

  it 'rejects an unsupported response type without repair' do
    allow(reviewer).to receive(:generate).and_return(nil)

    expect do
      pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    end.to raise_error(Aireview::ParseError, /unsupported generate result type: NilClass/)
    expect(reviewer).to have_received(:generate).once
  end

  it 'rejects an invalid structured critique result without repair' do
    allow(reviewer).to receive(:generate).and_return(structured_generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      { 'verdicts' => [{ 'id' => 'C9', 'decision' => 'keep', 'reason' => 'hallucinated id' }] }
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /invalid critique result: unknown verdict ids: C9/)
    expect(reviewer).to have_received(:critique).once
  end

  it 'rejects malformed structured critique verdicts without repair' do
    allow(reviewer).to receive(:generate).and_return(structured_generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return({ 'verdicts' => [42] })

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(
      Aireview::ParseError,
      /invalid critique result: each critique verdict must be an object/
    )
    expect(reviewer).to have_received(:critique).once
  end

  it 'repairs invalid generate JSON once' do
    allow(reviewer).to receive(:generate).and_return('not json', generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).to have_received(:generate).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'accepts a structured Hash returned by a repair request for a JSON string' do
    allow(reviewer).to receive(:generate).and_return('not json', structured_generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).to have_received(:generate).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'repairs generate candidates with invalid ids once' do
    invalid_generate = JSON.generate(summary: 'bad', candidates: [{ file: 'app/models/order.rb' }])
    allow(reviewer).to receive(:generate).and_return(invalid_generate, generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).to have_received(:generate).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'raises a clear error when generate JSON repair fails and no other model is left' do
    allow(reviewer).to receive(:generate).and_return('not json', 'still not json')

    expect do
      pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    end.to raise_error(Aireview::ParseError, /invalid generate result JSON after repair/)
    expect(reviewer).to have_received(:generate).with(hash_including(pinned: true)).once
    expect(reviewer).to have_received(:exclude_answered_model)
      .with(stage: 'generate', reason: /invalid result: LLM returned invalid generate result JSON after repair/)
  end

  it 'restarts the stage on the next model with the original prompt after a failed repair' do
    log_output = StringIO.new
    pipeline = described_class.new(config: config, reviewer: reviewer, logger: Logger.new(log_output))
    prompts = []
    responses = ['not json', 'still not json', generate_result([candidates.first])]
    allow(reviewer).to receive(:generate) do |**kwargs|
      prompts << kwargs
      responses.shift
    end
    allow(reviewer).to receive(:exclude_answered_model).and_return('gemini/gemini-3.7-flash')
    allow(reviewer).to receive(:answered_model).and_return('gemini/gemini-3.6-flash (2/2)')

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(result).to include('Tax is no longer included')
    expect(prompts.map { |kwargs| kwargs[:pinned] }).to eq([nil, true, nil])
    expect(prompts.first[:user_prompt]).to eq(prompts.last[:user_prompt])
    expect(log_output.string).to include(
      'Pipeline generate: restarting on the next model after gemini/gemini-3.7-flash'
    )
    expect(log_output.string).to include('completed with 1 candidate(s) (model=gemini/gemini-3.6-flash (2/2))')
  end

  it 'restarts the stage when the answering model has no attempts left for the repair' do
    allow(reviewer).to receive(:generate).with(hash_including(pinned: true))
      .and_raise(Aireview::RepairImpossibleError, 'attempt limit of 3 reached')
    allow(reviewer).to receive(:generate).with(hash_excluding(pinned: true))
      .and_return('not json', generate_result([candidates.first]))
    allow(reviewer).to receive(:exclude_answered_model).and_return('gemini/gemini-3.7-flash')

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(result).to include('Tax is no longer included')
    expect(reviewer).to have_received(:exclude_answered_model)
      .with(stage: 'generate', reason: 'repair impossible: attempt limit of 3 reached')
  end

  it 'treats a repair request over the stage limit as an invalid result and restarts on the next model' do
    allow(config).to receive(:max_prompt_chars).with('generate').and_return(5_000)
    allow(reviewer).to receive(:generate).and_return('not json ' * 1_000, generate_result([candidates.first]))
    allow(reviewer).to receive(:exclude_answered_model).and_return('gemini/gemini-3.7-flash')

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(result).to include('Tax is no longer included')
    expect(reviewer).to have_received(:generate).twice
    expect(reviewer).not_to have_received(:generate).with(hash_including(pinned: true))
    expect(reviewer).to have_received(:exclude_answered_model)
      .with(stage: 'generate', reason: /invalid result: repair request does not fit the stage limit: Generate request is \d+ chars/)
  end

  it 'passes the weaker-critique flag and the critique rule through to the report and dry-run' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )
    allow(reviewer).to receive(:critique_weaker?).and_return(true)
    allow(config).to receive(:routing).and_return(instance_double('Aireview::ModelPool', rule: 'not_below_generate, weaker allowed'))

    expect(pipeline.run(merge_request: merge_request, changes: changes)).to include('weaker than Generate')
    expect(pipeline.run(merge_request: merge_request, changes: changes, critique: false))
      .not_to include('weaker than Generate')
    expect(pipeline.dry_run_prompts(merge_request: merge_request, changes: changes)[:critique_rule])
      .to eq('not_below_generate, weaker allowed')
    expect(pipeline.dry_run_prompts(merge_request: merge_request, changes: changes, critique: false)[:critique_rule]).to be_nil
  end

  it 'keeps generate candidates when critique restarts on another model' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      'not json', 'still not json',
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )
    allow(reviewer).to receive(:exclude_answered_model).and_return('gemini/gemini-3.8-flash')

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(reviewer).to have_received(:generate).once
    expect(reviewer).to have_received(:critique).exactly(3).times
    expect(reviewer).to have_received(:exclude_answered_model).with(stage: 'critique', reason: /invalid result/)
  end

  it 'repairs invalid critique JSON once' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      'not json',
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(reviewer).to have_received(:critique).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'parses generate JSON wrapped in code fences without repair' do
    fenced_generate = <<~JSON
      ```json
      #{generate_result([candidates.first])}
      ```
    JSON
    allow(reviewer).to receive(:generate).and_return(fenced_generate)

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).to have_received(:generate).once
    expect(result).to include('Tax is no longer included')
  end

  it 'parses repaired critique JSON wrapped in code fences' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      'not json',
      <<~JSON
        ```json
        #{JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])}
        ```
      JSON
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(reviewer).to have_received(:critique).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'renders generate candidates directly when critique is disabled' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique)

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(reviewer).not_to have_received(:critique)
    expect(result).to include('Tax is no longer included')
  end

  it 'keeps up to three important accepted findings after critique' do
    important = 3.times.map { |index| finding("C#{index + 1}", category: 'bug', problem: "Confirmed bug #{index + 1}") }
    allow(reviewer).to receive(:generate).and_return(generate_result(important))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: important.map { |candidate| { id: candidate[:id], decision: 'keep', reason: 'confirmed by diff' } }
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Confirmed bug 1')
    expect(result).to include('Confirmed bug 2')
    expect(result).to include('Confirmed bug 3')
  end

  it 'renders at most three findings in the final report' do
    important = 4.times.map { |index| finding("C#{index + 1}", category: 'bug', problem: "Confirmed bug #{index + 1}") }
    allow(reviewer).to receive(:generate).and_return(generate_result(important))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: important.map { |candidate| { id: candidate[:id], decision: 'keep', reason: 'confirmed by diff' } }
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Confirmed bug 1')
    expect(result).to include('Confirmed bug 2')
    expect(result).to include('Confirmed bug 3')
    expect(result).not_to include('Confirmed bug 4')
  end

  it 'does not render accepted minor maintainability findings' do
    minor = finding('C1', category: 'Maintainability', severity: 'MINOR', problem: 'Name is unclear')
    allow(reviewer).to receive(:generate).and_return(generate_result([minor]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).not_to include('Name is unclear')
    expect(result).to include('## Important findings')
    expect(result).to include('None found.')
    expect(result).to include('ok')
  end

  it 'renders the expected markdown structure' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to eq(<<~MARKDOWN.rstrip)
      ## Summary

      MR recalculates order totals during checkout.

      ## Mismatches

      None found.

      ## Important findings

      - **Where**: app/models/order.rb:12
      - **Problem**: Tax is no longer included
      - **Why it matters**: Tax is no longer included can break checkout
      - **Suggestion**: Keep the previous calculation or update the requirement

      ## Result

      needs attention

      This report was generated by an AI and may contain mistakes. Verify the findings by hand before acting on them.
    MARKDOWN
  end

  it 'logs generate and critique pipeline stages' do
    log_output = StringIO.new
    stage_logger = Logger.new(log_output)
    stage_pipeline = described_class.new(config: config, reviewer: reviewer, logger: stage_logger)
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    stage_pipeline.run(merge_request: merge_request, changes: changes)

    expect(log_output.string).to include('Pipeline generate pass started (model=gemini-generate)')
    expect(log_output.string).to include('Pipeline generate pass completed with 1 candidate(s)')
    expect(log_output.string).to include('Pipeline critique pass started (model=gemini-critique)')
    expect(log_output.string).to include('Pipeline critique pass completed with 1 verdict(s)')
    expect(log_output.string).to include('Pipeline finished with 1 accepted finding(s)')
  end

  it 'passes coverage from the context to the report and to dry-run output' do
    config = instance_double(
      'Aireview::Config',
      require_models!: true, review_instructions: nil, review_language: 'en',
      secret_patterns: [], secret_files: [],
      max_prompt_chars: 400_000, max_diff_chars: 600, max_mr_description_chars: 8_000,
      max_jira_description_chars: 8_000, max_jira_comment_chars: 2_000,
      generate_model: 'g', generate_temperature: 0, critique_model: 'c', critique_temperature: 0,
      llm_time_budget: 1_800, overloaded_quarantine: 120, fallback_names: [], warnings: [],
      routing: instance_double('Aireview::StageChains', rule: nil), api_key_counts: {'gemini' => 1},
      stage_model_source: nil, stage_fallbacks_source: nil, stage_provider_source: 'built-in', layer_paths: {},
      jev_shadow?: false
    )
    allow_model_engine(config)
    pipeline = described_class.new(config: config, reviewer: reviewer, logger: logger)
    big = changes.first.merge('new_path' => 'big.rb', 'old_path' => 'big.rb', 'diff' => "@@ -1,3 +1,3 @@\n#{"+x\n" * 300}")
    allow(reviewer).to receive(:generate).and_return(generate_result([]))

    result = pipeline.run(merge_request: merge_request, changes: changes + [big], critique: false)
    dry_run = pipeline.dry_run_prompts(merge_request: merge_request, changes: changes + [big])

    expect(result).to include('ok. Partial review: 1 files not reviewed.')
    expect(result).to include("## Not reviewed\n\n- big.rb")
    expect(dry_run[:coverage].files_not_shown).to eq(['big.rb'])
    expect(dry_run[:sizes][:diff_budget]).to eq(600)
    expect(dry_run.dig(:generate_prompt, :user_prompt)).to include('[1 file(s) not shown: big.rb]')
  end

  it 'treats a repair request over the stage limit as an invalid result of that model' do
    allow(config).to receive(:max_prompt_chars).with('generate').and_return(5_000)
    allow(config).to receive(:max_prompt_chars).with('critique').and_return(400_000)
    allow(reviewer).to receive(:generate).and_return('not json ' * 1_000)

    expect { pipeline.run(merge_request: merge_request, changes: changes) }
      .to raise_error(Aireview::ParseError,
                      /repair request does not fit the stage limit: Generate request is \d+ chars, over llm.generate.max_prompt_chars=5000/)
    expect(reviewer).to have_received(:generate).once
    expect(reviewer).to have_received(:exclude_answered_model).with(stage: 'generate', reason: /repair request does not fit/)
  end

  it 'reports the fallback model used by a stage and lists reserves in dry-run output' do
    allow(config).to receive(:fallback_names).with('generate').and_return(['gemini/g2'])
    allow(config).to receive(:api_key_counts).with(['generate']).and_return('gemini' => 2)
    allow(reviewer).to receive(:generate).and_return(generate_result([]))
    allow(reviewer).to receive(:fallback_models).and_return('generate' => 'gemini/g2')

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    dry_run = pipeline.dry_run_prompts(merge_request: merge_request, changes: changes, critique: false)

    expect(result).to include('Fallback model used: generate — gemini/g2.')
    expect(dry_run[:generate_fallbacks]).to eq(['gemini/g2'])
    expect(dry_run[:critique_fallbacks]).to eq([])
    expect(dry_run[:api_keys]).to eq('gemini' => 2)
    expect(dry_run[:time_budget]).to eq(1_800)
    expect(dry_run[:overloaded_quarantine]).to eq(120)
  end

  it 'checks candidates against the shown diff before the critique pass' do
    log_output = StringIO.new
    pipeline = described_class.new(config: config, reviewer: reviewer, logger: Logger.new(log_output))
    candidates = [
      finding('C1', category: 'bug', problem: 'Quote is off').merge(quoted_code: 'total = subtotal * 2'),
      finding('C2', category: 'bug', problem: 'Line is off').merge(line: 99),
      finding('C3', category: 'bug', problem: 'File is off').merge(file: 'app/models/invoice.rb')
    ]
    allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{id: 'C1', decision: 'keep', reason: 'confirmed'},
                               {id: 'C2', decision: 'keep', reason: 'confirmed'}])
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(reviewer).to have_received(:critique) do |user_prompt:, **|
      expect(user_prompt).to include('"note": "quoted_code not found in the diff shown to the model"')
      expect(user_prompt).to include('"note": "line was outside the shown hunks and has been reset to null"')
      expect(user_prompt).not_to include('C3')
    end
    expect(result).to include('- **Where**: app/models/order.rb:12 (quote not found in the diff)')
    expect(result).to include("- **Where**: app/models/order.rb\n- **Problem**: Line is off")
    expect(log_output.string).to include('Candidate C3 dropped: file "app/models/invoice.rb" is not in the merge request')
  end

  it 'keeps the missing-quote mark in the report without a critique pass' do
    candidate = finding('C1', category: 'bug', problem: 'Quote is off').merge(quoted_code: 'nope')
    allow(reviewer).to receive(:generate).and_return(generate_result([candidate]))

    result = pipeline.run(merge_request: merge_request, changes: changes, critique: false)

    expect(result).to include('- **Where**: app/models/order.rb:12 (quote not found in the diff)')
    expect(result).to include('needs attention')
  end

  it 'skips the critique pass when every candidate points at a file outside the merge request' do
    allow(reviewer).to receive(:generate)
      .and_return(generate_result([finding('C1', category: 'bug', problem: 'x').merge(file: 'nope.rb')]))
    allow(reviewer).to receive(:critique)

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(reviewer).not_to have_received(:critique)
    expect(result).to include("## Result\n\nok")
  end

  it 'skips the critique request when generate returns no candidates' do
    log_output = StringIO.new
    pipeline = described_class.new(config: config, reviewer: reviewer, logger: Logger.new(log_output))
    allow(reviewer).to receive(:generate).and_return(generate_result([]))
    allow(reviewer).to receive(:critique)

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include("## Result\n\nok")
    expect(reviewer).not_to have_received(:critique)
    expect(log_output.string).to include('Pipeline critique pass skipped: no candidates')
  end

  it 'validates LLM models before rendering dry-run prompts' do
    pipeline.dry_run_prompts(merge_request: merge_request, changes: changes)

    expect(config).to have_received(:require_models!)
    expect(config).not_to have_received(:require_llm_configuration!)
  end

  it 'applies critique refinements but preserves file, line, and quoted code from generate' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          {
            id: 'C1',
            decision: 'keep',
            reason: 'confirmed with better wording',
            refinement: {
              problem: 'Refined problem',
              why: 'Refined impact',
              suggestion: 'Refined suggestion',
              category: 'regression',
              severity: 'critical',
              file: 'evil.rb',
              line: 999,
              quoted_code: 'evil'
            }
          }
        ]
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('- **Where**: app/models/order.rb:12')
    expect(result).to include('Refined problem')
    expect(result).to include('Refined impact')
    expect(result).to include('Refined suggestion')
    expect(result).not_to include('evil.rb')
  end

  it 'raises a clear error when critique skips a candidate id' do
    allow(reviewer).to receive(:generate).and_return(generate_result(candidates))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C2', decision: 'reject', reason: 'not supported by diff' }
        ]
      ),
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C2', decision: 'reject', reason: 'not supported by diff' }
        ]
      )
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /missing verdict ids: C3/)
  end

  it 'raises a clear error when critique introduces an unknown candidate id' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C9', decision: 'keep', reason: 'hallucinated id' }]),
      JSON.generate(verdicts: [{ id: 'C9', decision: 'keep', reason: 'hallucinated id' }])
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /unknown verdict ids: C9/)
  end

  it 'raises a clear error when critique duplicates a verdict id' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C1', decision: 'reject', reason: 'duplicate verdict' }
        ]
      ),
      JSON.generate(
        verdicts: [
          { id: 'C1', decision: 'keep', reason: 'confirmed by diff' },
          { id: 'C1', decision: 'reject', reason: 'duplicate verdict' }
        ]
      )
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /duplicate verdict ids: C1/)
  end

  it 'raises a clear error when critique uses an invalid verdict decision' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'skip', reason: 'unsupported decision' }]),
      JSON.generate(verdicts: [{ id: 'C1', decision: 'skip', reason: 'unsupported decision' }])
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /invalid verdict decision for C1/)
  end

  it 'raises a clear error when reject verdict includes refinement' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          {
            id: 'C1',
            decision: 'reject',
            reason: 'not supported by diff',
            refinement: { problem: 'should not be here' }
          }
        ]
      ),
      JSON.generate(
        verdicts: [
          {
            id: 'C1',
            decision: 'reject',
            reason: 'not supported by diff',
            refinement: { problem: 'should not be here' }
          }
        ]
      )
    )

    expect do
      pipeline.run(merge_request: merge_request, changes: changes)
    end.to raise_error(Aireview::ParseError, /reject verdict cannot include refinement for C1/)
  end

  it 'matches critique ids after trimming whitespace' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: ' C1 ', decision: ' keep ', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
  end

  it 'keeps original text when refinement sets a field to null' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(
        verdicts: [
          {
            id: 'C1',
            decision: 'keep',
            reason: 'confirmed by diff',
            refinement: {
              problem: nil,
              why: 'Refined impact',
              suggestion: nil
            }
          }
        ]
      )
    )

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(result).to include('Refined impact')
    expect(result).to include('Keep the previous calculation or update the requirement')
  end
end
