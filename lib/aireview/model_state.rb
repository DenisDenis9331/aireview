# frozen_string_literal: true
require 'set'

module Aireview
  # Что роутер узнал о модели за прогон. Три вещи с разным сроком жизни:
  # отправленные запросы считаются на стадию, карантин действует до
  # момента времени, исключение — до конца прогона (модели нет у
  # провайдера, все ключи по квоте) или до конца стадии (негодный
  # результат). Ключи с исчерпанной суточной квотой помнятся отдельно:
  # квота — свойство «ключ + модель», карантин — свойство модели.
  class ModelState
    # Каждый отправленный запрос, включая короткий повтор и починку JSON,
    # расходует попытку независимо от исхода; ключи модели делят один
    # счётчик, карантин его не обнуляет.
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

    # Ответившая модель не перегружена, какой бы ключ ни ответил.
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

    # Почему модель нельзя пробовать в стадии; nil — можно (карантин
    # проверяется отдельно: он не запрет, а ожидание).
    def skip_reason(stage)
      return @excluded_reason if @excluded_reason
      return "excluded for this stage: #{@stage_exclusions[stage.to_s]}" if @stage_exclusions.key?(stage.to_s)
      return "attempt limit of #{@limit} reached" unless requests_left?(stage)

      nil
    end
  end
end
