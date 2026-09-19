require 'stringio'
require 'json'
require 'aireview/model_checker'
require 'aireview/stage_chains'

RSpec.describe Aireview::ModelChecker do
  include_context 'LLM errors'

  let(:out) { StringIO.new }
  let(:log_output) { StringIO.new }
  let(:sleeps) { [] }
  let(:config) do
    instance_double(
      'Aireview::Config',
      require_llm_configuration!: true, require_models!: true,
      review_instructions: nil, review_language: 'ru', secret_patterns: [], secret_files: [],
      max_prompt_chars: 400_000, max_diff_chars: 120_000, max_mr_description_chars: 8_000,
      max_jira_description_chars: 8_000, max_jira_comment_chars: 2_000,
      generate_model: 'gemini-a', generate_temperature: 0, critique_model: 'gemini-b', critique_temperature: 0,
      llm_time_budget: 1_800, overloaded_quarantine: 120, llm_timeout: 60, fallback_names: [], warnings: [],
      api_key_counts: {'gemini' => 1},
      stage_model_source: nil, stage_fallbacks_source: nil, stage_provider_source: 'built-in', layer_paths: {},
      routing: routing
    )
  end
  let(:routing) do
    Aireview::StageChains.new(
      'generate' => [candidate('gemini-a'), candidate('qwen', provider: 'ollama')],
      'critique' => [candidate('gemini-b'), candidate('gemini-a')]
    )
  end
  let(:client) { instance_double('Aireview::LlmClient') }
  let(:checker) do
    described_class.new(config: config, out: out, logger: Logger.new(log_output), client: client,
                        sleeper: ->(seconds) { sleeps << seconds })
  end

  def candidate(model, provider: 'gemini')
    Aireview::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: 400_000)
  end

  let(:generate_ok) { JSON.generate(summary: 'ok', candidates: []) }
  let(:critique_ok) { JSON.generate(verdicts: [{id: 'C1', decision: 'keep', reason: 'fine'}]) }

  before do
    allow(config).to receive(:stage_chain) { |stage| routing.chain(stage) }
    allow(config).to receive(:provider_api_keys) { |provider| provider == 'ollama' ? [nil] : ['key-one'] }
  end

  # The client answers by a script; the check is that the checker sends the
  # production prompts with the production schemas, the provider's first key
  # and the config timeout.
  def stub_probe(answers)
    allow(client).to receive(:request) do |prompt, candidate:, key:, timeout:, key_index: 0|
      expect(key).to eq(candidate.provider == 'ollama' ? nil : 'key-one')
      expect(key_index).to eq(0)
      expect(timeout).to eq(60.0)
      expect(prompt.temperature).to eq(0)
      expect(prompt.schema).to eq(prompt.stage == 'critique' ? Aireview::CritiqueOutputSchema : Aireview::GenerateOutputSchema)
      expect(prompt.system).to include(prompt.stage == 'critique' ? 'second pass' : 'first pass')
      expect(prompt.user).to include('app/models/order.rb')
      answer = answers.fetch([candidate.model, prompt.stage]).shift
      raise answer if answer.is_a?(Exception)

      instance_double('RubyLLM::Message', content: answer)
    end
  end

  it 'probes every model of both chains once per schema with the production prompts and passes' do
    stub_probe(
      ['gemini-a', 'generate'] => [generate_ok], ['gemini-a', 'critique'] => [critique_ok],
      ['qwen', 'generate'] => [generate_ok], ['qwen', 'critique'] => [critique_ok],
      ['gemini-b', 'generate'] => [generate_ok], ['gemini-b', 'critique'] => [critique_ok]
    )

    expect(checker.run).to eq(0)
    expect(client).to have_received(:request).exactly(6).times
    lines = out.string.lines.map(&:strip)
    expect(lines.first).to eq('Checking 3 model(s) with the generate and critique schemas')
    expect(lines[1]).to match(/\Agemini\/gemini-a\s+generate ok \(\d+\.\ds\)\z/)
    expect(lines.last).to eq('Result: 6 ok -> PASSED')
  end

  it 'fails on a missing model, an invalid result, an unverifiable one, a fatal error, and skips a stopped Ollama' do
    stub_probe(
      ['gemini-a', 'generate'] => [missing_model_error('gemini-a')],
      ['gemini-a', 'critique'] => [JSON.generate(verdicts: [{id: 'C9', decision: 'keep', reason: 'x'}])],
      ['qwen', 'generate'] => [Faraday::ConnectionFailed.new('Connection refused')],
      ['qwen', 'critique'] => [Faraday::ConnectionFailed.new('Connection refused')],
      ['gemini-b', 'generate'] => [RubyLLM::ServiceUnavailableError.new('high demand')],
      ['gemini-b', 'critique'] => [RubyLLM::UnauthorizedError.new('bad key')]
    )

    expect(checker.run).to eq(1)
    text = out.string
    expect(text).to include('gemini/gemini-a', 'generate missing: models/gemini-a is not found')
    expect(text).to include('critique invalid: LLM returned invalid critique result: ')
    expect(text).to include('ollama/qwen', 'generate skipped: Connection refused')
    expect(text).to include('generate unverified: high demand')
    expect(text).to include('critique failed: bad key')
    expect(text).to end_with("Result: 1 missing, 1 invalid, 2 skipped, 1 unverified, 1 failed -> FAILED\n")
  end

  it 'fails on a skipped Ollama model in strict mode: on a runner with Ollama, unreachable means broken' do
    checker = described_class.new(config: config, out: out, logger: Logger.new(log_output), client: client,
                                  sleeper: ->(seconds) { sleeps << seconds }, strict: true)
    stub_probe(
      ['gemini-a', 'generate'] => [generate_ok], ['gemini-a', 'critique'] => [critique_ok],
      ['qwen', 'generate'] => [Errno::ECONNREFUSED.new], ['qwen', 'critique'] => [Errno::ECONNREFUSED.new],
      ['gemini-b', 'generate'] => [generate_ok], ['gemini-b', 'critique'] => [critique_ok]
    )

    expect(checker.run).to eq(1)
    expect(out.string).to end_with("Result: 4 ok, 2 skipped -> FAILED\n")
  end

  it 'passes when the only problems are skipped Ollama models' do
    stub_probe(
      ['gemini-a', 'generate'] => [generate_ok], ['gemini-a', 'critique'] => [critique_ok],
      ['qwen', 'generate'] => [Errno::ECONNREFUSED.new], ['qwen', 'critique'] => [Errno::ECONNREFUSED.new],
      ['gemini-b', 'generate'] => [generate_ok], ['gemini-b', 'critique'] => [critique_ok]
    )

    expect(checker.run).to eq(0)
    expect(out.string).to end_with("Result: 4 ok, 2 skipped -> PASSED\n")
  end

  it 'retries a rate limit once with the provider hint and reports it as unverified if it persists' do
    limited = RubyLLM::RateLimitError.new('Quota exceeded. Please retry in 7s.')
    stub_probe(
      ['gemini-a', 'generate'] => [limited, generate_ok], ['gemini-a', 'critique'] => [limited, limited],
      ['qwen', 'generate'] => [generate_ok], ['qwen', 'critique'] => [critique_ok],
      ['gemini-b', 'generate'] => [generate_ok], ['gemini-b', 'critique'] => [critique_ok]
    )

    expect(checker.run).to eq(1)
    expect(sleeps).to eq([7.0, 7.0])
    expect(out.string).to include('gemini/gemini-a', 'generate ok')
    expect(out.string).to include('critique unverified: Quota exceeded. Please retry in 7s.')
    expect(log_output.string).to include('Model check: gemini/gemini-a rate limited, retrying once in 7s')
  end
end
