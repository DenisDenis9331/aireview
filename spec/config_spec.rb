require 'fileutils'
require 'tmpdir'
require 'aireview/config'

RSpec.describe Aireview::Config do
  describe '.load' do
    it 'merges env and file config while discovering parent config' do
      Dir.mktmpdir do |dir|
        root = File.join(dir, 'repo')
        child = File.join(root, 'aireview')
        FileUtils.mkdir_p(child)

        File.write(
          File.join(root, '.aireview.yml'),
          <<~YAML
            review_language: en
            ignore_paths:
              - vendor/**
            llm:
              temperature: 0.1
              generate:
                model: gemini-2.5-pro
                temperature: 0.3
              critique:
                model: gemini-2.5-flash
                temperature: 0
          YAML
        )

        config = described_class.load(
          cwd: child,
          env: {
            'GITLAB_TOKEN' => 'glpat-123',
            'LLM_PROVIDER' => 'gemini',
            'LLM_TIMEOUT' => '45',
            'LLM_HTTP_PROXY' => 'http://127.0.0.1:8888',
            'GEMINI_API_KEY' => 'secret'
          },
          logger: Logger.new(nil)
        )

        expect(config.review_language).to eq('en')
        expect(config.ignore_paths).to eq(['vendor/**'])
        expect(config.llm_provider).to eq('gemini')
        expect(config.generate_model).to eq('gemini-2.5-pro')
        expect(config.critique_model).to eq('gemini-2.5-flash')
        expect(config.generate_temperature).to eq(0.3)
        expect(config.critique_temperature).to eq(0)
        expect(config.llm_timeout).to eq(45)
        expect(config.llm_http_proxy).to eq('http://127.0.0.1:8888')
        expect(config.gitlab_token).to eq('glpat-123')
        expect(config.provider_api_key).to eq('secret')
        expect(config.config_path).to eq(File.join(root, '.aireview.yml'))
      end
    end

    it 'uses 60 seconds as the default LLM timeout' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {},
          logger: Logger.new(nil)
        )

        expect(config.llm_timeout).to eq(60)
      end
    end

    it 'includes cassette paths in default secret files' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {},
          logger: Logger.new(nil)
        )

        expect(config.secret_files).to include(
          'spec/fixtures/cassettes/*.yml',
          'spec/fixtures/cassettes/**/*.yml',
          'spec/cassettes/*.yml',
          'spec/cassettes/**/*.yml',
          'test/fixtures/cassettes/*.yml',
          'test/fixtures/cassettes/**/*.yml'
        )
      end
    end

    it 'loads stage-specific LLM overrides from environment' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {
            'LLM_GENERATE_MODEL' => 'gemini-2.5-pro',
            'LLM_CRITIQUE_MODEL' => 'gemini-2.5-flash-lite',
            'LLM_GENERATE_TEMPERATURE' => '0.3',
            'LLM_CRITIQUE_TEMPERATURE' => '0'
          },
          logger: Logger.new(nil)
        )

        expect(config.generate_model).to eq('gemini-2.5-pro')
        expect(config.critique_model).to eq('gemini-2.5-flash-lite')
        expect(config.generate_temperature).to eq(0.3)
        expect(config.critique_temperature).to eq(0)
      end
    end

    it 'loads LLM HTTP proxy from YAML' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              http_proxy: http://127.0.0.1:8888
              generate:
                model: gemini-2.5-pro
              critique:
                model: gemini-2.5-flash
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect(config.llm_http_proxy).to eq('http://127.0.0.1:8888')
      end
    end

    it 'raises when generate model is missing' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              critique:
                model: gemini-2.5-flash
          YAML
        )

        config = described_class.load(
          cwd: dir,
          env: { 'GEMINI_API_KEY' => 'x' },
          logger: Logger.new(nil)
        )

        expect { config.require_llm_configuration! }
          .to raise_error(Aireview::ConfigError, /generate/)
      end
    end

    it 'raises when critique model is missing' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              generate:
                model: gemini-2.5-pro
          YAML
        )

        config = described_class.load(
          cwd: dir,
          env: { 'GEMINI_API_KEY' => 'x' },
          logger: Logger.new(nil)
        )

        expect { config.require_llm_configuration! }
          .to raise_error(Aireview::ConfigError, /critique/)
      end
    end

    it 'validates models without requiring an API key' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              generate:
                model: gemini-2.5-pro
              critique:
                model: gemini-2.5-flash
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect { config.require_models! }.not_to raise_error
        expect { config.require_llm_configuration! }
          .to raise_error(Aireview::ConfigError, /API key/)
      end
    end

    it 'ignores deprecated LLM_MODEL env variable' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              generate: { model: gemini-generate }
              critique: { model: gemini-critique }
          YAML
        )

        config = described_class.load(
          cwd: dir,
          env: { 'LLM_MODEL' => 'should-be-ignored' },
          logger: Logger.new(nil)
        )

        expect(config.generate_model).to eq('gemini-generate')
        expect(config.critique_model).to eq('gemini-critique')
        expect(config).not_to respond_to(:llm_model)
      end
    end

    it 'overrides only the generate model when requested' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              generate:
                model: gemini-generate
              critique:
                model: gemini-critique
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))
        overridden = config.with_overrides(generate_model: 'gemini-generate-cli')

        expect(overridden.generate_model).to eq('gemini-generate-cli')
        expect(overridden.critique_model).to eq('gemini-critique')
      end
    end

    it 'overrides only the critique model when requested' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              generate:
                model: gemini-generate
              critique:
                model: gemini-critique
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))
        overridden = config.with_overrides(critique_model: 'gemini-critique-cli')

        expect(overridden.generate_model).to eq('gemini-generate')
        expect(overridden.critique_model).to eq('gemini-critique-cli')
      end
    end

    it 'overrides only the generate temperature when requested' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              temperature: 0.2
              generate:
                model: gemini-generate
                temperature: 0.3
              critique:
                model: gemini-critique
                temperature: 0
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))
        overridden = config.with_overrides(generate_temperature: 0.6)

        expect(overridden.llm_temperature).to eq(0.2)
        expect(overridden.generate_temperature).to eq(0.6)
        expect(overridden.critique_temperature).to eq(0)
      end
    end

    it 'overrides only the critique temperature when requested' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              temperature: 0.2
              generate:
                model: gemini-generate
                temperature: 0.3
              critique:
                model: gemini-critique
                temperature: 0
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))
        overridden = config.with_overrides(critique_temperature: 0.1)

        expect(overridden.llm_temperature).to eq(0.2)
        expect(overridden.generate_temperature).to eq(0.3)
        expect(overridden.critique_temperature).to eq(0.1)
      end
    end

    it 'lets stage-specific temperature overrides win independently' do
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, '.aireview.yml'),
          <<~YAML
            llm:
              temperature: 0.2
              generate:
                model: gemini-generate
                temperature: 0.3
              critique:
                model: gemini-critique
                temperature: 0
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))
        overridden = config.with_overrides(
          generate_model: 'gemini-generate-cli',
          critique_model: 'gemini-critique-cli',
          generate_temperature: 0.7,
          critique_temperature: 0.1
        )

        expect(overridden.generate_model).to eq('gemini-generate-cli')
        expect(overridden.critique_model).to eq('gemini-critique-cli')
        expect(overridden.llm_temperature).to eq(0.2)
        expect(overridden.generate_temperature).to eq(0.7)
        expect(overridden.critique_temperature).to eq(0.1)
      end
    end

    it 'loads OpenRouter API key from environment' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {
            'LLM_PROVIDER' => 'openrouter',
            'LLM_GENERATE_MODEL' => 'meta-llama/llama-3.3-70b-instruct:free',
            'LLM_CRITIQUE_MODEL' => 'meta-llama/llama-3.3-70b-instruct:free',
            'OPENROUTER_API_KEY' => 'sk-or-secret'
          },
          logger: Logger.new(nil)
        )

        expect(config.llm_provider).to eq('openrouter')
        expect(config.provider_api_key).to eq('sk-or-secret')
      end
    end
  end
end
