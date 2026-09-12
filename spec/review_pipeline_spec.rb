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
      critique_temperature: 0
    )
  end

  let(:reviewer) { instance_double('Aireview::Reviewer') }
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

  it 'raises a clear error when generate JSON repair fails' do
    allow(reviewer).to receive(:generate).and_return('not json', 'still not json')

    expect do
      pipeline.run(merge_request: merge_request, changes: changes, critique: false)
    end.to raise_error(Aireview::ParseError, /invalid generate result JSON after repair/)
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
      generate_model: 'g', generate_temperature: 0, critique_model: 'c', critique_temperature: 0
    )
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

  it 'refuses a repair request that exceeds the stage limit' do
    allow(config).to receive(:max_prompt_chars).with(:generate).and_return(5_000)
    allow(config).to receive(:max_prompt_chars).with(:critique).and_return(400_000)
    allow(reviewer).to receive(:generate).and_return('not json ' * 1_000)

    expect { pipeline.run(merge_request: merge_request, changes: changes) }
      .to raise_error(Aireview::ContextBudgetError, /Generate request is \d+ chars, over llm.generate.max_prompt_chars=5000/)
    expect(reviewer).to have_received(:generate).once
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
