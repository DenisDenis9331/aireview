# frozen_string_literal: true
require_relative 'errors'
require_relative 'output_schemas'
require_relative 'llm_router'
require_relative 'llm_client'

module Aireview
  # Стадии ревью поверх роутера: generate и critique со своими схемами и
  # температурами. Сам запрос делает LlmClient, обход моделей — LlmRouter.
  class Reviewer
    attr_reader :router

    def initialize(config:, logger: Logger.new($stderr), router: nil, client: nil)
      @config = config
      @logger = logger
      @router = router || LlmRouter.new(config: config, logger: logger)
      @client = client || LlmClient.new(config: config, logger: logger)
    end

    # pinned — запрос только к модели, ответившей в стадии последней
    # (починка её же JSON): её отказ — RepairImpossibleError.
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

    # Стадии, ответившие запасной моделью, для строки в отчёте.
    def fallback_models
      @router.fallback_models
    end

    # Модель, ответившая в стадии последней, с местом в цепочке — для лога.
    def answered_model(stage)
      @router.answered(stage)
    end

    # Критика прошла на модели ниже generate по пулу (allow_weaker).
    def critique_weaker?
      @router.critique_weaker?
    end

    # Негодный результат: модель исключается для стадии, следующий запрос
    # стадии уйдёт другой. Возвращает исключённую модель или nil.
    def exclude_answered_model(stage:, reason:)
      @router.exclude_answered(stage: stage, reason: reason)
    end

    private

    # Отказ закреплённого маршрута — не ошибка API для пайплайна, а
    # «починка невозможна»: та же участь, что у негодного результата.
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
