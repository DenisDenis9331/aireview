# frozen_string_literal: true

module Aireview
  # Проверка формы ответов LLM после разбора JSON: кандидаты, вердикты, id.
  # Ошибка формы — SchemaError, пайплайн решает, чинить ли ответ повторным
  # запросом. Ожидает от включающего класса value, normalize_id и
  # normalize_decision.
  module ResultValidation
    class SchemaError < StandardError
    end

    private

    def validate_generate_result_shape!(parsed)
      valid_shape = parsed.is_a?(Hash) && parsed['candidates'].is_a?(Array)
      raise SchemaError, 'expected an object with summary and candidates array' unless valid_shape
      raise SchemaError, 'each generate candidate must be an object' unless parsed['candidates'].all?(Hash)
    end

    def validate_critique_result_shape!(parsed)
      valid_shape = parsed.is_a?(Hash) && parsed['verdicts'].is_a?(Array)
      raise SchemaError, 'expected an object with verdicts array' unless valid_shape
      raise SchemaError, 'each critique verdict must be an object' unless parsed['verdicts'].all?(Hash)
    end

    def validate_identifiers!(identifiers, missing_message:, duplicate_prefix:)
      raise SchemaError, missing_message unless identifiers.all?

      duplicate_ids = identifiers.group_by(&:itself).select { |_, ids| ids.size > 1 }.keys
      return if duplicate_ids.empty?

      raise SchemaError, "#{duplicate_prefix}: #{duplicate_ids.join(', ')}"
    end

    def validate_expected_verdict_ids!(verdict_ids, expected_ids)
      return unless expected_ids

      unknown_ids = verdict_ids - expected_ids
      missing_ids = expected_ids - verdict_ids
      raise SchemaError, "unknown verdict ids: #{unknown_ids.join(', ')}" unless unknown_ids.empty?
      raise SchemaError, "missing verdict ids: #{missing_ids.join(', ')}" unless missing_ids.empty?
    end

    def validate_verdict!(verdict)
      id = normalize_id(value(verdict, 'id'))
      decision = normalize_decision(value(verdict, 'decision'))
      raise SchemaError, "invalid verdict decision for #{id}" unless %w[keep reject].include?(decision)

      refinement = value(verdict, 'refinement')
      raise SchemaError, "reject verdict cannot include refinement for #{id}" if invalid_refinement?(verdict, decision)
      return if refinement.nil?
      return if refinement.is_a?(Hash)

      raise SchemaError, "refinement must be an object for #{id}"
    end

    def invalid_refinement?(verdict, decision)
      refinement_key?(verdict) && decision != 'keep'
    end

    def refinement_key?(verdict)
      verdict.key?('refinement') || verdict.key?(:refinement)
    end
  end
end
