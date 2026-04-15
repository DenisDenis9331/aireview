require 'logger'
require 'pathname'
require 'yaml'
require_relative 'errors'
require_relative 'utils'

module Aireview
  class Config
    DEFAULT_SECRET_FILES = [
      '.env',
      '.env.*',
      'config/secrets.yml',
      'config/credentials/*.key',
      'spec/fixtures/cassettes/*.yml',
      'spec/fixtures/cassettes/**/*.yml',
      'spec/cassettes/*.yml',
      'spec/cassettes/**/*.yml',
      'test/fixtures/cassettes/*.yml',
      'test/fixtures/cassettes/**/*.yml'
    ].freeze

    DEFAULTS = {
      'review_language' => 'ru',
      'ignore_paths' => [],
      'secret_patterns' => [],
      'secret_files' => DEFAULT_SECRET_FILES,
      'review_instructions' => nil,
      'llm_api_base' => nil,
      'llm_http_proxy' => nil,
      'llm' => {
        'provider' => 'gemini',
        'temperature' => 0,
        'timeout' => 60
      }
    }.freeze

    ENV_MAPPING = {
      'gitlab_url' => 'GITLAB_URL',
      'gitlab_token' => 'GITLAB_TOKEN',
      'jira_url' => 'JIRA_URL',
      'jira_email' => 'JIRA_EMAIL',
      'jira_token' => 'JIRA_TOKEN',
      'review_language' => 'REVIEW_LANGUAGE',
      'llm_api_base' => 'LLM_API_BASE',
      'llm_http_proxy' => 'LLM_HTTP_PROXY'
    }.freeze

    PROVIDER_KEY_MAPPING = {
      'gemini' => 'GEMINI_API_KEY',
      'openai' => 'OPENAI_API_KEY',
      'openrouter' => 'OPENROUTER_API_KEY',
      'anthropic' => 'ANTHROPIC_API_KEY',
      'ollama' => nil
    }.freeze

    attr_reader :config_path

    def self.load(config_path: nil, cwd: Dir.pwd, env: ENV, logger: Logger.new($stderr))
      load_dotenv(cwd)

      file_path = config_path ? File.expand_path(config_path, cwd) : discover_file(cwd, '.aireview.yml')
      file_config = File.file?(file_path) ? normalize_hash(YAML.load_file(file_path) || {}) : {}

      merged = deep_merge(DEFAULTS, file_config)
      merged = deep_merge(merged, env_config(env))

      new(merged, config_path: File.file?(file_path) ? file_path : nil, logger: logger)
    end

    def self.load_dotenv(cwd)
      require 'dotenv'
      dotenv_path = discover_file(cwd, '.env')
      Dotenv.load(dotenv_path) if File.file?(dotenv_path)
    rescue LoadError
      nil
    end

    def self.discover_file(cwd, basename)
      current = Pathname.new(cwd).expand_path

      loop do
        candidate = current.join(basename)
        return candidate.to_s if candidate.file?

        break if current.root?

        current = current.parent
      end

      File.join(cwd, basename)
    end

    def self.env_config(env)
      config = {}

      ENV_MAPPING.each do |key, env_key|
        value = env[env_key]
        config[key] = value unless Aireview::Utils.blank?(value)
      end

      llm_config = {
        'provider' => env['LLM_PROVIDER'],
        'temperature' => parse_float(env['LLM_TEMPERATURE']),
        'timeout' => parse_float(env['LLM_TIMEOUT']),
        'generate' => {
          'model' => env['LLM_GENERATE_MODEL'],
          'temperature' => parse_float(env['LLM_GENERATE_TEMPERATURE'])
        }.reject { |_, value| value.nil? },
        'critique' => {
          'model' => env['LLM_CRITIQUE_MODEL'],
          'temperature' => parse_float(env['LLM_CRITIQUE_TEMPERATURE'])
        }.reject { |_, value| value.nil? }
      }.reject { |_, value| value.nil? }
      llm_config.delete('generate') if llm_config['generate'].empty?
      llm_config.delete('critique') if llm_config['critique'].empty?
      config['llm'] = llm_config

      PROVIDER_KEY_MAPPING.each do |provider, env_key|
        next unless env_key

        value = env[env_key]
        config["#{provider}_api_key"] = value unless Aireview::Utils.blank?(value)
      end

      api_key = env['LLM_API_KEY']
      config['llm_api_key'] = api_key unless Aireview::Utils.blank?(api_key)

      config
    end

    def self.parse_float(value)
      return nil if Aireview::Utils.blank?(value)

      Float(value)
    rescue ArgumentError
      nil
    end

    def self.deep_merge(left, right)
      left.merge(right) do |_, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def self.normalize_hash(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner_value), result|
          result[key.to_s] = normalize_hash(inner_value)
        end
      when Array
        value.map { |item| normalize_hash(item) }
      else
        value
      end
    end

    def initialize(data, config_path:, logger:)
      @data = self.class.normalize_hash(data)
      @config_path = config_path
      @logger = logger
    end

    def with_overrides(
      generate_model: nil,
      critique_model: nil,
      generate_temperature: nil,
      critique_temperature: nil
    )
      return self if generate_model.nil? && critique_model.nil? &&
                     generate_temperature.nil? && critique_temperature.nil?

      llm_config = {}

      llm_config['generate'] = (llm_config['generate'] || {}).merge('model' => generate_model) if generate_model
      llm_config['critique'] = (llm_config['critique'] || {}).merge('model' => critique_model) if critique_model
      llm_config['generate'] = (llm_config['generate'] || {}).merge('temperature' => generate_temperature) unless generate_temperature.nil?
      llm_config['critique'] = (llm_config['critique'] || {}).merge('temperature' => critique_temperature) unless critique_temperature.nil?

      merged = self.class.deep_merge(
        @data,
        'llm' => llm_config
      )
      self.class.new(merged, config_path: config_path, logger: @logger)
    end

    def gitlab_url
      @data['gitlab_url']
    end

    def gitlab_token
      @data['gitlab_token']
    end

    def jira_url
      @data['jira_url']
    end

    def jira_email
      @data['jira_email']
    end

    def jira_token
      @data['jira_token']
    end

    def llm_provider
      dig('llm', 'provider') || DEFAULTS.dig('llm', 'provider')
    end

    def llm_temperature
      dig('llm', 'temperature') || DEFAULTS.dig('llm', 'temperature')
    end

    def llm_timeout
      dig('llm', 'timeout') || DEFAULTS.dig('llm', 'timeout')
    end

    def generate_model
      dig('llm', 'generate', 'model')
    end

    def critique_model
      dig('llm', 'critique', 'model')
    end

    def generate_temperature
      dig('llm', 'generate', 'temperature') || llm_temperature
    end

    def critique_temperature
      dig('llm', 'critique', 'temperature') || llm_temperature
    end

    def llm_api_base
      @data['llm_api_base']
    end

    def llm_http_proxy
      @data['llm_http_proxy'] || dig('llm', 'http_proxy')
    end

    def review_language
      @data['review_language'] || DEFAULTS['review_language']
    end

    def ignore_paths
      Array(@data['ignore_paths']).compact
    end

    def secret_patterns
      Array(@data['secret_patterns']).compact
    end

    def secret_files
      (DEFAULT_SECRET_FILES + Array(@data['secret_files']).compact).uniq
    end

    def review_instructions
      @data['review_instructions']
    end

    def llm_api_key
      @data['llm_api_key']
    end

    def provider_api_key(provider = llm_provider)
      @data["#{provider}_api_key"] || llm_api_key
    end

    def jira_configured?
      Aireview::Utils.present?(jira_url) &&
        Aireview::Utils.present?(jira_email) &&
        Aireview::Utils.present?(jira_token)
    end

    def require_gitlab_token!
      return gitlab_token if Aireview::Utils.present?(gitlab_token)

      raise ConfigError, 'GITLAB_TOKEN is required'
    end

    def require_models!
      missing = []
      missing << 'llm.generate.model (or LLM_GENERATE_MODEL)' if Aireview::Utils.blank?(generate_model)
      missing << 'llm.critique.model (or LLM_CRITIQUE_MODEL)' if Aireview::Utils.blank?(critique_model)
      raise ConfigError, "LLM models are required: #{missing.join(', ')}" unless missing.empty?
    end

    def require_llm_configuration!
      require_models!

      return if llm_provider == 'ollama'
      return provider_api_key if Aireview::Utils.present?(provider_api_key)

      raise ConfigError, "API key is required for provider #{llm_provider.inspect}"
    end

    private

    def dig(*keys)
      keys.reduce(@data) do |accumulator, key|
        accumulator.is_a?(Hash) ? accumulator[key] : nil
      end
    end
  end
end
