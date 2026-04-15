require 'aireview/review_pipeline'
require 'stringio'

RSpec.describe Aireview::ReviewPipeline do
  let(:config) do
    instance_double(
      'Aireview::Config',
      require_models!: true,
      require_llm_configuration!: true,
      review_instructions: nil,
      review_language: 'ru',
      secret_patterns: [],
      secret_files: [],
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

  let(:changes_text) do
    <<~DIFF
      diff --git a/app/models/order.rb b/app/models/order.rb
      +total = subtotal
    DIFF
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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(result).to include('MR recalculates order totals during checkout.')
    expect(result).to include('Не найдено.')
    expect(result).to include('ok')
  end

  it 'repairs invalid generate JSON once' do
    allow(reviewer).to receive(:generate).and_return('not json', generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text, critique: false)

    expect(reviewer).to have_received(:generate).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'repairs generate candidates with invalid ids once' do
    invalid_generate = JSON.generate(summary: 'bad', candidates: [{ file: 'app/models/order.rb' }])
    allow(reviewer).to receive(:generate).and_return(invalid_generate, generate_result([candidates.first]))

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text, critique: false)

    expect(reviewer).to have_received(:generate).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'raises a clear error when generate JSON repair fails' do
    allow(reviewer).to receive(:generate).and_return('not json', 'still not json')

    expect do
      pipeline.run(merge_request: merge_request, changes_text: changes_text, critique: false)
    end.to raise_error(Aireview::ParseError, /invalid generate result JSON after repair/)
  end

  it 'repairs invalid critique JSON once' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      'not json',
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text, critique: false)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(reviewer).to have_received(:critique).twice
    expect(result).to include('Tax is no longer included')
  end

  it 'renders generate candidates directly when critique is disabled' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique)

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text, critique: false)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(result).not_to include('Name is unclear')
    expect(result).to include('## Важные замечания')
    expect(result).to include('Не найдено.')
    expect(result).to include('ok')
  end

  it 'renders the expected markdown structure' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'keep', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(result).to eq(<<~MARKDOWN.rstrip)
      ## Сводка

      MR recalculates order totals during checkout.

      ## Несоответствия

      Не найдено.

      ## Важные замечания

      - **Где**: app/models/order.rb:12
      - **Проблема**: Tax is no longer included
      - **Почему важно**: Tax is no longer included can break checkout
      - **Предложение**: Keep the previous calculation or update the requirement

      ## Результат

      needs attention

      Отчёт сгенерирован ИИ и может содержать ошибки. Проверьте замечания вручную перед принятием решений.
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

    stage_pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(log_output.string).to include('Pipeline generate pass started (model=gemini-generate)')
    expect(log_output.string).to include('Pipeline generate pass completed with 1 candidate(s)')
    expect(log_output.string).to include('Pipeline critique pass started (model=gemini-critique)')
    expect(log_output.string).to include('Pipeline critique pass completed with 1 verdict(s)')
    expect(log_output.string).to include('Pipeline finished with 1 accepted finding(s)')
  end

  it 'validates LLM models before rendering dry-run prompts' do
    pipeline.dry_run_prompts(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(result).to include('- **Где**: app/models/order.rb:12')
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
      pipeline.run(merge_request: merge_request, changes_text: changes_text)
    end.to raise_error(Aireview::ParseError, /missing verdict ids: C3/)
  end

  it 'raises a clear error when critique introduces an unknown candidate id' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C9', decision: 'keep', reason: 'hallucinated id' }]),
      JSON.generate(verdicts: [{ id: 'C9', decision: 'keep', reason: 'hallucinated id' }])
    )

    expect do
      pipeline.run(merge_request: merge_request, changes_text: changes_text)
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
      pipeline.run(merge_request: merge_request, changes_text: changes_text)
    end.to raise_error(Aireview::ParseError, /duplicate verdict ids: C1/)
  end

  it 'raises a clear error when critique uses an invalid verdict decision' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: 'C1', decision: 'skip', reason: 'unsupported decision' }]),
      JSON.generate(verdicts: [{ id: 'C1', decision: 'skip', reason: 'unsupported decision' }])
    )

    expect do
      pipeline.run(merge_request: merge_request, changes_text: changes_text)
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
      pipeline.run(merge_request: merge_request, changes_text: changes_text)
    end.to raise_error(Aireview::ParseError, /reject verdict cannot include refinement for C1/)
  end

  it 'matches critique ids after trimming whitespace' do
    allow(reviewer).to receive(:generate).and_return(generate_result([candidates.first]))
    allow(reviewer).to receive(:critique).and_return(
      JSON.generate(verdicts: [{ id: ' C1 ', decision: ' keep ', reason: 'confirmed by diff' }])
    )

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

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

    result = pipeline.run(merge_request: merge_request, changes_text: changes_text)

    expect(result).to include('Tax is no longer included')
    expect(result).to include('Refined impact')
    expect(result).to include('Keep the previous calculation or update the requirement')
  end
end
