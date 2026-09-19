require 'stringio'
require 'aireview/reviewer'
require 'aireview/stage_chains'

# The stages on top of the router and the client: walking the models is
# checked by llm_router_spec, the request by llm_client_spec; here — that
# the stages build the prompt, that the router and the client fit together,
# and two end-to-end scenarios with the real router and real provider errors.
RSpec.describe Aireview::Reviewer do
  include_context 'LLM errors'

  let(:config) do
    instance_double(
      'Aireview::Config',
      require_llm_configuration!: true,
      generate_temperature: 0.3,
      critique_temperature: 0,
      llm_timeout: 60,
      llm_time_budget: 1_800,
      overloaded_quarantine: 120
    )
  end
  let(:generate_fallbacks) { [] }
  let(:gemini_keys) { ['key-one'] }
  let(:routing) do
    Aireview::StageChains.new(
      'generate' => [candidate('gemini-3.7-flash'), *generate_fallbacks],
      'critique' => [candidate('gemini-3.8-flash')]
    )
  end
  let(:client) { instance_double('Aireview::LlmClient') }
  let(:requests) { [] }
  let(:clock) { {time: 0.0} }
  let(:sleeps) { [] }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:router) do
    Aireview::LlmRouter.new(config: config, routing: routing, logger: logger, clock: -> { clock[:time] },
                            sleeper: lambda { |seconds|
                              sleeps << seconds
                              clock[:time] += seconds
                            })
  end
  let(:reviewer) { described_class.new(config: config, logger: logger, router: router, client: client) }

  def candidate(model, provider: 'gemini')
    Aireview::ModelCandidate.new(provider: provider, model: model, max_prompt_chars: 400_000)
  end

  # The client answers by a "model → answers" script; every call is recorded.
  def answers(script)
    allow(client).to receive(:request) do |prompt, candidate:, key:, timeout:, key_index: 0|
      requests << {stage: prompt.stage, model: candidate.model, key: key, key_index: key_index, timeout: timeout,
                   temperature: prompt.temperature, schema: prompt.schema, system: prompt.system, user: prompt.user}
      answer = script.fetch(candidate.model).shift
      raise answer if answer.is_a?(Exception)

      instance_double('RubyLLM::Message', content: answer)
    end
  end

  before do
    allow(config).to receive(:provider_api_keys) { |provider| provider.to_s == 'ollama' ? [nil] : gemini_keys }
    allow(router).to receive(:rand).with(Aireview::LlmRouter::SHORT_RETRY_JITTER_RANGE).and_return(1.0)
  end

  it 'sends each stage with its own schema, temperature, key and the router timeout' do
    answers('gemini-3.7-flash' => ['generate body'], 'gemini-3.8-flash' => ['critique body'])

    expect(reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')).to eq('generate body')
    expect(reviewer.critique(system_prompt: 'cs', user_prompt: 'cu')).to eq('critique body')

    expect(requests).to eq([
      {stage: 'generate', model: 'gemini-3.7-flash', key: 'key-one', key_index: 0, timeout: 60.0,
       temperature: 0.3, schema: Aireview::GenerateOutputSchema, system: 'gs', user: 'gu'},
      {stage: 'critique', model: 'gemini-3.8-flash', key: 'key-one', key_index: 0, timeout: 60.0,
       temperature: 0, schema: Aireview::CritiqueOutputSchema, system: 'cs', user: 'cu'}
    ])
    expect(reviewer.fallback_models).to eq({})
    expect(reviewer.answered_model('generate')).to eq('gemini/gemini-3.7-flash (1/1)')
    expect(reviewer.critique_weaker?).to be(false)
  end

  context 'with a fallback model' do
    let(:generate_fallbacks) { [candidate('gemini-fallback')] }

    it 'switches to the fallback after the primary is overloaded twice and reports it' do
      answers('gemini-3.7-flash' => [overloaded_error, overloaded_error], 'gemini-fallback' => ['fallback body'])

      expect(reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')).to eq('fallback body')
      expect(requests.map { |request| request[:model] }).to eq(%w[gemini-3.7-flash gemini-3.7-flash gemini-fallback])
      expect(sleeps).to eq([30.0])
      expect(reviewer.fallback_models).to eq('generate' => 'gemini/gemini-fallback')
      expect(reviewer.answered_model('generate')).to eq('gemini/gemini-fallback (2/2)')
      expect(log_output.string).to include(
        'LLM generate: switching to gemini/gemini-fallback after gemini/gemini-3.7-flash: overloaded after 2 attempt(s)'
      )
    end

    it 'excludes the answering model for the stage on request and moves on with the same prompt' do
      answers('gemini-3.7-flash' => ['bad json'], 'gemini-fallback' => ['good json'])
      reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')

      expect(reviewer.exclude_answered_model(stage: 'generate', reason: 'invalid result'))
        .to eq(candidate('gemini-3.7-flash'))
      expect(reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')).to eq('good json')
    end
  end

  context 'with two keys' do
    let(:gemini_keys) { %w[key-one key-two] }

    it 'switches the key on a real daily quota response body without waiting' do
      answers('gemini-3.7-flash' => [daily_quota_error, 'generate body'])

      expect(reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')).to eq('generate body')
      expect(requests.map { |request| request.values_at(:key, :key_index) }).to eq([['key-one', 0], ['key-two', 1]])
      expect(sleeps).to be_empty
      expect(log_output.string).not_to include('key-one', 'key-two')
    end
  end

  it 'reports a repair that the answering model can no longer take as an invalid result, not an API error' do
    answers('gemini-3.7-flash' => ['first', 'second', 'third'])
    reviewer.generate(system_prompt: 'gs', user_prompt: 'gu')
    reviewer.generate(system_prompt: 'gs', user_prompt: 'repair', pinned: true)
    reviewer.generate(system_prompt: 'gs', user_prompt: 'repair', pinned: true)

    expect { reviewer.generate(system_prompt: 'gs', user_prompt: 'repair', pinned: true) }
      .to raise_error(Aireview::RepairImpossibleError, /attempt limit of 3 reached/)
    expect(Aireview::RepairImpossibleError.ancestors).to include(Aireview::ParseError)
  end

  it 'lets a fatal API error through as ApiError' do
    answers('gemini-3.7-flash' => [RubyLLM::UnauthorizedError.new('bad key')])

    expect { reviewer.generate(system_prompt: 'gs', user_prompt: 'gu') }
      .to raise_error(Aireview::ApiError, 'LLM API request failed: bad key')
  end
end
