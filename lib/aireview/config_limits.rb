# frozen_string_literal: true

module Aireview
  # Лимиты контекста в символах: точного токенизатора для провайдеров локально
  # нет, а окно Ollama задаётся на сервере и клиенту не видно. Дефолты щедрые,
  # под конкретную модель их задают в .aireview.yml.
  module ConfigLimits
    LLM_STAGES = %w[generate critique].freeze
    DEFAULT_MAX_PROMPT_CHARS = 400_000
    CONTEXT_DEFAULTS = {
      'max_diff_chars' => 120_000,
      'max_mr_description_chars' => 8_000,
      'max_jira_description_chars' => 8_000,
      'max_jira_comment_chars' => 2_000
    }.freeze
    CONTEXT_ENV = {
      'max_diff_chars' => 'MAX_DIFF_CHARS',
      'max_mr_description_chars' => 'MAX_MR_DESCRIPTION_CHARS',
      'max_jira_description_chars' => 'MAX_JIRA_DESCRIPTION_CHARS',
      'max_jira_comment_chars' => 'MAX_JIRA_COMMENT_CHARS'
    }.freeze

    module ClassMethods
      def context_env_config(env)
        context = CONTEXT_ENV.each_with_object({}) do |(key, env_key), config|
          value = parse_integer(env[env_key])
          config[key] = value unless value.nil?
        end
        context.empty? ? {} : {'context' => context}
      end

      def parse_integer(value)
        return nil if Aireview::Utils.blank?(value)

        Integer(value.to_s, 10)
      rescue ArgumentError
        nil
      end
    end

    # Лимит всего запроса стадии в символах: системный промпт плюс контекст
    # (для критика ещё и кандидаты). Наследуется из llm как model/temperature.
    def max_prompt_chars(stage)
      stage = stage.to_s
      raise ArgumentError, "unknown LLM stage #{stage.inspect}" unless LLM_STAGES.include?(stage)

      positive_integer!(
        dig('llm', stage, 'max_prompt_chars') || dig('llm', 'max_prompt_chars') || DEFAULT_MAX_PROMPT_CHARS,
        "llm.#{stage}.max_prompt_chars"
      )
    end

    def max_diff_chars
      context_limit('max_diff_chars')
    end

    def max_mr_description_chars
      context_limit('max_mr_description_chars')
    end

    def max_jira_description_chars
      context_limit('max_jira_description_chars')
    end

    def max_jira_comment_chars
      context_limit('max_jira_comment_chars')
    end

    private

    def context_limit(key)
      positive_integer!(dig('context', key) || CONTEXT_DEFAULTS.fetch(key), "context.#{key}")
    end

    def positive_integer!(value, name)
      integer = Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
      integer = value.to_i if value.is_a?(Float) && value == value.floor
      return integer if integer.is_a?(Integer) && integer.positive?

      raise ConfigError, "#{name} must be a positive integer, got #{value.inspect}"
    end
  end
end
