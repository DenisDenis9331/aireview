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
    expect(names).to include('GITLAB_TOKEN', 'LLM_MODELS', 'LLM_CRITIQUE_START', 'MAX_JIRA_COMMENT_CHARS')
  end
end
