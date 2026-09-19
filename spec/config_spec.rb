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
                model: gemini-3.7-flash
                temperature: 0.3
              critique:
                model: gemini-3.8-flash
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
        expect(config.generate_provider).to eq('gemini')
        expect(config.critique_provider).to eq('gemini')
        expect(config.generate_model).to eq('gemini-3.7-flash')
        expect(config.critique_model).to eq('gemini-3.8-flash')
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

    it 'loads Jira login from environment' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {
            'JIRA_URL' => 'https://jira.company.com',
            'JIRA_LOGIN' => 'user',
            'JIRA_PASSWORD' => 'password'
          },
          logger: Logger.new(nil)
        )

        expect(config.jira_login).to eq('user')
        expect(config.jira_password).to eq('password')
        expect(config.jira_configured?).to be(true)
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
            'LLM_GENERATE_PROVIDER' => 'gemini',
            'LLM_CRITIQUE_PROVIDER' => 'ollama',
            'LLM_GENERATE_MODEL' => 'gemini-3.7-flash',
            'LLM_CRITIQUE_MODEL' => 'qwen2.5-coder:7b',
            'LLM_GENERATE_TEMPERATURE' => '0.3',
            'LLM_CRITIQUE_TEMPERATURE' => '0'
          },
          logger: Logger.new(nil)
        )

        expect(config.generate_provider).to eq('gemini')
        expect(config.critique_provider).to eq('ollama')
        expect(config.generate_model).to eq('gemini-3.7-flash')
        expect(config.critique_model).to eq('qwen2.5-coder:7b')
        expect(config.generate_temperature).to eq(0.3)
        expect(config.critique_temperature).to eq(0)
      end
    end

    it 'loads a custom Ollama API base from environment' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: { 'OLLAMA_API_BASE' => 'http://ollama:11434/v1' },
          logger: Logger.new(nil)
        )

        expect(config.ollama_api_base).to eq('http://ollama:11434/v1')
      end
    end

    it 'uses generous default context limits' do
      Dir.mktmpdir do |dir|
        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect(config.max_prompt_chars(:generate)).to eq(400_000)
        expect(config.max_prompt_chars('critique')).to eq(400_000)
        expect(config.max_diff_chars).to eq(120_000)
        expect(config.max_mr_description_chars).to eq(8_000)
        expect(config.max_jira_description_chars).to eq(8_000)
        expect(config.max_jira_comment_chars).to eq(2_000)
      end
    end

    it 'loads context limits from YAML with stage-specific prompt limits inheriting from llm' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.aireview.yml'), <<~YAML)
          context:
            max_diff_chars: 30000
            max_jira_comment_chars: 500
          llm:
            max_prompt_chars: 50000
            critique:
              max_prompt_chars: 60000
        YAML

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect(config.max_diff_chars).to eq(30_000)
        expect(config.max_jira_comment_chars).to eq(500)
        expect(config.max_mr_description_chars).to eq(8_000)
        expect(config.max_prompt_chars(:generate)).to eq(50_000)
        expect(config.max_prompt_chars(:critique)).to eq(60_000)
      end
    end

    it 'loads context limits from environment over YAML' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.aireview.yml'), "context:\n  max_diff_chars: 30000\n")
        env = {
          'MAX_DIFF_CHARS' => '20000',
          'MAX_JIRA_DESCRIPTION_CHARS' => '1000',
          'LLM_MAX_PROMPT_CHARS' => '40000',
          'LLM_GENERATE_MAX_PROMPT_CHARS' => '25000'
        }

        config = described_class.load(cwd: dir, env: env, logger: Logger.new(nil))

        expect(config.max_diff_chars).to eq(20_000)
        expect(config.max_jira_description_chars).to eq(1_000)
        expect(config.max_prompt_chars(:generate)).to eq(25_000)
        expect(config.max_prompt_chars(:critique)).to eq(40_000)
      end
    end

    it 'rejects unparsable limits from the environment instead of falling back to defaults' do
      Dir.mktmpdir do |dir|
        expect { described_class.load(cwd: dir, env: {'LLM_MAX_PROMPT_CHARS' => '8k'}, logger: Logger.new(nil)) }
          .to raise_error(Aireview::ConfigError, 'LLM_MAX_PROMPT_CHARS must be an integer, got "8k"')
        expect { described_class.load(cwd: dir, env: {'MAX_DIFF_CHARS' => 'oops'}, logger: Logger.new(nil)) }
          .to raise_error(Aireview::ConfigError, 'MAX_DIFF_CHARS must be an integer, got "oops"')
        expect { described_class.load(cwd: dir, env: {'LLM_CRITIQUE_MAX_PROMPT_CHARS' => '1.5'}, logger: Logger.new(nil)) }
          .to raise_error(Aireview::ConfigError, 'LLM_CRITIQUE_MAX_PROMPT_CHARS must be an integer, got "1.5"')
      end
    end

    it 'rejects non-positive or non-integer context limits' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, '.aireview.yml'), "context:\n  max_diff_chars: 0\nllm:\n  max_prompt_chars: abc\n")

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect { config.max_diff_chars }
          .to raise_error(Aireview::ConfigError, 'context.max_diff_chars must be a positive integer, got 0')
        expect { config.max_prompt_chars(:generate) }
          .to raise_error(Aireview::ConfigError, 'llm.generate.max_prompt_chars must be a positive integer, got "abc"')
        expect { config.max_prompt_chars(:repair) }.to raise_error(ArgumentError, /unknown LLM stage/)
      end
    end

    it 'uses English as the default review language' do
      Dir.mktmpdir do |dir|
        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect(config.review_language).to eq('en')
      end
    end

    it 'uses the local Ollama API base by default' do
      Dir.mktmpdir do |dir|
        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect(config.ollama_api_base).to eq('http://localhost:11434/v1')
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
                model: gemini-3.7-flash
              critique:
                model: gemini-3.8-flash
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
                model: gemini-3.8-flash
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
                model: gemini-3.7-flash
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
                model: gemini-3.7-flash
              critique:
                model: gemini-3.8-flash
          YAML
        )

        config = described_class.load(cwd: dir, env: {}, logger: Logger.new(nil))

        expect { config.require_models! }.not_to raise_error
        expect { config.require_llm_configuration! }
          .to raise_error(Aireview::ConfigError, /API key/)
      end
    end

    it 'does not require API keys for Ollama stages' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {
            'LLM_GENERATE_PROVIDER' => 'ollama',
            'LLM_GENERATE_MODEL' => 'qwen2.5-coder:7b',
            'LLM_CRITIQUE_PROVIDER' => 'ollama',
            'LLM_CRITIQUE_MODEL' => 'qwen2.5-coder:7b'
          },
          logger: Logger.new(nil)
        )

        expect { config.require_llm_configuration! }.not_to raise_error
      end
    end

    it 'requires a key only for the remote stage in a mixed configuration' do
      Dir.mktmpdir do |dir|
        config = described_class.load(
          cwd: dir,
          env: {
            'LLM_GENERATE_PROVIDER' => 'ollama',
            'LLM_GENERATE_MODEL' => 'qwen2.5-coder:7b',
            'LLM_CRITIQUE_PROVIDER' => 'gemini',
            'LLM_CRITIQUE_MODEL' => 'gemini-3.8-flash'
          },
          logger: Logger.new(nil)
        )

        expect { config.require_llm_configuration! }
          .to raise_error(Aireview::ConfigError, /critique.*gemini/)
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


    describe 'fallback models and keys' do
      def load_with(dir, yaml: nil, env: {})
        File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
        described_class.load(cwd: dir, env: env, logger: Logger.new(nil))
      end

      it 'builds the stage chain from YAML with the primary model first' do
        Dir.mktmpdir do |dir|
          config = load_with(dir, yaml: <<~YAML)
            llm:
              provider: gemini
              max_prompt_chars: 100000
              generate:
                model: gemini-3.7-flash
                fallbacks:
                  - gemini-3.8-flash
                  - provider: ollama
                    model: qwen2.5-coder:7b
                    max_prompt_chars: 20000
              critique:
                model: gemini-3.8-flash
          YAML

          chain = config.stage_chain(:generate)
          expect(chain.map(&:to_s)).to eq(%w[gemini/gemini-3.7-flash gemini/gemini-3.8-flash ollama/qwen2.5-coder:7b])
          expect(chain.map(&:max_prompt_chars)).to eq([100_000, 100_000, 20_000])
          expect(config.stage_chain('critique').map(&:to_s)).to eq(['gemini/gemini-3.8-flash'])
          expect(config.fallback_names(:generate)).to eq(%w[gemini/gemini-3.8-flash ollama/qwen2.5-coder:7b])
          expect(config.api_key_counts(%i[generate critique])).to eq('gemini' => 0)
        end
      end

      it 'reads fallback models from the environment over YAML' do
        Dir.mktmpdir do |dir|
          env = {
            'LLM_GENERATE_MODEL' => 'gemini-3.7-flash',
            'LLM_GENERATE_FALLBACK_MODEL' => 'gemini-3.8-flash, ollama/qwen2.5-coder:7b',
            'LLM_CRITIQUE_MODEL' => 'gemini-3.8-flash',
            'LLM_CRITIQUE_FALLBACK_MODEL' => 'gemini-3.7-flash'
          }
          config = load_with(dir, yaml: "llm:\n  generate:\n    fallbacks:\n      - from-yaml\n", env: env)

          expect(config.stage_chain(:generate).map(&:to_s))
            .to eq(%w[gemini/gemini-3.7-flash gemini/gemini-3.8-flash ollama/qwen2.5-coder:7b])
          expect(config.stage_chain(:critique).map(&:to_s)).to eq(%w[gemini/gemini-3.8-flash gemini/gemini-3.7-flash])
        end
      end

      it 'rejects a fallback without a model or with a bad limit' do
        Dir.mktmpdir do |dir|
          config = load_with(dir, yaml: "llm:\n  generate:\n    model: g\n    fallbacks:\n      - provider: ollama\n")
          expect { config.stage_chain(:generate) }
            .to raise_error(Aireview::ConfigError, 'llm.generate.fallbacks[0].model is required')

          config = load_with(dir, yaml: "llm:\n  generate:\n    model: g\n    fallbacks:\n      - model: f\n        max_prompt_chars: 0\n")
          expect { config.stage_chain(:generate) }
            .to raise_error(Aireview::ConfigError, 'llm.generate.fallbacks[0].max_prompt_chars must be a positive integer, got 0')
        end
      end

      it 'lists API keys in order, preferring GEMINI_API_KEYS over GEMINI_API_KEY' do
        Dir.mktmpdir do |dir|
          single = load_with(dir, env: {'GEMINI_API_KEY' => 'one'})
          expect(single.provider_api_keys('gemini')).to eq(['one'])

          many = load_with(dir, env: {'GEMINI_API_KEY' => 'one', 'GEMINI_API_KEYS' => 'two, three'})
          expect(many.provider_api_keys(:gemini)).to eq(%w[two three])
          expect(many.provider_api_key('gemini')).to eq('one')
          expect(many.provider_api_keys('ollama')).to eq([nil])
        end
      end

      it 'requires a key for every provider in the chains' do
        Dir.mktmpdir do |dir|
          config = load_with(dir, yaml: <<~YAML, env: {'GEMINI_API_KEY' => 'one'})
            llm:
              provider: ollama
              generate:
                model: qwen2.5-coder:7b
                fallbacks:
                  - provider: gemini
                    model: gemini-3.8-flash
              critique:
                model: qwen2.5-coder:7b
          YAML
          expect { config.require_llm_configuration! }.not_to raise_error

          config = load_with(dir, env: {})
          expect { config.require_llm_configuration! }
            .to raise_error(Aireview::ConfigError, 'generate: API key is required for provider "gemini"')
        end
      end

      it 'keeps only the primary model and the first key when fallbacks are disabled' do
        Dir.mktmpdir do |dir|
          env = {
            'LLM_GENERATE_MODEL' => 'g', 'LLM_GENERATE_FALLBACK_MODEL' => 'f',
            'LLM_CRITIQUE_MODEL' => 'c', 'GEMINI_API_KEYS' => 'one,two'
          }
          config = load_with(dir, env: env).with_overrides(no_fallbacks: true, generate_model: 'cli')

          expect(config.stage_chain(:generate).map(&:to_s)).to eq(['gemini/cli'])
          expect(config.provider_api_keys('gemini')).to eq(['one'])
          expect(config.fallbacks_disabled?).to be(true)
          expect(config.fallback_names(:generate)).to eq([])
          expect(config.api_key_counts(%i[generate critique])).to eq('gemini' => 1)
        end
      end

      it 'reads the overloaded quarantine with a default of two minutes' do
        Dir.mktmpdir do |dir|
          expect(load_with(dir).overloaded_quarantine).to eq(120)
          expect(load_with(dir, env: {'LLM_OVERLOADED_QUARANTINE' => '300'}).overloaded_quarantine).to eq(300)
          expect(load_with(dir, yaml: "llm:\n  overloaded_quarantine: 60\n").overloaded_quarantine).to eq(60)
          expect { load_with(dir, env: {'LLM_OVERLOADED_QUARANTINE' => '0'}).overloaded_quarantine }
            .to raise_error(Aireview::ConfigError, /llm.overloaded_quarantine must be a positive integer/)
        end
      end

      it 'reads the LLM time budget with a default of 30 minutes' do
        Dir.mktmpdir do |dir|
          expect(load_with(dir).llm_time_budget).to eq(1_800)
          expect(load_with(dir, env: {'LLM_TIME_BUDGET' => '600'}).llm_time_budget).to eq(600)
          expect(load_with(dir, yaml: "llm:\n  time_budget: 900\n").llm_time_budget).to eq(900)
          expect { load_with(dir, env: {'LLM_TIME_BUDGET' => 'soon'}) }
            .to raise_error(Aireview::ConfigError, 'LLM_TIME_BUDGET must be an integer, got "soon"')
        end
      end
    end

    describe 'image defaults layer' do
      let(:image_defaults) { <<~YAML }
        review_language: en
        llm:
          provider: gemini
          timeout: 300
          generate:
            provider: gemini
            model: image-generate
            fallbacks:
              - provider: gemini
                model: image-generate-reserve
          critique:
            provider: gemini
            model: image-critique
      YAML

      def load_layered(dir, image: image_defaults, yaml: nil, env: {})
        image_path = File.join(dir, 'defaults.yml')
        File.write(image_path, image) if image
        File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
        env = env.merge('AIREVIEW_DEFAULTS' => image_path) if image
        described_class.load(cwd: dir, env: env, logger: Logger.new(nil))
      end

      it 'takes models from the image when the project has no config' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir)

          expect(config.generate_model).to eq('image-generate')
          expect(config.critique_model).to eq('image-critique')
          expect(config.fallback_names(:generate)).to eq(['gemini/image-generate-reserve'])
          expect(config.llm_timeout).to eq(300)
          expect(config.review_language).to eq('en')
          expect(config.config_path).to be_nil
          expect(config.layer_paths).to eq('image defaults' => File.join(dir, 'defaults.yml'))
          expect { config.require_models! }.not_to raise_error
        end
      end

      it 'lets the project YAML override the image and env override the project' do
        Dir.mktmpdir do |dir|
          config = load_layered(
            dir,
            yaml: "llm:\n  generate:\n    model: project-generate\n  critique:\n    model: project-critique\n",
            env: {'LLM_CRITIQUE_MODEL' => 'env-critique'}
          )

          expect(config.generate_model).to eq('project-generate')
          expect(config.critique_model).to eq('env-critique')
          expect(config.source_of('llm', 'generate', 'model')).to eq('.aireview.yml')
          expect(config.source_of('llm', 'critique', 'model')).to eq('env')
          expect(config.source_of('llm', 'generate', 'fallbacks')).to eq('image defaults')
          expect(config.source_of('llm', 'timeout')).to eq('image defaults')
          expect(config.source_of('llm', 'temperature')).to eq('built-in')
          expect(config.source_of('llm', 'generate', 'max_prompt_chars')).to be_nil
        end
      end

      it 'lets general provider and temperature from a higher layer beat stage values from the image' do
        Dir.mktmpdir do |dir|
          image = <<~YAML
            llm:
              provider: gemini
              temperature: 0
              generate:
                provider: gemini
                model: image-generate
                temperature: 0.1
                fallbacks:
                  - provider: gemini
                    model: image-reserve
              critique:
                provider: gemini
                model: image-critique
                temperature: 0
          YAML
          env = {
            'LLM_PROVIDER' => 'ollama',
            'LLM_TEMPERATURE' => '0.7',
            'LLM_GENERATE_MODEL' => 'qwen2.5-coder:7b',
            'LLM_CRITIQUE_MODEL' => 'qwen2.5-coder:7b'
          }
          config = load_layered(dir, image: image, env: env)

          expect(config.generate_provider).to eq('ollama')
          expect(config.critique_provider).to eq('ollama')
          expect(config.generate_temperature).to eq(0.7)
          expect(config.critique_temperature).to eq(0.7)
          expect(config.stage_provider_source('generate')).to eq('env')
          # Явный провайдер запасной модели не наследуется и не меняется.
          expect(config.stage_chain(:generate).map(&:to_s)).to eq(%w[ollama/qwen2.5-coder:7b gemini/image-reserve])

          config = load_layered(dir, image: image, yaml: "llm:\n  provider: ollama\n  generate:\n    model: g\n")
          expect(config.generate_provider).to eq('ollama')
          expect(config.critique_provider).to eq('ollama')
          expect(config.generate_temperature).to eq(0.1)
        end
      end

      it 'prefers the stage value within a layer and a higher-layer stage value over a general one' do
        Dir.mktmpdir do |dir|
          image = "llm:\n  provider: gemini\n  generate:\n    provider: ollama\n    model: g\n  critique:\n    model: c\n"
          config = load_layered(dir, image: image)
          expect(config.generate_provider).to eq('ollama')
          expect(config.critique_provider).to eq('gemini')

          config = load_layered(dir, image: image, yaml: "llm:\n  critique:\n    provider: ollama\n", env: {'LLM_PROVIDER' => 'gemini'})
          expect(config.generate_provider).to eq('gemini')
          expect(config.critique_provider).to eq('gemini')
          expect(config.stage_provider_source('critique')).to eq('env')

          config = load_layered(dir, image: image, env: {'LLM_MAX_PROMPT_CHARS' => '1000', 'LLM_CRITIQUE_MAX_PROMPT_CHARS' => '500'})
          expect(config.max_prompt_chars(:generate)).to eq(1000)
          expect(config.max_prompt_chars(:critique)).to eq(500)
        end
      end

      it 'keeps image fallbacks when the project overrides only the model' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir, yaml: "llm:\n  generate:\n    model: project-generate\n")

          expect(config.stage_chain(:generate).map(&:to_s)).to eq(%w[gemini/project-generate gemini/image-generate-reserve])
        end
      end

      it 'drops image fallbacks when the project sets an empty list' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir, yaml: "llm:\n  generate:\n    fallbacks: []\n")

          expect(config.fallback_names(:generate)).to eq([])
        end
      end

      it 'keeps stage settings of a config built from a hash after CLI overrides' do
        data = {
          'llm' => {
            'provider' => 'ollama', 'temperature' => 0.7, 'max_prompt_chars' => 1000,
            'generate' => {'model' => 'g'}, 'critique' => {'model' => 'c'}
          }
        }
        config = described_class.new(data, config_path: nil, logger: Logger.new(nil))
          .with_overrides(generate_model: 'cli-generate')

        expect(config.generate_model).to eq('cli-generate')
        expect(config.generate_provider).to eq('ollama')
        expect(config.critique_provider).to eq('ollama')
        expect(config.generate_temperature).to eq(0.7)
        expect(config.max_prompt_chars(:generate)).to eq(1000)
        expect(config.source_of('llm', 'generate', 'model')).to eq('cli')
        expect(config.source_of('llm', 'provider')).to eq('config')
      end

      it 'reports CLI overrides as their own layer' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir).with_overrides(generate_model: 'cli-generate')

          expect(config.generate_model).to eq('cli-generate')
          expect(config.source_of('llm', 'generate', 'model')).to eq('cli')
          expect(config.source_of('llm', 'critique', 'model')).to eq('image defaults')
        end
      end

      it 'works without the image layer' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir, image: nil, yaml: "llm:\n  generate:\n    model: g\n  critique:\n    model: c\n")

          expect(config.generate_model).to eq('g')
          expect(config.layer_paths).to eq('.aireview.yml' => File.join(dir, '.aireview.yml'))
          expect(config.source_of('llm', 'generate', 'model')).to eq('.aireview.yml')
        end
      end

      it 'fails early when AIREVIEW_DEFAULTS points to a missing file' do
        Dir.mktmpdir do |dir|
          missing = File.join(dir, 'nope.yml')
          expect { described_class.load(cwd: dir, env: {'AIREVIEW_DEFAULTS' => missing}, logger: Logger.new(nil)) }
            .to raise_error(Aireview::ConfigError, "AIREVIEW_DEFAULTS points to a missing file: #{missing}")
        end
      end

      it 'warns when a provider override makes inherited fallbacks change provider' do
        Dir.mktmpdir do |dir|
          image = <<~YAML
            llm:
              generate:
                model: image-generate
                fallbacks:
                  - image-reserve
                  - provider: gemini
                    model: explicit-reserve
              critique:
                model: image-critique
          YAML
          config = load_layered(dir, image: image, env: {'LLM_GENERATE_PROVIDER' => 'ollama'})

          expect(config.stage_provider_source('generate')).to eq('env')
          expect(config.stage_provider_warnings('generate')).to eq([
            'generate: provider "ollama" comes from env, but fallbacks without an explicit provider ' \
            'come from image defaults and now inherit it: image-reserve'
          ])
          expect(config.stage_provider_warnings('critique')).to eq([])
        end
      end

      it 'does not warn when fallbacks carry their own provider or come from the same layer' do
        Dir.mktmpdir do |dir|
          config = load_layered(dir, env: {'LLM_GENERATE_PROVIDER' => 'ollama'})
          expect(config.stage_provider_warnings('generate')).to eq([])

          config = load_layered(
            dir,
            image: nil,
            yaml: "llm:\n  generate:\n    provider: ollama\n    model: g\n    fallbacks: [r]\n  critique:\n    model: c\n"
          )
          expect(config.stage_provider_warnings('generate')).to eq([])
        end
      end
    end

    describe 'replacing the image pool from a higher layer' do
      let(:image) do
        <<~YAML
          llm:
            provider: gemini
            models: [gemini-a, gemini-b]
            generate:
              start: gemini-b
            critique:
              start: gemini-a
        YAML
      end

      def load_pool(dir, env: {}, yaml: nil, logger: Logger.new(nil))
        File.write(File.join(dir, 'defaults.yml'), image)
        File.write(File.join(dir, '.aireview.yml'), yaml) if yaml
        env = env.merge('AIREVIEW_DEFAULTS' => File.join(dir, 'defaults.yml'), 'GEMINI_API_KEY' => 'k')
        described_class.load(cwd: dir, env: env, logger: logger)
      end

      it 'starts from the first model of the new pool when the inherited start is not in it' do
        Dir.mktmpdir do |dir|
          log_output = StringIO.new
          config = load_pool(dir, env: {'LLM_MODELS' => 'gemini/custom-a,gemini/custom-b'}, logger: Logger.new(log_output))

          expect(config.stage_chain(:generate).map(&:to_s)).to eq(%w[gemini/custom-a gemini/custom-b])
          expect(config.routing.critique_chain(after: config.routing.pool[1]).map(&:to_s))
            .to eq(%w[gemini/custom-a gemini/custom-b])
          expect { config.require_llm_configuration! }.not_to raise_error
          expect(config.warnings).to eq([
            'llm.generate.start gemini-b is not in the overriding llm.models, starting from gemini/custom-a',
            'llm.critique.start gemini-a is not in the overriding llm.models, starting from gemini/custom-a'
          ])
          expect(log_output.string).not_to include('llm.generate.start')
          expect(config.stage_model_source('generate')).to eq('env')
        end
      end

      it 'keeps an inherited start that the new pool still contains' do
        Dir.mktmpdir do |dir|
          config = load_pool(dir, yaml: "llm:\n  models: [gemini-c, gemini-b]\n")
          expect(config.stage_chain(:generate).map(&:to_s)).to eq(%w[gemini/gemini-b gemini/gemini-c])
        end
      end

      it 'still rejects a wrong start given in the same or a higher layer than the pool' do
        Dir.mktmpdir do |dir|
          config = load_pool(dir, env: {'LLM_MODELS' => 'gemini/custom-a', 'LLM_GENERATE_START' => 'gemini-b'})
          expect { config.stage_chain(:generate) }
            .to raise_error(Aireview::ConfigError, 'gemini-b is not in llm.models: gemini/custom-a')

          config = load_pool(dir, yaml: "llm:\n  models: [gemini-c]\n  generate:\n    start: gemini-b\n")
          expect { config.stage_chain(:generate) }
            .to raise_error(Aireview::ConfigError, 'gemini-b is not in llm.models: gemini/gemini-c')
        end
      end
    end

    describe 'config/defaults.yml shipped in the image' do
      it 'is a complete pool configuration with an explicit provider on every model' do
        path = File.expand_path('../config/defaults.yml', __dir__)
        Dir.mktmpdir do |dir|
          config = described_class.load(cwd: dir, env: {'AIREVIEW_DEFAULTS' => path}, logger: Logger.new(nil))

          expect { config.require_models! }.not_to raise_error
          expect(config.routing).to be_a(Aireview::ModelPool)
          expect(config.routing.pool_stage?('generate') && config.routing.pool_stage?('critique')).to be(true)
          pool = config.routing.pool
          expect(pool.size).to eq(5)
          expect(pool.map(&:model).uniq.size).to eq(5)
          expect(pool.map(&:provider).uniq).to eq(['gemini'])
          expect(pool.map(&:model)).to all(match(/\A[a-z0-9.-]+\z/))
          expect(pool.map(&:model)).not_to include(a_string_matching(/preview|exp/))
          # Generate стартует не с самой сильной модели, критика — с самой сильной.
          expect(config.stage_chain(:generate).first.model).to eq('gemini-3.7-flash')
          expect(config.stage_chain(:critique).first.model).to eq('gemini-3.8-flash')
          expect(config.routing.rule).to eq('not_below_generate')
          expect(config.generate_temperature).to eq(0.1)
          expect(config.critique_temperature).to eq(0)
          expect(config.llm_timeout).to eq(180)
          expect(config.overloaded_quarantine).to eq(120)
          expect(config.stage_provider_warnings('generate')).to eq([])
          expect(config.stage_model_source('generate')).to eq('image defaults')
          expect(config.stage_fallbacks_source('critique')).to eq('image defaults')
          expect(config.with_overrides(critique_model: 'gemini-3.6-flash').stage_model_source('critique')).to eq('cli')

          raw = YAML.load_file(path)
          raw.dig('llm', 'models').each { |item| expect(item).to include('provider' => 'gemini') }
          expect(raw.to_s).not_to match(/api_key|token/i)
        end
      end
    end
  end
end
