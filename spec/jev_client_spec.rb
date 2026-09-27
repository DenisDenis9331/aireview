# frozen_string_literal: true

require 'faraday'
require 'json'
require 'stringio'
require 'aireview/config'
require 'aireview/jev_client'

RSpec.describe Aireview::JevClient do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:log) { StringIO.new }
  let(:sleeps) { [] }
  let(:questions) do
    {
      'real_issue_C1' => {'type' => 'noul', 'instructions' => 'Real?'},
      'severity_C1' => {'type' => 'choice', 'instructions' => 'How bad?', 'criteria' => {'major' => nil}}
    }
  end
  let(:answers) do
    {
      'real_issue_C1' => {'type' => 'noul', 'noul' => 0.9},
      'severity_C1' => {'type' => 'choice', 'choice' => 'major', 'probabilities' => {'major' => 1.0},
                        'confidence' => 0.8}
    }
  end

  def config(model: 'jev-1.13.0', key: 'secret', proxy: nil)
    instance_double('Aireview::Config', jev_api_key: key, jev_model: model, jev_timeout: 7, llm_http_proxy: proxy)
  end

  def client(model: 'jev-1.13.0')
    connection = Faraday.new(url: described_class::API_URL) { |builder| builder.adapter :test, stubs }
    described_class.new(config: config(model: model), logger: Logger.new(log),
                        connection: connection, sleeper: ->(seconds) { sleeps << seconds })
  end

  def json(status, body, headers = {})
    [status, {'Content-Type' => 'application/json'}.merge(headers), JSON.generate(body)]
  end

  it 'posts the model, state and questions with the key and returns the answers' do
    captured = nil
    body = nil
    stubs.post('/v1/systemone') do |env|
      captured = env
      body = env.body
      json(200, 'model' => 'jev-1.13.0', 'answers' => answers, 'usage' => {'input_tokens' => 321})
    end

    result = client.evaluate(state: {'diff' => 'x'}, questions: questions)

    expect(captured.request_headers['Authorization']).to eq('Bearer secret')
    expect(JSON.parse(body)).to eq('model' => 'jev-1.13.0', 'state' => {'diff' => 'x'}, 'questions' => questions)
    expect(result.answers).to eq(answers)
    expect(result.model).to eq('jev-1.13.0')
    expect(log.string).to include('Jev request completed (model=jev-1.13.0, tokens: input=321)')
    expect(log.string).not_to include('secret')
  end

  it 'retries once on 429 and 529 after retry-after, capped' do
    calls = 0
    stubs.post('/v1/systemone') do
      calls += 1
      calls == 1 ? json(529, {'error' => 'overloaded'}, 'retry-after' => '60') : json(200, 'answers' => answers)
    end

    expect(client.evaluate(state: 'x', questions: questions).answers).to eq(answers)
    expect(calls).to eq(2)
    expect(sleeps).to eq([described_class::MAX_RETRY_DELAY])
  end

  it 'gives up after the one retry with the status in the error' do
    stubs.post('/v1/systemone') { json(429, 'error' => 'rate limited') }

    expect { client.evaluate(state: 'x', questions: questions) }
      .to raise_error(Aireview::JevError) { |error| expect(error.status).to eq(429) }
    expect(sleeps).to eq([described_class::RETRY_DELAY])
  end

  it 'does not retry other errors' do
    calls = 0
    stubs.post('/v1/systemone') do
      calls += 1
      json(422, 'detail' => 'state too long')
    end

    expect { client.evaluate(state: 'x', questions: questions) }.to raise_error(Aireview::JevError, /422.*too long/)
    expect(calls).to eq(1)
  end

  it 'turns network errors into JevError' do
    stubs.post('/v1/systemone') { raise Faraday::TimeoutError, 'timed out' }

    expect { client.evaluate(state: 'x', questions: questions) }.to raise_error(Aireview::JevError, /timed out/)
  end

  it 'rejects an answer that is missing or does not match its question type' do
    stubs.post('/v1/systemone') do
      json(200, 'answers' => answers.merge('real_issue_C1' => {'type' => 'noul', 'noul' => 1.7}))
    end

    expect { client.evaluate(state: 'x', questions: questions) }
      .to raise_error(Aireview::JevError, /invalid noul answer for real_issue_C1/)
  end

  it 'rejects invalid JSON' do
    stubs.post('/v1/systemone') { [200, {}, 'not json'] }

    expect { client.evaluate(state: 'x', questions: questions) }.to raise_error(Aireview::JevError, /invalid JSON/)
  end

  it 'warns when a pinned version answers as another one, but not for an alias' do
    stubs.post('/v1/systemone') { json(200, 'model' => 'jev-1.14.0', 'answers' => answers) }

    client.evaluate(state: 'x', questions: questions)
    client(model: 'jev-latest').evaluate(state: 'x', questions: questions)

    expect(log.string.scan('Jev answered as "jev-1.14.0", not the requested jev-1.13.0').size).to eq(1)
  end

  it 'goes through LLM_HTTP_PROXY when it is set' do
    with_proxy = described_class.new(config: config(proxy: 'http://127.0.0.1:8888'))
    direct = described_class.new(config: config(proxy: ''))

    expect(with_proxy.instance_variable_get(:@connection).proxy.uri.to_s).to eq('http://127.0.0.1:8888')
    expect(with_proxy.instance_variable_get(:@connection).options.timeout).to eq(7)
    expect(direct.instance_variable_get(:@connection).proxy).to be_nil
  end

  it 'requires a key' do
    expect { described_class.new(config: config(key: '')) }
      .to raise_error(Aireview::ConfigError, /JEV_API_KEY/)
  end
end
