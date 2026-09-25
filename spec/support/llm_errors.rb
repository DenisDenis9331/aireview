require 'json'

# Provider errors with the real RubyLLM classes and Google response bodies —
# the classifier, the router and the client are checked with them.
RSpec.shared_context 'LLM errors' do
  def overloaded_error(message = 'This model is currently experiencing high demand')
    RubyLLM::ServiceUnavailableError.new(message)
  end

  def rate_limited_error(message = 'Quota exceeded. Please retry in 5s.')
    RubyLLM::RateLimitError.new(message)
  end

  # Google's answer to an exhausted quota: the kind is in QuotaFailure.violations[].quotaId.
  def quota_error(quota_id, message: 'You exceeded your current quota. Please retry in 55s.',
                  error_class: RubyLLM::RateLimitError)
    body = {
      'error' => {
        'code' => 429,
        'status' => 'RESOURCE_EXHAUSTED',
        'message' => message,
        'details' => [
          {'@type' => 'type.googleapis.com/google.rpc.QuotaFailure',
           'violations' => [{'quotaMetric' => 'generativelanguage.googleapis.com/generate_content_free_tier_requests',
                             'quotaId' => quota_id}]}
        ]
      }
    }
    error_class.new(message, response: Struct.new(:body).new(JSON.generate(body)))
  end

  def daily_quota_error
    quota_error('GenerateRequestsPerDayPerProjectPerModel-FreeTier')
  end

  def missing_model_error(model = 'gemini-x')
    RubyLLM::Error.new("models/#{model} is not found for API version v1beta, or is not supported for generateContent. " \
                       'Call ListModels to see the list of available models and their supported methods.')
  end
end
