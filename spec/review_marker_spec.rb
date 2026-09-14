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

    it 'changes when the model changes' do
      expect(described_class.key(prompts: prompts(generate_model: 'gemini-3.6-flash'), config: config))
        .not_to eq(described_class.key(prompts: prompts, config: config))
    end

    it 'changes when the critique pass is disabled' do
      expect(described_class.key(prompts: prompts(critique_prompt: nil), config: config))
        .not_to eq(described_class.key(prompts: prompts, config: config))
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
