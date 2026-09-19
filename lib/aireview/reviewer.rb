# frozen_string_literal: true
require_relative 'errors'
require_relative 'output_schemas'
require_relative 'llm_router'
require_relative 'llm_client'

module Aireview
  # The review stages on top of the router: Generate and Critique with their
  # own schemas and temperatures. LlmClient makes the request, LlmRouter
  # walks the models.
  class Reviewer
    attr_reader :router

    def initialize(config:, logger: Logger.new($stderr), router: nil, client: nil)
      @config = config
      @logger = logger
      @router = router || LlmRouter.new(config: config, logger: logger)
      @client = client || LlmClient.new(config: config, logger: logger)
    end

    # pinned — a request only to the model that answered last in the stage
    # (the repair of its own JSON): its failure is RepairImpossibleError.
    def generate(system_prompt:, user_prompt:, pinned: false)
      prompt = LlmClient::Prompt.new(stage: 'generate', system: system_prompt, user: user_prompt,
                                     temperature: @config.generate_temperature, schema: GenerateOutputSchema)
      call_llm(prompt, pinned: pinned)
    end

    def critique(system_prompt:, user_prompt:, pinned: false)
      prompt = LlmClient::Prompt.new(stage: 'critique', system: system_prompt, user: user_prompt,
                                     temperature: @config.critique_temperature, schema: CritiqueOutputSchema)
      call_llm(prompt, pinned: pinned)
    end

    # Stages answered by a fallback model, for the report line.
    def fallback_models
      @router.fallback_models
    end

    # The model that answered last in the stage with its place in the chain, for the log.
    def answered_model(stage)
      @router.answered(stage)
    end

    # Critique ran on a model below Generate in the pool (allow_weaker).
    def critique_weaker?
      @router.critique_weaker?
    end

    # An invalid result: the model is excluded for the stage, the next
    # request of the stage goes to another. Returns the excluded model or nil.
    def exclude_answered_model(stage:, reason:)
      @router.exclude_answered(stage: stage, reason: reason)
    end

    private

    # A pinned route giving up is not an API error for the pipeline but
    # "repair impossible": the same fate as an invalid result.
    def call_llm(prompt, pinned:)
      response = @router.call(stage: prompt.stage, request_chars: prompt.chars, pinned: pinned) do |route, timeout|
        @client.request(prompt, candidate: route.candidate, key: route.key, key_index: route.key_index,
                                timeout: timeout)
      end
      response.content
    rescue RouteExhaustedError => e
      raise RepairImpossibleError, e.message
    end
  end
end
