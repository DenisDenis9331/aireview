# frozen_string_literal: true
module Aireview
  module Utils
    module_function

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def present?(value)
      !blank?(value)
    end

    def presence(value)
      present?(value) ? value.to_s.strip : nil
    end

    # Слияние настроек по ключам: вложенные хеши сливаются, всё остальное
    # (в том числе массивы) правая сторона заменяет целиком.
    def deep_merge(left, right)
      left.merge(right) do |_, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    # Ключи хешей — строки на любой глубине: YAML, env и ответы LLM приходят
    # по-разному, дальше все работают с одним видом.
    def normalize_hash(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, inner), result| result[key.to_s] = normalize_hash(inner) }
      when Array
        value.map { |item| normalize_hash(item) }
      else
        value
      end
    end

    def dig(data, *keys)
      keys.reduce(data) { |accumulator, key| accumulator.is_a?(Hash) ? accumulator[key] : nil }
    end
  end
end
