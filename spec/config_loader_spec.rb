require 'tmpdir'
require 'aireview/config_loader'

# The loader boundary: layers in priority order and env parsing apart from
# Config; the full set of loading scenarios is in config_spec through Config.load.
RSpec.describe Aireview::ConfigLoader do
  it 'stacks built-in, image, file and env layers in that order' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'image.yml'), "review_language: en\n")
      File.write(File.join(dir, '.aireview.yml'), "llm:\n  timeout: 90\n")
      config = described_class.load(cwd: dir, env: {'AIREVIEW_DEFAULTS' => File.join(dir, 'image.yml'), 'LLM_TIMEOUT' => '30'},
                                    logger: Logger.new(nil))

      expect(config).to be_a(Aireview::Config)
      expect(config.layers.map(&:name)).to eq(['built-in', 'image defaults', '.aireview.yml', 'env'])
      expect(config.review_language).to eq('en')
      expect(config.llm_timeout).to eq(30.0)
      expect(config.config_path).to eq(File.join(dir, '.aireview.yml'))
    end
  end

  describe 'bundled defaults' do
    it 'stand in for the image layer when no layer names a model' do
      Dir.mktmpdir do |dir|
        config = described_class.load(cwd: dir, env: {'LLM_TIMEOUT' => '30'}, logger: Logger.new(nil))

        expect(config.layers.map(&:name)).to eq(['built-in', 'bundled defaults', 'env'])
        expect(config.layer_paths).to eq('bundled defaults' => described_class::BUNDLED_DEFAULTS)
        expect(config.source_of('llm', 'models')).to eq('bundled defaults')
        expect(config.llm_timeout).to eq(30.0)
        expect { config.require_models! }.not_to raise_error
      end
    end

    it 'stay out when .aireview.yml or env names a model' do
      Dir.mktmpdir do |dir|
        [{'LLM_MODELS' => 'ollama/q:7b'}, {'LLM_CRITIQUE_MODEL' => 'c'}].each do |env|
          expect(described_class.load(cwd: dir, env: env, logger: Logger.new(nil)).layers.map(&:name))
            .to eq(%w[built-in env])
        end

        File.write(File.join(dir, '.aireview.yml'), "llm:\n  generate:\n    model: g\n")
        expect(described_class.load(cwd: dir, env: {}, logger: Logger.new(nil)).layers.map(&:name))
          .to eq(['built-in', '.aireview.yml', 'env'])
      end
    end

    it 'stay out when the CLI names a model, keeping the configured fallbacks' do
      Dir.mktmpdir do |dir|
        env = {'LLM_PROVIDER' => 'ollama', 'LLM_GENERATE_FALLBACK_MODEL' => 'backup-local'}
        config = described_class.load(cwd: dir, env: env, logger: Logger.new(nil))
          .with_overrides(generate_model: 'primary-local', no_critique: true)

        expect(config.layers.map(&:name)).to eq(%w[built-in env cli])
        expect(config.stage_chain('generate').map(&:to_s)).to eq(%w[ollama/primary-local ollama/backup-local])
      end
    end

    it 'give way to AIREVIEW_DEFAULTS' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'image.yml'), "review_language: en\n")
        config = described_class.load(cwd: dir, env: {'AIREVIEW_DEFAULTS' => File.join(dir, 'image.yml')},
                                      logger: Logger.new(nil))

        expect(config.layers.map(&:name)).to eq(['built-in', 'image defaults', 'env'])
      end
    end
  end

  it 'parses env into the same shape as the YAML' do
    env = {
      'LLM_PROVIDER' => 'gemini', 'LLM_TEMPERATURE' => '0.2', 'LLM_TIME_BUDGET' => '600',
      'LLM_GENERATE_MODEL' => 'g', 'LLM_GENERATE_FALLBACK_MODEL' => 'r1, ollama/q:7b',
      'LLM_MODELS' => 'a,gemini/b', 'LLM_CRITIQUE_ALLOW_WEAKER' => 'yes',
      'GEMINI_API_KEYS' => 'one, two', 'LLM_API_KEY' => 'generic', 'MAX_DIFF_CHARS' => '500',
      'LLM_HTTP_PROXY' => ' '
    }

    expect(described_class.env_config(env)).to eq(
      'llm' => {
        'provider' => 'gemini', 'temperature' => 0.2, 'time_budget' => 600,
        'generate' => {'model' => 'g', 'fallbacks' => [{'model' => 'r1'}, {'provider' => 'ollama', 'model' => 'q:7b'}]},
        'models' => [{'model' => 'a'}, {'provider' => 'gemini', 'model' => 'b'}],
        'critique' => {'allow_weaker' => true}
      },
      'context' => {'max_diff_chars' => 500},
      'gemini_api_keys' => %w[one two],
      'llm_api_key' => 'generic'
    )
  end

  it 'rejects values it cannot parse instead of falling back to defaults' do
    expect { described_class.env_config('LLM_TIME_BUDGET' => 'soon') }
      .to raise_error(Aireview::ConfigError, 'LLM_TIME_BUDGET must be an integer, got "soon"')
    expect { described_class.env_config('LLM_CRITIQUE_ALLOW_WEAKER' => 'maybe') }
      .to raise_error(Aireview::ConfigError, 'LLM_CRITIQUE_ALLOW_WEAKER must be true or false, got "maybe"')
    expect(described_class.env_config('LLM_TEMPERATURE' => 'warm')).to eq('llm' => {})
  end

  it 'lists every env name it reads, without duplicates' do
    names = described_class.env_names
    expect(names).to eq(names.uniq)
    expect(names).to include('GITLAB_TOKEN', 'GITHUB_TOKEN', 'GITHUB_API_URL', 'GITHUB_REVIEW_AUTHOR', 'LLM_MODELS', 'LLM_CRITIQUE_START', 'MAX_JIRA_COMMENT_CHARS')
  end
end
