# frozen_string_literal: true

require 'aireview'

RSpec.describe Aireview::ReviewMarker do
  def config(overrides = {})
    Aireview::Config.new(
      {
        'llm' => {
          'provider' => 'gemini',
          'temperature' => 0,
          'generate' => {'model' => 'gemini-3.7-flash'},
          'critique' => {'model' => 'gemini-3.8-flash'}
        }
      }.merge(overrides),
      config_path: nil,
      logger: Logger.new(File::NULL)
    )
  end

  def prompts(overrides = {})
    {
      generate_prompt: {system_prompt: 'system', user_prompt: 'diff and description'},
      critique_prompt: {system_prompt: 'system', user_prompt: 'candidates'},
      generate_model: 'gemini-3.7-flash',
      generate_temperature: 0.1,
      critique_model: 'gemini-3.8-flash',
      critique_temperature: 0
    }.merge(overrides)
  end

  describe '.build and .extract' do
    it 'reads back the key it wrote' do
      expect(described_class.extract("#{described_class.build('abc123')}\nreview")).to eq('abc123')
    end

    it 'returns nil when the note carries no marker' do
      expect(described_class.extract('just a comment')).to be_nil
    end
  end

  describe '.key' do
    it 'stays the same for the same prompts and settings' do
      expect(described_class.key(prompts: prompts, config: config))
        .to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'changes when the prompt changes' do
      changed = prompts(generate_prompt: {system_prompt: 'system', user_prompt: 'another description'})

      expect(described_class.key(prompts: changed, config: config))
        .not_to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'changes when the model or the temperature of a stage changes in the config' do
      other_model = config('llm' => {'provider' => 'gemini', 'temperature' => 0,
                                     'generate' => {'model' => 'gemini-3.6-flash'},
                                     'critique' => {'model' => 'gemini-3.8-flash'}})
      other_temperature = config('llm' => {'provider' => 'gemini', 'temperature' => 0,
                                           'generate' => {'model' => 'gemini-3.7-flash', 'temperature' => 0.5},
                                           'critique' => {'model' => 'gemini-3.8-flash'}})

      expect(described_class.key(prompts: prompts, config: other_model))
        .not_to eq(described_class.key(prompts: prompts, config: config))
      expect(described_class.key(prompts: prompts, config: other_temperature))
        .not_to eq(described_class.key(prompts: prompts, config: config))
    end

    # Golden keys: changing what goes into the key would re-review every open MR.
    it 'stays byte-identical to the keys of the previous release' do
      golden_prompts = prompts(generate_prompt: {system_prompt: 'system', user_prompt: 'diff'})
      stage = config('llm' => {'provider' => 'gemini', 'generate' => {'model' => 'gemini-3.7-flash', 'temperature' => 0.1},
                               'critique' => {'model' => 'gemini-3.8-flash'}})
      pool = config('llm' => {'provider' => 'gemini', 'models' => %w[gemini-3.8-flash gemini-3.7-flash],
                              'generate' => {'start' => 'gemini-3.7-flash', 'temperature' => 0.1}})

      expect(described_class.key(prompts: golden_prompts, config: stage)).to eq('9ae278d453a80f43')
      expect(described_class.key(prompts: golden_prompts, config: pool)).to eq('576d70cfbea178a1')
      expect(described_class.key(prompts: golden_prompts.merge(critique_prompt: nil), config: stage)).to eq('783db3b9d42ab693')
    end

    it 'changes with the count of files the platform did not return, and only when it is nonzero' do
      coverage = lambda do |missing|
        Aireview::ContextBudget::Coverage.empty.tap { |value| value.files_not_returned = missing }
      end
      complete = described_class.key(prompts: prompts, config: config)

      expect(described_class.key(prompts: prompts(coverage: coverage.call(0)), config: config)).to eq(complete)
      expect(described_class.key(prompts: prompts(coverage: coverage.call(412)), config: config)).not_to eq(complete)
      expect(described_class.key(prompts: prompts(coverage: coverage.call(415)), config: config))
        .not_to eq(described_class.key(prompts: prompts(coverage: coverage.call(412)), config: config))
    end

    it 'changes when the critique pass is disabled' do
      expect(described_class.key(prompts: prompts(critique_prompt: nil), config: config))
        .not_to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'changes with the order and the policy of a shared pool' do
      pool = { 'provider' => 'gemini', 'temperature' => 0, 'models' => %w[strong medium weak],
               'generate' => {'start' => 'medium'}, 'critique' => {'allow_weaker' => false} }
      strict = described_class.key(prompts: prompts, config: config('llm' => pool))
      lenient = described_class.key(
        prompts: prompts, config: config('llm' => pool.merge('critique' => {'allow_weaker' => true}))
      )
      reordered = described_class.key(prompts: prompts, config: config('llm' => pool.merge('models' => %w[strong weak medium])))

      expect(strict).not_to eq(lenient)
      expect(strict).not_to eq(reordered)
      expect(strict).to eq(described_class.key(prompts: prompts, config: config('llm' => pool)))
      expect(strict).not_to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'ignores fallback models and extra keys: only the configured primary model counts' do
      with_fallbacks = config(
        'llm' => {
          'provider' => 'gemini',
          'temperature' => 0,
          'generate' => {'model' => 'gemini-3.7-flash', 'fallbacks' => ['gemini-3.8-flash']},
          'critique' => {'model' => 'gemini-3.8-flash', 'fallbacks' => [{'provider' => 'ollama', 'model' => 'q'}]}
        },
        'gemini_api_keys' => %w[one two]
      )

      expect(described_class.key(prompts: prompts, config: with_fallbacks))
        .to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'looks like a short hex digest' do
      expect(described_class.key(prompts: prompts, config: config)).to match(/\A[0-9a-f]{16}\z/)
    end

    context 'with prompts built through the context budget' do
      let(:merge_request) do
        {
          'title' => 'Fix totals',
          'description' => 'A' * 100,
          'source_branch' => 'fix',
          'target_branch' => 'main',
          'author' => {'name' => 'Denis'}
        }
      end
      let(:changes) do
        [{'old_path' => 'a.rb', 'new_path' => 'a.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"}]
      end

      def key_for(context_overrides)
        pipeline = Aireview::ReviewPipeline.new(
          config: config('context' => context_overrides),
          reviewer: instance_double(Aireview::Reviewer),
          logger: Logger.new(File::NULL)
        )
        prompts = pipeline.dry_run_prompts(merge_request: merge_request, changes: changes)
        described_class.key(prompts: prompts, config: config)
      end

      it 'changes when a limit truncates the context' do
        expect(key_for('max_mr_description_chars' => 50)).not_to eq(key_for('max_mr_description_chars' => 500))
      end

      it 'stays the same when a limit does not change the prompt' do
        expect(key_for('max_diff_chars' => 5_000)).to eq(key_for('max_diff_chars' => 50_000))
      end
    end
  end

  describe '.key with Jev as the critique engine' do
    let(:merge_request) do
      {'title' => 'Fix totals', 'description' => 'Tax must stay', 'source_branch' => 'fix',
       'target_branch' => 'main', 'author' => {'name' => 'Denis'}}
    end
    let(:changes) { [{'old_path' => 'a.rb', 'new_path' => 'a.rb', 'diff' => "@@ -1 +1 @@\n-old\n+new\n"}] }

    def jev_config(jev: {}, critique: {}, engine: 'jev')
      llm = {
        'provider' => 'gemini', 'temperature' => 0,
        'generate' => {'model' => 'gemini-3.7-flash'},
        'critique' => {'model' => 'gemini-3.8-flash', 'engine' => engine}.merge(critique),
        'jev' => jev
      }
      config('llm' => llm, 'jev_api_key' => 'j')
    end

    def key_for(config, critique: true)
      pipeline = Aireview::ReviewPipeline.new(config: config, reviewer: instance_double(Aireview::Reviewer),
                                              logger: Logger.new(File::NULL))
      prompts = pipeline.dry_run_prompts(merge_request: merge_request, changes: changes, critique: critique)
      described_class.key(prompts: prompts, config: config)
    end

    it 'is the key from before Jev with the model engine, whatever the Jev settings' do
      plain = key_for(config)

      expect(key_for(jev_config(engine: 'model', jev: {'shadow' => true, 'keep_above' => 0.9}))).to eq(plain)
    end

    it 'changes with the engine, the version, every threshold and the fallback' do
      base = key_for(jev_config)
      variants = [
        {'model' => 'jev-1.14.0'}, {'keep_above' => 0.6}, {'enough_context' => 0.6},
        {'version_claim' => 0.6}, {'duplicate' => 0.6}, {'fallback' => 'fail'}
      ]

      expect(base).not_to eq(key_for(config))
      variants.each { |jev| expect(key_for(jev_config(jev: jev))).not_to eq(base), jev.inspect }
    end

    it 'changes when only the criteria of the duplicate question change' do
      base = key_for(jev_config)
      templates = Aireview::JevCritic.decision_templates
      changed = templates.merge('duplicate_of' => templates['duplicate_of'].merge('none' => 'Nothing alike.'))
      allow(Aireview::JevCritic).to receive(:decision_templates).and_return(changed)

      expect(key_for(jev_config)).not_to eq(base)
    end

    it 'follows the LLM critique model while Jev can fall back to it, and ignores it otherwise' do
      other_model = {'model' => 'gemini-3.6-flash'}

      expect(key_for(jev_config(critique: other_model))).not_to eq(key_for(jev_config))
      expect(key_for(jev_config(jev: {'fallback' => 'fail'}, critique: other_model)))
        .to eq(key_for(jev_config(jev: {'fallback' => 'fail'})))
    end

    it 'keeps the generate pool in the key and ignores an unused critique model when Jev cannot fall back' do
      pool_config = lambda do |models, critique: {}|
        llm = {'provider' => 'gemini', 'models' => models, 'critique' => {'engine' => 'jev'}.merge(critique),
               'jev' => {'fallback' => 'fail'}}
        config('llm' => llm, 'jev_api_key' => 'j')
      end
      base = key_for(pool_config.call(%w[g1 g2]))

      expect(key_for(pool_config.call(%w[g1 g2], critique: {'model' => 'c1'}))).to eq(base)
      expect(key_for(pool_config.call(%w[g1 g3]))).not_to eq(base)
      expect(key_for(pool_config.call(%w[g1 g3], critique: {'model' => 'c1'})))
        .not_to eq(key_for(pool_config.call(%w[g1 g2], critique: {'model' => 'c1'})))
    end

    it 'has no critique part at all with --no-critique, whatever the engine' do
      expect(key_for(jev_config, critique: false)).to eq(key_for(config, critique: false))
    end
  end

  describe '.state' do
    let(:merge_request) do
      {
        'sha' => 'headsha',
        'target_branch' => 'master',
        'diff_refs' => {'base_sha' => 'basesha', 'head_sha' => 'headsha'}
      }
    end

    it 'differs when a new commit arrives' do
      expect(described_class.state(merge_request.merge('sha' => 'newsha')))
        .not_to eq(described_class.state(merge_request))
    end

    it 'differs when the target branch is switched' do
      expect(described_class.state(merge_request.merge('target_branch' => 'release')))
        .not_to eq(described_class.state(merge_request))
    end

    it 'differs when the comparison base moves' do
      rebased = merge_request.merge('diff_refs' => {'base_sha' => 'newbase', 'head_sha' => 'headsha'})

      expect(described_class.state(rebased)).not_to eq(described_class.state(merge_request))
    end
  end
end
