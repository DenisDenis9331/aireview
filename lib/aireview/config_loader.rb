# frozen_string_literal: true
require_relative 'stages'
require 'logger'
require 'pathname'
require 'yaml'
require_relative 'errors'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'config_layers'
require_relative 'config_limits'
require_relative 'config'

module Aireview
  # Builds a Config from layers: built-in values, image defaults
  # (AIREVIEW_DEFAULTS, or the bundled config/defaults.yml when no upper layer
  # names a model), the project's .aireview.yml (searched upwards from cwd),
  # env. Everything that knows environment variable names and file formats
  # lives here; Config only answers questions about merged data.
  module ConfigLoader
    ENV_MAPPING = {
      'gitlab_url' => 'GITLAB_URL',
      'gitlab_token' => 'GITLAB_TOKEN',
      'jira_url' => 'JIRA_URL',
      'jira_login' => 'JIRA_LOGIN',
      'jira_password' => 'JIRA_PASSWORD',
      'review_language' => 'REVIEW_LANGUAGE',
      'review_mode' => 'REVIEW_MODE',
      'llm_api_base' => 'LLM_API_BASE',
      'ollama_api_base' => 'OLLAMA_API_BASE',
      'llm_http_proxy' => 'LLM_HTTP_PROXY',
      'jev_api_key' => 'JEV_API_KEY'
    }.freeze
    PROVIDER_KEY_MAPPING = {
      'gemini' => 'GEMINI_API_KEY',
      'openai' => 'OPENAI_API_KEY',
      'anthropic' => 'ANTHROPIC_API_KEY',
      'openrouter' => 'OPENROUTER_API_KEY'
    }.freeze
    PROVIDER_KEYS_MAPPING = {
      'gemini' => 'GEMINI_API_KEYS',
      'openai' => 'OPENAI_API_KEYS',
      'anthropic' => 'ANTHROPIC_API_KEYS',
      'openrouter' => 'OPENROUTER_API_KEYS'
    }.freeze
    CONTEXT_ENV = {
      'max_diff_chars' => 'MAX_DIFF_CHARS',
      'max_mr_description_chars' => 'MAX_MR_DESCRIPTION_CHARS',
      'max_jira_description_chars' => 'MAX_JIRA_DESCRIPTION_CHARS',
      'max_jira_comment_chars' => 'MAX_JIRA_COMMENT_CHARS'
    }.freeze
    LLM_ENV = %w[
      LLM_PROVIDER LLM_TEMPERATURE LLM_TIMEOUT LLM_MAX_PROMPT_CHARS LLM_TIME_BUDGET LLM_OVERLOADED_QUARANTINE
      LLM_MODELS LLM_CRITIQUE_RANK LLM_CRITIQUE_ALLOW_WEAKER LLM_CRITIQUE_ENGINE
      LLM_JEV_SHADOW LLM_JEV_MODEL LLM_JEV_FALLBACK LLM_JEV_KEEP_ABOVE
    ].freeze
    LLM_STAGE_ENV_SUFFIXES = %w[PROVIDER MODEL TEMPERATURE MAX_PROMPT_CHARS FALLBACK_MODEL START].freeze
    IMAGE_DEFAULTS_ENV = 'AIREVIEW_DEFAULTS'
    BUNDLED_DEFAULTS = File.expand_path('../../config/defaults.yml', __dir__)

    module_function

    def load(config_path: nil, cwd: Dir.pwd, env: ENV, logger: Logger.new($stderr))
      load_dotenv(cwd)

      file_path = config_path ? File.expand_path(config_path, cwd) : discover_file(cwd, '.aireview.yml')
      upper = [file_layer(file_path), ConfigLayers::Layer.new(name: ConfigLayers::ENV_LAYER, data: env_config(env))]
      layers = [
        ConfigLayers::Layer.new(name: ConfigLayers::BUILT_IN_LAYER, data: Config::DEFAULTS),
        image_defaults_layer(env) || bundled_defaults_layer(upper.compact),
        *upper
      ].compact

      Config.new(config_path: File.file?(file_path) ? file_path : nil, logger: logger, layers: layers)
    end

    # Every environment variable the loader reads. The CI template passes
    # them into the container by name: a project variable missing from this
    # list never reaches the review.
    def env_names
      stage_env = STAGES.flat_map do |stage|
        LLM_STAGE_ENV_SUFFIXES.map { |suffix| "LLM_#{stage.upcase}_#{suffix}" }
      end
      [
        *ENV_MAPPING.values, *PROVIDER_KEY_MAPPING.values, *PROVIDER_KEYS_MAPPING.values, 'LLM_API_KEY',
        *LLM_ENV, *stage_env, *CONTEXT_ENV.values
      ].uniq
    end

    def load_dotenv(cwd)
      require 'dotenv'
      dotenv_path = discover_file(cwd, '.env')
      Dotenv.load(dotenv_path) if File.file?(dotenv_path)
    rescue LoadError
      nil
    end

    def discover_file(cwd, basename)
      current = Pathname.new(cwd).expand_path

      loop do
        candidate = current.join(basename)
        return candidate.to_s if candidate.file?

        break if current.root?

        current = current.parent
      end

      File.join(cwd, basename)
    end

    # Image defaults: the Dockerfile sets the path through AIREVIEW_DEFAULTS.
    # A path that is set but missing means a broken image; better to learn
    # that at once.
    def image_defaults_layer(env)
      path = env[IMAGE_DEFAULTS_ENV]
      return nil if Aireview::Utils.blank?(path)
      raise ConfigError, "#{IMAGE_DEFAULTS_ENV} points to a missing file: #{path}" unless File.file?(path)

      ConfigLayers::Layer.new(name: ConfigLayers::IMAGE_LAYER, path: path, data: read_yaml(path))
    end

    # Outside the image (gem install, a checkout) the same defaults.yml stands
    # in for the image layer, but only when no upper layer names a model (CLI
    # models are checked in Config#with_overrides): a setup with models of its
    # own keeps working exactly as before, and one without models would fail
    # with "LLM models are required" anyway.
    def bundled_defaults_layer(upper)
      return nil if upper.any? { |layer| models_configured?(layer.data) }
      return nil unless File.file?(BUNDLED_DEFAULTS)

      ConfigLayers::Layer.new(name: ConfigLayers::BUNDLED_LAYER, path: BUNDLED_DEFAULTS,
                              data: read_yaml(BUNDLED_DEFAULTS))
    end

    def models_configured?(data)
      Aireview::Utils.present?(Aireview::Utils.dig(data, 'llm', 'models')) ||
        STAGES.any? { |stage| Aireview::Utils.present?(Aireview::Utils.dig(data, 'llm', stage, 'model')) }
    end

    def file_layer(file_path)
      return nil unless File.file?(file_path)

      ConfigLayers::Layer.new(name: ConfigLayers::FILE_LAYER, path: file_path, data: read_yaml(file_path))
    end

    def read_yaml(path)
      Aireview::Utils.normalize_hash(YAML.load_file(path) || {})
    end

    def env_config(env)
      mapped_env_config(env)
        .merge('llm' => Aireview::Utils.deep_merge(llm_env_config(env), pool_env_config(env)))
        .merge(context_env_config(env))
        .merge(provider_key_env_config(env))
        .merge(provider_keys_env_config(env))
        .merge(generic_api_key_env_config(env))
    end

    def mapped_env_config(env)
      ENV_MAPPING.each_with_object({}) do |(key, env_key), config|
        value = env[env_key]
        config[key] = value unless Aireview::Utils.blank?(value)
      end
    end

    def llm_env_config(env)
      {
        'provider' => env['LLM_PROVIDER'],
        'temperature' => parse_float(env['LLM_TEMPERATURE']),
        'timeout' => parse_float(env['LLM_TIMEOUT']),
        'max_prompt_chars' => parse_integer(env['LLM_MAX_PROMPT_CHARS'], 'LLM_MAX_PROMPT_CHARS'),
        'time_budget' => parse_integer(env['LLM_TIME_BUDGET'], 'LLM_TIME_BUDGET'),
        'overloaded_quarantine' => parse_integer(env['LLM_OVERLOADED_QUARANTINE'], 'LLM_OVERLOADED_QUARANTINE'),
        'generate' => llm_stage_env_config(env, 'GENERATE'),
        'critique' => llm_stage_env_config(env, 'CRITIQUE'),
        'jev' => jev_env_config(env)
      }.compact.reject { |key, value| %w[generate critique jev].include?(key) && value.empty? }
    end

    # LLM_JEV_SHADOW=true|false, LLM_JEV_MODEL — a pinned Jev version,
    # LLM_JEV_FALLBACK=model|fail, LLM_JEV_KEEP_ABOVE — the keep threshold.
    def jev_env_config(env)
      {
        'shadow' => parse_boolean(env['LLM_JEV_SHADOW'], 'LLM_JEV_SHADOW'),
        'model' => Aireview::Utils.presence(env['LLM_JEV_MODEL']),
        'fallback' => Aireview::Utils.presence(env['LLM_JEV_FALLBACK']),
        # Validated by ConfigJev: a typo must fail, not fall back to the default.
        'keep_above' => Aireview::Utils.presence(env['LLM_JEV_KEEP_ABOVE'])
      }.compact
    end

    def llm_stage_env_config(env, stage)
      {
        'provider' => env["LLM_#{stage}_PROVIDER"],
        'model' => env["LLM_#{stage}_MODEL"],
        'temperature' => parse_float(env["LLM_#{stage}_TEMPERATURE"]),
        'max_prompt_chars' => parse_integer(env["LLM_#{stage}_MAX_PROMPT_CHARS"], "LLM_#{stage}_MAX_PROMPT_CHARS"),
        'fallbacks' => fallback_models_env_config(env, stage)
      }.compact
    end

    # LLM_GENERATE_FALLBACK_MODEL=gemini-3.8-flash (or a comma-separated
    # list) — the provider is separated by a slash because Ollama tags contain a colon.
    def fallback_models_env_config(env, stage)
      value = env["LLM_#{stage}_FALLBACK_MODEL"]
      return nil if Aireview::Utils.blank?(value)

      value.split(',').map(&:strip).reject(&:empty?).map { |item| ModelCandidate.parse_item(item) }
    end

    # LLM_MODELS=gemini/gemini-3.8-flash,gemini/gemini-3.7-flash;
    # LLM_GENERATE_START / LLM_CRITIQUE_START — a model from the pool;
    # LLM_CRITIQUE_RANK, LLM_CRITIQUE_ALLOW_WEAKER=true|false.
    def pool_env_config(env)
      models = env['LLM_MODELS'].to_s.split(',').map(&:strip).reject(&:empty?).map do |item|
        ModelCandidate.parse_item(item)
      end
      {
        'models' => models.empty? ? nil : models,
        'generate' => {'start' => env['LLM_GENERATE_START']}.compact,
        'critique' => {
          'start' => env['LLM_CRITIQUE_START'],
          'engine' => Aireview::Utils.presence(env['LLM_CRITIQUE_ENGINE']),
          'rank' => env['LLM_CRITIQUE_RANK'],
          'allow_weaker' => parse_boolean(env['LLM_CRITIQUE_ALLOW_WEAKER'], 'LLM_CRITIQUE_ALLOW_WEAKER')
        }.compact
      }.compact.reject { |_, value| value.is_a?(Hash) && value.empty? }
    end

    def context_env_config(env)
      context = CONTEXT_ENV.each_with_object({}) do |(key, env_key), config|
        value = parse_integer(env[env_key], env_key)
        config[key] = value unless value.nil?
      end
      context.empty? ? {} : {'context' => context}
    end

    def provider_key_env_config(env)
      PROVIDER_KEY_MAPPING.each_with_object({}) do |(provider, env_key), config|
        value = env[env_key]
        config["#{provider}_api_key"] = value unless Aireview::Utils.blank?(value)
      end
    end

    def provider_keys_env_config(env)
      PROVIDER_KEYS_MAPPING.each_with_object({}) do |(provider, env_key), config|
        keys = env[env_key].to_s.split(',').map(&:strip).reject(&:empty?)
        config["#{provider}_api_keys"] = keys unless keys.empty?
      end
    end

    def generic_api_key_env_config(env)
      api_key = env['LLM_API_KEY']
      return {} if Aireview::Utils.blank?(api_key)

      {'llm_api_key' => api_key}
    end

    def parse_float(value)
      return nil if Aireview::Utils.blank?(value)

      Float(value)
    rescue ArgumentError
      nil
    end

    # A limit that failed to parse must not silently fall back to the
    # default: the request would go to a model with a window it does not have.
    def parse_integer(value, name)
      return nil if Aireview::Utils.blank?(value)

      Integer(value.to_s, 10)
    rescue ArgumentError
      raise ConfigError, "#{name} must be an integer, got #{value.inspect}"
    end

    def parse_boolean(value, name)
      return nil if Aireview::Utils.blank?(value)
      return true if %w[true 1 yes].include?(value.to_s.downcase)
      return false if %w[false 0 no].include?(value.to_s.downcase)

      raise ConfigError, "#{name} must be true or false, got #{value.inspect}"
    end
  end
end
