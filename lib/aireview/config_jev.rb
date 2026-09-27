# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'

module Aireview
  # Jev (TypeSafe) settings, llm.jev. For now Jev only runs in shadow mode
  # next to the LLM Critique: its decisions go to the log, the review result
  # and the review key do not depend on it.
  module ConfigJev
    # A pinned version, not an alias: thresholds are tuned against one
    # version, and an alias moves when a release ships.
    DEFAULT_JEV_MODEL = 'jev-1.13.0'
    JEV_ALIASES = %w[jev-latest jev-preview].freeze
    DEFAULT_JEV_TIMEOUT = 10
    # Provisional values for the shadow log. The log carries the raw
    # probabilities, so the experiment can pick real thresholds afterwards.
    JEV_THRESHOLD_DEFAULTS = {
      'keep_above' => 0.5,
      'enough_context' => 0.5,
      'version_claim' => 0.5,
      'duplicate' => 0.5
    }.freeze

    def jev_shadow?
      value = dig('llm', 'jev', 'shadow')
      return false if value.nil?
      return value if [true, false].include?(value)

      raise ConfigError, "llm.jev.shadow must be true or false, got #{value.inspect}"
    end

    def jev_model
      Aireview::Utils.presence(dig('llm', 'jev', 'model')) || DEFAULT_JEV_MODEL
    end

    def jev_api_key
      @data['jev_api_key']
    end

    def jev_timeout
      positive_integer!(dig('llm', 'jev', 'timeout') || DEFAULT_JEV_TIMEOUT, 'llm.jev.timeout')
    end

    def jev_thresholds
      JEV_THRESHOLD_DEFAULTS.to_h do |name, default|
        value = dig('llm', 'jev', name)
        [name.to_sym, value.nil? ? default : probability!(value, "llm.jev.#{name}")]
      end
    end

    def jev_warnings
      return [] unless jev_shadow?

      warnings = []
      if Aireview::Utils.blank?(jev_api_key)
        warnings << 'llm.jev.shadow is on, but JEV_API_KEY is not set: Jev is skipped'
      end
      if JEV_ALIASES.include?(jev_model)
        warnings << "llm.jev.model #{jev_model.inspect} is an alias: its answers change when TypeSafe ships " \
                    'a release; pin a version such as jev-1.13.0'
      end
      warnings
    end

    private

    def probability!(value, name)
      number = Float(value, exception: false) if value.is_a?(Numeric) || value.is_a?(String)
      return number if number&.between?(0, 1)

      raise ConfigError, "#{name} must be a number from 0 to 1, got #{value.inspect}"
    end
  end
end
