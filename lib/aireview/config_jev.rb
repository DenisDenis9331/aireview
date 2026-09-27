# frozen_string_literal: true
require_relative 'errors'
require_relative 'stages'
require_relative 'utils'

module Aireview
  # The critique engine and the Jev (TypeSafe) settings. llm.critique.engine
  # picks who checks the candidates: an LLM (model, the default) or Jev, a
  # fast classifier that decides keep/reject but cannot refine a finding.
  # llm.jev.fallback says what happens when Jev cannot decide: the LLM
  # Critique takes over (model) or the run fails (fail). llm.jev.shadow runs
  # Jev next to the LLM Critique for the log only.
  module ConfigJev
    CRITIQUE_ENGINES = %w[model jev].freeze
    JEV_FALLBACKS = %w[model fail].freeze
    # A pinned version, not an alias: thresholds are tuned against one
    # version, and an alias moves when a release ships.
    DEFAULT_JEV_MODEL = 'jev-1.13.0'
    JEV_ALIASES = %w[jev-latest jev-preview].freeze
    DEFAULT_JEV_TIMEOUT = 10
    # Provisional values until real thresholds are chosen from the shadow
    # logs; the logs carry the raw probabilities for that.
    JEV_THRESHOLD_DEFAULTS = {
      'keep_above' => 0.5,
      'enough_context' => 0.5,
      'version_claim' => 0.5,
      'duplicate' => 0.5
    }.freeze

    def critique_engine
      one_of!(dig('llm', 'critique', 'engine') || 'model', CRITIQUE_ENGINES, 'llm.critique.engine')
    end

    def jev_fallback
      one_of!(dig('llm', 'jev', 'fallback') || 'model', JEV_FALLBACKS, 'llm.jev.fallback')
    end

    # Jev decides in this run: the engine is jev and the run has a critique
    # at all (--no-critique switches off every engine, as the critique:
    # argument or as a CLI override of the config).
    def jev_critique?(critique: true)
      critique && !critique_disabled? && critique_engine == 'jev'
    end

    # The stages that need an LLM in a run. Jev with fallback: model still
    # needs a ready LLM Critique; with fallback: fail it needs none.
    def llm_stages(critique: true)
      return ['generate'] unless critique && !critique_disabled?
      return ['generate'] if jev_critique? && jev_fallback == 'fail'

      STAGES
    end

    def critique_disabled?
      @data['critique_disabled'] == true
    end

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

    # Everything besides the questions that changes a Jev decision; nil when
    # Jev does not decide. The fallback is part of it: it decides what
    # happens to the candidates Jev could not judge.
    def jev_signature
      return nil unless critique_engine == 'jev'

      ['jev', jev_model, *jev_thresholds.values, jev_fallback]
    end

    # Jev as the critic needs a key and a pinned version: the thresholds are
    # tuned against one version, and falling back to the LLM silently would
    # hide a broken setup.
    def require_jev!(critique: true)
      return unless jev_critique?(critique: critique)
      raise ConfigError, 'llm.critique.engine is jev, but JEV_API_KEY is not set' if Aireview::Utils.blank?(jev_api_key)
      return unless JEV_ALIASES.include?(jev_model)

      raise ConfigError, "llm.jev.model #{jev_model.inspect} is an alias; with llm.critique.engine: jev " \
                         'pin a version such as jev-1.13.0'
    end

    def jev_warnings
      return [] unless jev_shadow?
      return ['llm.jev.shadow is ignored: Jev already decides as the critique engine'] if critique_engine == 'jev'

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

    def one_of!(value, allowed, name)
      value = value.to_s
      return value if allowed.include?(value)

      raise ConfigError, "#{name} must be one of #{allowed.join(', ')}, got #{value.inspect}"
    end

    def probability!(value, name)
      number = Float(value, exception: false) if value.is_a?(Numeric) || value.is_a?(String)
      return number if number&.between?(0, 1)

      raise ConfigError, "#{name} must be a number from 0 to 1, got #{value.inspect}"
    end
  end
end
