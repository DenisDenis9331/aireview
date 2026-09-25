require 'json'
require 'stringio'
require 'aireview/review_pipeline'
require 'aireview/stage_chains'

# The RubyLLM 2 answer at the pipeline: real messages with the JSON text,
# the real reviewer and router, only the request is scripted. RubyLLM 2
# returns structured output as text; the pipeline must still send an answer
# that breaks the schema to the next model at once and repair only a text
# that is not JSON, as with RubyLLM 1.x.
RSpec.describe 'RubyLLM answer through the reviewer and the pipeline' do
  let(:config) do
    instance_double(
      'Aireview::Config',
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
      generate_model: 'gemini-a',
      generate_temperature: 0.3,
      critique_model: 'gemini-c1',
      critique_temperature: 0,
      llm_timeout: 60,
      llm_time_budget: 1_800,
      overloaded_quarantine: 120,
      provider_api_keys: ['key-one']
    )
  end
  let(:routing) do
    Aireview::StageChains.new(
      'generate' => [candidate('gemini-a')],
      'critique' => [candidate('gemini-c1'), candidate('gemini-c2')]
    )
  end
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:router) do
    Aireview::LlmRouter.new(config: config, routing: routing, logger: logger, clock: -> { 0.0 }, sleeper: ->(_) {})
  end
  let(:client) { instance_double('Aireview::LlmClient') }
  let(:reviewer) { Aireview::Reviewer.new(config: config, logger: logger, router: router, client: client) }
  let(:pipeline) { Aireview::ReviewPipeline.new(config: config, reviewer: reviewer, logger: logger) }
  let(:requests) { [] }

  let(:merge_request) do
    {'title' => 'Fix order total', 'description' => 'AIR-1', 'source_branch' => 'fix/order-total',
     'target_branch' => 'main', 'author' => {'name' => 'Denis'}}
  end
  let(:changes) do
    [{'old_path' => 'app/models/order.rb', 'new_path' => 'app/models/order.rb',
      'diff' => "@@ -10,3 +10,3 @@\n-total = subtotal + tax\n+total = subtotal\n"}]
  end
  let(:generate_answer) do
    JSON.generate(
      summary: 'MR recalculates order totals.',
      candidates: [{id: 'C1', file: 'app/models/order.rb', line: 10, quoted_code: 'total = subtotal',
                    problem: 'Tax is no longer included', why: 'Checkout undercharges',
                    suggestion: 'Add the tax back', category: 'bug', severity: 'major'}]
    )
  end

  def candidate(model)
    Aireview::ModelCandidate.new(provider: 'gemini', model: model, max_prompt_chars: 400_000)
  end

  def verdict(decision)
    JSON.generate(verdicts: [{id: 'C1', decision: decision, reason: 'checked against the diff'}])
  end

  # An answer that stopped for a reason other than the end of the text.
  def stopped(content, reason)
    {content: content, finish_reason: reason}
  end

  # "model → answers" (a text, or a Hash with the finish reason); every
  # request is recorded as [stage, model, :repair?].
  def answers(script)
    allow(client).to receive(:request) do |prompt, candidate:, **|
      repair = prompt.user.start_with?('The previous')
      requests << [prompt.stage, candidate.model, repair ? :repair : :request]
      answer = script.fetch(candidate.model).shift
      answer = {content: answer} unless answer.is_a?(Hash)
      RubyLLM::Message.new(role: :assistant, **answer)
    end
  end

  before do
    allow(router).to receive(:rand).and_return(1.0)
  end

  it 'takes a valid JSON answer with one request per stage' do
    answers('gemini-a' => [generate_answer], 'gemini-c1' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([%w[generate gemini-a], %w[critique gemini-c1]].map { |call| [*call, :request] })
  end

  it 'moves a schema-breaking answer to the next model without a repair request' do
    answers('gemini-a' => [generate_answer], 'gemini-c1' => [verdict('maybe')], 'gemini-c2' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c2', :request]
    ])
  end

  it 'moves a JSON null answer to the next model without a repair request' do
    answers('gemini-a' => [generate_answer], 'gemini-c1' => ['null'], 'gemini-c2' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c2', :request]
    ])
  end

  it 'repairs a text that is not JSON on the same model, then moves on when the repair fails too' do
    answers('gemini-a' => [generate_answer], 'gemini-c1' => ['{"verdicts": [', 'still not json'],
            'gemini-c2' => [verdict('reject')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).not_to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c1', :repair],
      ['critique', 'gemini-c2', :request]
    ])
  end

  it 'moves an answer cut off at the output limit to the next model without a repair request' do
    answers('gemini-a' => [generate_answer],
            'gemini-c1' => [stopped('{"verdicts": [{"id": "C1", "deci', :max_tokens)],
            'gemini-c2' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c2', :request]
    ])
    expect(log_output.string).to include('critique result was cut off at the output limit (max_tokens)')
    expect(log_output.string).not_to include('requesting one repair')
  end

  it 'moves an empty answer blocked by the provider to the next model without a repair request' do
    answers('gemini-a' => [generate_answer], 'gemini-c1' => [stopped('', :content_filter)],
            'gemini-c2' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c2', :request]
    ])
    expect(log_output.string).to include('critique result was blocked by the provider (content_filter)')
  end

  it 'takes a valid answer whatever the finish reason' do
    answers('gemini-a' => [stopped(generate_answer, :max_tokens)],
            'gemini-c1' => [stopped(verdict('keep'), :max_tokens)])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([%w[generate gemini-a], %w[critique gemini-c1]].map { |call| [*call, :request] })
  end

  it 'moves on when the repair itself is cut off at the output limit' do
    answers('gemini-a' => [generate_answer],
            'gemini-c1' => ['{"verdicts": [', stopped('{"verdicts": [{"id": "C1"', :max_tokens)],
            'gemini-c2' => [verdict('keep')])

    result = pipeline.run(merge_request: merge_request, changes: changes)

    expect(result).to include('Tax is no longer included')
    expect(requests).to eq([
      ['generate', 'gemini-a', :request],
      ['critique', 'gemini-c1', :request],
      ['critique', 'gemini-c1', :repair],
      ['critique', 'gemini-c2', :request]
    ])
    expect(log_output.string).to include('critique result repair was cut off at the output limit (max_tokens)')
  end

  it 'reads an answer like RubyLLM 1.x: empty stays text, JSON null is nil' do
    expect(Aireview::LlmClient.content(RubyLLM::Message.new(role: :assistant, content: ''))).to eq('')
    expect(Aireview::LlmClient.content(RubyLLM::Message.new(role: :assistant, content: 'null'))).to be_nil
    expect(Aireview::LlmClient.content(RubyLLM::Message.new(role: :assistant, content: '{"a": 1}'))).to eq('a' => 1)
    expect(Aireview::LlmClient.content(RubyLLM::Message.new(role: :assistant, content: 'text'))).to eq('text')
  end
end
