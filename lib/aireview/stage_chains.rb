# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'stages'

module Aireview
  # A routing plan of independent chains: every stage has its own primary
  # model and reserves in walking order. Critique does not depend on which
  # model answered in Generate.
  #
  # The plan interface (ModelPool implements it too): chain(stage),
  # critique_chain(after:), primary(stage), weaker?, signature, rule,
  # pool?, pool_stage?, pool_member?, start_used?, warnings.
  class StageChains
    # settings — per stage: provider, model, fallbacks (the raw list from the
    # config), max_prompt_chars. only_primary keeps one model.
    def self.build(settings, only_primary: false)
      chains = settings.to_h do |stage, stage_settings|
        [stage.to_s, stage_chain(stage.to_s, stage_settings, only_primary: only_primary)]
      end
      new(chains)
    end

    def self.stage_chain(stage, settings, only_primary:)
      primary = ModelCandidate.new(
        provider: settings.fetch(:provider).to_s,
        model: settings[:model],
        max_prompt_chars: settings.fetch(:max_prompt_chars)
      )
      return [primary] if only_primary

      [primary, *fallbacks(stage, Array(settings[:fallbacks]), primary)]
    end

    # A reserve without a provider inherits the stage provider, without a
    # limit its limit.
    def self.fallbacks(stage, items, primary)
      items.each_with_index.map do |item, index|
        item = ModelCandidate.parse_item(item)
        name = "llm.#{stage}.fallbacks[#{index}]"
        raise ConfigError, "#{name} must be a model name or a hash with model" unless item.is_a?(Hash)
        raise ConfigError, "#{name}.model is required" if Aireview::Utils.blank?(item['model'])

        limit = item['max_prompt_chars']
        ModelCandidate.new(
          provider: (item['provider'] || primary.provider).to_s,
          model: item['model'].to_s,
          max_prompt_chars: limit.nil? ? primary.max_prompt_chars : positive_limit(limit, name)
        )
      end
    end

    def self.positive_limit(value, name)
      integer = Integer(value, exception: false)
      return integer if integer&.positive?

      raise ConfigError, "#{name}.max_prompt_chars must be a positive integer, got #{value.inspect}"
    end

    def initialize(chains)
      @chains = chains
    end

    def chain(stage)
      @chains.fetch(stage.to_s) { raise ArgumentError, "unknown LLM stage #{stage.inspect}" }
    end

    def stage?(stage)
      @chains.key?(stage.to_s)
    end

    def critique_chain(after:)
      chain('critique')
    end

    def primary(stage)
      chain(stage).first
    end

    def weaker?(_critique_candidate, _generate_candidate)
      false
    end

    def signature
      nil
    end

    def rule
      nil
    end

    def pool?
      false
    end

    def pool_stage?(_stage)
      false
    end

    def pool_member?(_model)
      false
    end

    def start_used?(_stage)
      false
    end

    def warnings
      []
    end
  end
end
