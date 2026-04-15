require 'aireview/context_builder'

RSpec.describe Aireview::ContextBuilder do
  let(:config) do
    instance_double(
      'Aireview::Config',
      review_instructions: "Проверь тесты\nИ migrations",
      review_language: 'ru',
      secret_patterns: [],
      secret_files: []
    )
  end

  let(:merge_request) do
    {
      'title' => 'Add review flow',
      'description' => 'Implements MR review',
      'source_branch' => 'feature/review',
      'target_branch' => 'main',
      'author' => { 'name' => 'Denis' }
    }
  end

  describe '#build' do
    it 'builds system and user prompts with jira context' do
      builder = described_class.new(config: config, logger: Logger.new(nil))
      prompt = builder.build(
        merge_request: merge_request,
        changes_text: "diff --git a/a.rb b/a.rb\n+puts 1",
        jira_issue: {
          'key' => 'AIR-123',
          'summary' => 'Implement review flow',
          'description' => 'Need a local review command',
          'comments' => ['QA: please verify dry-run']
        }
      )

      expect(prompt[:system_prompt]).to include('Дополнительные инструкции проекта')
      expect(prompt[:system_prompt]).to include('Язык ответа: русский.')
      expect(prompt[:user_prompt]).to include('MR: Add review flow')
      expect(prompt[:user_prompt]).to include('Author: Denis')
      expect(prompt[:user_prompt]).to include('Jira task (AIR-123):')
      expect(prompt[:user_prompt]).to include('QA: please verify dry-run')
      expect(prompt[:user_prompt]).to include('Changes:')
    end

    it 'truncates long diff text' do
      stub_const("#{described_class}::MAX_DIFF_CHARS", 20)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      prompt = builder.build(
        merge_request: merge_request,
        changes_text: 'x' * 30
      )

      expect(prompt[:user_prompt]).to include('[TRUNCATED 10 chars]')
    end

    it 'scrubs secrets from MR, Jira, instructions, and changes text' do
      config = instance_double(
        'Aireview::Config',
        review_instructions: 'Never expose sk-systemfakefakefakefakefake',
        review_language: 'ru',
        secret_patterns: [],
        secret_files: []
      )
      builder = described_class.new(config: config, logger: Logger.new(nil))

      prompt = builder.build(
        merge_request: merge_request.merge(
          'title' => 'Fix auth sk-titlefakefakefakefakefake',
          'description' => 'Token: Bearer long-description-token-1234567890'
        ),
        changes_text: "diff --git a/a.rb b/a.rb\n+Authorization: Bearer long-diff-token-1234567890",
        jira_issue: {
          'key' => 'AIR-123',
          'summary' => 'Summary sk-summaryfakefakefakefakefake',
          'description' => 'Jira token glpat_fakefakefakefakefakefakefake',
          'comments' => ['QA: ghp_fakefakefakefakefakefakefake']
        }
      )

      combined_prompt = "#{prompt[:system_prompt]}\n#{prompt[:user_prompt]}"

      expect(combined_prompt).not_to include('sk-system')
      expect(combined_prompt).not_to include('sk-title')
      expect(combined_prompt).not_to include('long-description-token')
      expect(combined_prompt).not_to include('long-diff-token')
      expect(combined_prompt).not_to include('sk-summary')
      expect(combined_prompt).not_to include('glpat_fake')
      expect(combined_prompt).not_to include('ghp_fake')
      expect(combined_prompt).to include('[REDACTED]')
    end

    it 'scrubs secrets from generate candidates before critique' do
      builder = described_class.new(config: config, logger: Logger.new(nil))

      prompt = builder.build_critique_prompt(
        merge_request: merge_request,
        changes_text: 'diff --git a/a.rb b/a.rb',
        candidates_json: '{"quoted_code":"Bearer long-candidate-token-1234567890"}'
      )

      expect(prompt[:user_prompt]).not_to include('long-candidate-token')
      expect(prompt[:user_prompt]).to include('Bearer [REDACTED]')
    end
  end
end
