# frozen_string_literal: true
require 'set'

module Aireview
  # What the router learned about a model during the run. Three things with
  # different lifetimes: sent requests are counted per stage, a quarantine
  # lasts until a moment in time, an exclusion lasts until the end of the
  # run (the provider has no such model, every key is out of quota) or the
  # end of the stage (an invalid result). Keys with an exhausted daily quota
  # are remembered separately: a quota is a property of "key + model", a
  # quarantine a property of the model.
  class ModelState
    # Every request sent, the short retry and the JSON repair included,
    # spends an attempt regardless of its outcome; the keys of a model share
    # one counter, a quarantine does not reset it.
    MAX_REQUESTS_PER_STAGE = 3

    attr_reader :excluded_reason

    def initialize(limit: MAX_REQUESTS_PER_STAGE)
      @limit = limit
      @sent = Hash.new(0)
      @quarantined_until = nil
      @excluded_reason = nil
      @stage_exclusions = {}
      @exhausted_keys = Set.new
    end

    def sent(stage)
      @sent[stage.to_s]
    end

    def record_request(stage)
      @sent[stage.to_s] += 1
    end

    def requests_left?(stage)
      sent(stage) < @limit
    end

    def quarantine(until_time)
      @quarantined_until = until_time
    end

    # A model that answered is not overloaded, whichever key answered.
    def lift_quarantine
      @quarantined_until = nil
    end

    def quarantine_left(now)
      return 0 unless @quarantined_until

      [@quarantined_until - now, 0].max
    end

    def exclude(reason)
      @excluded_reason = reason
    end

    def exclude_for_stage(stage, reason)
      @stage_exclusions[stage.to_s] = reason
    end

    def exhaust_key(key_index)
      @exhausted_keys << key_index
    end

    def key_exhausted?(key_index)
      @exhausted_keys.include?(key_index)
    end

    # Why the model cannot be tried in the stage; nil — it can (the
    # quarantine is checked separately: it is a wait, not a ban).
    def skip_reason(stage)
      return @excluded_reason if @excluded_reason
      return "excluded for this stage: #{@stage_exclusions[stage.to_s]}" if @stage_exclusions.key?(stage.to_s)
      return "attempt limit of #{@limit} reached" unless requests_left?(stage)

      nil
    end
  end
end
