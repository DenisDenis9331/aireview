# frozen_string_literal: true
require 'json'
require_relative 'utils'

module Aireview
  # Разбор и проверка формы ответа LLM: JSON (в том числе в code fences)
  # или уже структура по схеме → хеш со строковыми ключами и проверенными
  # id. Ошибка формы — SchemaError; чинить ли ответ повторным запросом,
  # решает пайплайн. Тем же разбором `aireview models check` судит, держит
  # ли модель схему.
  class ResultParser
    class SchemaError < StandardError
    end

    DECISIONS = %w[keep reject].freeze

    # expected — :generate или :critique; critique_candidate_ids — id
    # кандидатов, на каждый из которых критика обязана дать вердикт.
    def parse(raw, expected:, critique_candidate_ids: nil)
      parsed = Utils.normalize_hash(raw.is_a?(Hash) ? raw : JSON.parse(strip_code_fences(raw.to_s)))

      case expected.to_sym
      when :generate then generate_result(parsed)
      when :critique then critique_result(parsed, critique_candidate_ids)
      else raise ArgumentError, "Unknown expected JSON schema: #{expected.inspect}"
      end
    end

    private

    def strip_code_fences(text)
      stripped = text.strip
      return stripped unless stripped.start_with?('```')

      stripped
        .sub(/\A```[[:alnum:]_-]*[ \t]*\r?\n?/, '')
        .sub(/\r?\n?```[ \t]*\z/, '')
        .strip
    end

    def generate_result(parsed)
      parsed = {'summary' => nil, 'candidates' => parsed} if parsed.is_a?(Array)
      valid_shape = parsed.is_a?(Hash) && parsed['candidates'].is_a?(Array)
      raise SchemaError, 'expected an object with summary and candidates array' unless valid_shape
      raise SchemaError, 'each generate candidate must be an object' unless parsed['candidates'].all?(Hash)

      parsed['summary'] = nil unless parsed.key?('summary')
      identifiers!(parsed['candidates'].map { |candidate| Utils.presence(candidate['id']) },
                   missing: 'each generate candidate must include a non-empty id',
                   duplicates: 'duplicate generate candidate ids')
      parsed
    end

    def critique_result(parsed, expected_ids)
      valid_shape = parsed.is_a?(Hash) && parsed['verdicts'].is_a?(Array)
      raise SchemaError, 'expected an object with verdicts array' unless valid_shape
      raise SchemaError, 'each critique verdict must be an object' unless parsed['verdicts'].all?(Hash)

      verdict_ids = parsed['verdicts'].map { |verdict| Utils.presence(verdict['id']) }
      identifiers!(verdict_ids, missing: 'each verdict must include a non-empty id',
                                duplicates: 'duplicate verdict ids')
      expected_verdict_ids!(verdict_ids, expected_ids)
      parsed['verdicts'].each { |verdict| verdict!(verdict) }
      parsed
    end

    def identifiers!(identifiers, missing:, duplicates:)
      raise SchemaError, missing unless identifiers.all?

      duplicate_ids = identifiers.tally.select { |_, count| count > 1 }.keys
      raise SchemaError, "#{duplicates}: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
    end

    def expected_verdict_ids!(verdict_ids, expected_ids)
      return unless expected_ids

      unknown_ids = verdict_ids - expected_ids
      missing_ids = expected_ids - verdict_ids
      raise SchemaError, "unknown verdict ids: #{unknown_ids.join(', ')}" unless unknown_ids.empty?
      raise SchemaError, "missing verdict ids: #{missing_ids.join(', ')}" unless missing_ids.empty?
    end

    def verdict!(verdict)
      id = Utils.presence(verdict['id'])
      decision = verdict['decision'].to_s.strip.downcase
      raise SchemaError, "invalid verdict decision for #{id}" unless DECISIONS.include?(decision)
      if verdict.key?('refinement') && decision != 'keep'
        raise SchemaError,
              "reject verdict cannot include refinement for #{id}"
      end

      refinement = verdict['refinement']
      return if refinement.nil? || refinement.is_a?(Hash)

      raise SchemaError, "refinement must be an object for #{id}"
    end
  end
end
