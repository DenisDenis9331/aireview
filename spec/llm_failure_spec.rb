require 'aireview/llm_failure'

RSpec.describe Aireview::LlmFailure do
  include_context 'LLM errors'

  it 'recognises a missing or retired Gemini model by the provider text' do
    error = RubyLLM::Error.new(
      'models/gemini-1.0-pro is not found for API version v1beta, or is not supported for generateContent. ' \
      'Call ListModels to see the list of available models and their supported methods.'
    )
    expect(described_class.classify(error)).to eq(:unavailable)
    expect(described_class.classify(RubyLLM::BadRequestError.new('gemini-x is not supported for generateContent')))
      .to eq(:unavailable)
  end

  it 'recognises a model that Ollama has not pulled, in both wordings' do
    expect(described_class.classify(RubyLLM::Error.new("model 'nope:1b' not found"))).to eq(:unavailable)
    expect(described_class.classify(RubyLLM::Error.new('model "qwen2.5-coder:70b" not found, try pulling it first')))
      .to eq(:unavailable)
    expect(described_class.classify(RubyLLM::Error.new('file not found'))).to eq(:fatal)
  end

  it 'keeps a bare 404 and other API errors fatal' do
    expect(described_class.classify(RubyLLM::Error.new('404 Not Found'))).to eq(:fatal)
    expect(described_class.classify(RubyLLM::Error.new('<html>404 page not found</html>'))).to eq(:fatal)
    expect(described_class.classify(RubyLLM::BadRequestError.new('Invalid JSON payload'))).to eq(:fatal)
  end

  it 'classifies overloads, rate limits, daily quotas and timeouts as before' do
    expect(described_class.classify(RubyLLM::ServiceUnavailableError.new('high demand'))).to eq(:overloaded)
    expect(described_class.classify(RubyLLM::RateLimitError.new('retry in 5s'))).to eq(:rate_limit)
    expect(described_class.classify(RubyLLM::RateLimitError.new('20 requests per day'))).to eq(:daily_quota)
    expect(described_class.classify(Timeout::Error.new)).to eq(:timeout)
    expect(described_class.classify(RuntimeError.new('boom'))).to eq(:unhandled)
  end

  it 'reads the quota kind from a real Google response body' do
    expect(described_class.classify(daily_quota_error)).to eq(:daily_quota)
    expect(described_class.classify(quota_error('GenerateRequestsPerMinutePerProjectPerModel-FreeTier'))).to eq(:rate_limit)
    # RubyLLM turns a 429 mentioning input_token into ContextLengthExceededError:
    # it is an exhausted token quota, not an oversized request.
    token_quota = quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier',
                              message: 'Quota exceeded for metric: generate_content_free_tier_input_token_count',
                              error_class: RubyLLM::ContextLengthExceededError)
    expect(described_class.classify(token_quota)).to eq(:daily_quota)
    expect(described_class.classify(RubyLLM::ContextLengthExceededError.new('context is too long'))).to eq(:fatal)
    expect(described_class.retry_after_seconds(daily_quota_error.message)).to eq(55.0)
  end

  it 'treats a Faraday transport timeout like the outer Timeout' do
    expect(described_class.classify(Faraday::TimeoutError.new('execution expired'))).to eq(:timeout)
  end
end
