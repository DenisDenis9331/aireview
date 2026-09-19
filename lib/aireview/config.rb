# frozen_string_literal: true
require 'logger'
require 'pathname'
require 'yaml'
require_relative 'errors'
require_relative 'utils'
require_relative 'config_limits'
require_relative 'config_fallbacks'
require_relative 'config_layers'
require_relative 'config_loader'

module Aireview
  # Ответы на вопросы по слитым настройкам: значения, их источник (слой),
  # план маршрутизации, ключи провайдеров. Как настройки читаются из файлов
  # и env — дело ConfigLoader.
  class Config
    include ConfigLimits
    include ConfigFallbacks
    include ConfigLayers

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

    REVIEW_MODES = %w[update once].freeze
    DEFAULTS = {
      'review_language' => 'en',
      'review_mode' => 'update',
      'ignore_paths' => [],
      'secret_patterns' => [],
      'secret_files' => DEFAULT_SECRET_FILES,
      'review_instructions' => nil,
      'llm_api_base' => nil,
      'ollama_api_base' => 'http://localhost:11434/v1',
      'llm_http_proxy' => nil,
      'llm' => {
        'provider' => 'gemini',
        'temperature' => 0,
        'timeout' => 60,
        'max_prompt_chars' => ConfigLimits::DEFAULT_MAX_PROMPT_CHARS,
        'time_budget' => ConfigFallbacks::DEFAULT_TIME_BUDGET,
        'overloaded_quarantine' => ConfigFallbacks::DEFAULT_OVERLOADED_QUARANTINE
      },
      'context' => ConfigLimits::CONTEXT_DEFAULTS
    }.freeze

    attr_reader :config_path, :layers

    def self.load(**options)
      ConfigLoader.load(**options)
    end

    def self.env_names
      ConfigLoader.env_names
    end

    # Единственный источник правды — слои: слитые данные считаются из них.
    # Конфиг из готового хеша (без ConfigLoader) — один слой, иначе CLI-слой
    # из with_overrides остался бы единственным, и стадийные настройки
    # исходного хеша пропали бы.
    def initialize(data = nil, config_path: nil, logger: Logger.new($stderr), layers: nil)
      @layers = layers || [ConfigLayers::Layer.new(name: ConfigLayers::DATA_LAYER, data: Utils.normalize_hash(data))]
      @data = @layers.map(&:data).reduce({}) { |merged, layer_data| Utils.deep_merge(merged, layer_data) }
      @config_path = config_path
      @logger = logger
    end

    # Переопределения из CLI меняют только основную модель стадии, запасные
    # из конфига остаются; no_fallbacks оставляет одну модель и один ключ.
    def with_overrides(
      generate_model: nil,
      critique_model: nil,
      generate_temperature: nil,
      critique_temperature: nil,
      no_fallbacks: false
    )
      llm_config = {
        'generate' => stage_overrides(model: generate_model, temperature: generate_temperature),
        'critique' => stage_overrides(model: critique_model, temperature: critique_temperature)
      }.reject { |_, overrides| overrides.empty? }
      overrides = {}
      overrides['llm'] = llm_config unless llm_config.empty?
      overrides['fallbacks_disabled'] = true if no_fallbacks
      return self if overrides.empty?

      self.class.new(
        config_path: config_path,
        logger: @logger,
        layers: @layers + [ConfigLayers::Layer.new(name: ConfigLayers::CLI_LAYER, data: overrides)]
      )
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

    def jira_login
      @data['jira_login']
    end

    def jira_password
      @data['jira_password']
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

    # Основная модель стадии — первая в её цепочке: стартовая для generate,
    # первая пула для critique. Именно они идут в ключ ревью.
    def generate_model
      routing.primary('generate').model
    end

    def critique_model
      routing.primary('critique').model
    end

    def generate_provider
      routing.primary('generate').provider
    end

    # Всё, что кроме промпта влияет на результат ревью, — в ключ заметки
    # (см. ReviewMarker): провайдер, модель и температура стадий, общий пул
    # с политикой критики. Резервы стадийных цепочек результат не меняют.
    def result_signature
      {
        'generate' => [generate_provider, generate_model, generate_temperature],
        'critique' => [critique_provider, critique_model, critique_temperature],
        'pool' => routing.signature
      }
    end

    def critique_provider
      routing.primary('critique').provider
    end

    def generate_temperature
      stage_setting('generate', 'temperature') || DEFAULTS.dig('llm', 'temperature')
    end

    def critique_temperature
      stage_setting('critique', 'temperature') || DEFAULTS.dig('llm', 'temperature')
    end

    def llm_api_base
      @data['llm_api_base']
    end

    def ollama_api_base
      @data['ollama_api_base'] || DEFAULTS['ollama_api_base']
    end

    def llm_http_proxy
      @data['llm_http_proxy'] || dig('llm', 'http_proxy')
    end

    def review_language
      @data['review_language'] || DEFAULTS['review_language']
    end

    # update — обновляем свою заметку, когда дифф или настройки изменились,
    # once — ревьюим один раз автоматически; Retry джоба обновляет ревью при изменениях.
    def review_mode
      mode = (@data['review_mode'] || DEFAULTS['review_mode']).to_s
      return mode if REVIEW_MODES.include?(mode)

      @logger.warn("Unknown review_mode #{mode.inspect}, using #{DEFAULTS['review_mode']}")
      DEFAULTS['review_mode']
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
        Aireview::Utils.present?(jira_login) &&
        Aireview::Utils.present?(jira_password)
    end

    def require_gitlab_token!
      return gitlab_token if Aireview::Utils.present?(gitlab_token)

      raise ConfigError, 'GITLAB_TOKEN is required'
    end

    private

    # Без пула переопределение меняет только основную модель стадии, запасные
    # остаются. С пулом режим стадии переключается явно: модель из пула
    # становится стартовой, а своя model и fallbacks стадии сбрасываются;
    # модель не из пула — одиночная цепочка, start и fallbacks сбрасываются.
    def stage_overrides(model:, temperature:)
      overrides = {'temperature' => temperature}.compact
      return overrides unless model

      items = Array(dig('llm', 'models'))
      return overrides.merge('model' => model) if items.empty?

      if ModelPool.member?(items, llm_provider, model)
        overrides.merge('start' => model, 'model' => nil, 'fallbacks' => nil)
      else
        overrides.merge('start' => nil, 'model' => model, 'fallbacks' => [])
      end
    end

    def dig(*keys)
      Utils.dig(@data, *keys)
    end
  end
end
