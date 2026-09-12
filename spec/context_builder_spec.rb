require 'aireview/context_builder'

RSpec.describe Aireview::ContextBuilder do
  def config_double(**overrides)
    defaults = {
      review_instructions: "Проверь тесты\nИ migrations",
      review_language: 'ru',
      secret_patterns: [],
      secret_files: [],
      max_prompt_chars: 400_000,
      max_diff_chars: 120_000,
      max_mr_description_chars: 8_000,
      max_jira_description_chars: 8_000,
      max_jira_comment_chars: 2_000
    }
    instance_double('Aireview::Config', **defaults.merge(overrides))
  end

  let(:config) { config_double }

  let(:merge_request) do
    {
      'title' => 'Add review flow',
      'description' => 'Implements MR review',
      'source_branch' => 'feature/review',
      'target_branch' => 'main',
      'author' => { 'name' => 'Denis' }
    }
  end

  let(:jira_issue) do
    {
      'key' => 'AIR-123',
      'summary' => 'Implement review flow',
      'description' => 'Need a local review command',
      'comments' => ['QA: please verify dry-run']
    }
  end

  def change(path, diff)
    { 'old_path' => path, 'new_path' => path, 'diff' => diff }
  end

  def hunk(index, lines: 3)
    "@@ -#{index * 10},#{lines} +#{index * 10},#{lines} @@\n" + Array.new(lines) { |i| "+line #{index}.#{i}\n" }.join
  end

  let(:changes) { [change('a.rb', "#{hunk(1)}#{hunk(2)}"), change('b.rb', hunk(3))] }
  let(:builder) { described_class.new(config: config, logger: Logger.new(nil)) }

  describe '#prepare and prompts' do
    it 'builds system and user prompts with jira context' do
      context = builder.prepare(merge_request: merge_request, changes: changes, jira_issue: jira_issue)
      prompt = builder.build_generate_prompt(context)

      expect(prompt[:system_prompt]).to include('Additional project instructions')
      expect(prompt[:system_prompt]).to include('Response language: Russian.')
      expect(prompt[:user_prompt]).to include('MR: Add review flow')
      expect(prompt[:user_prompt]).to include('Author: Denis')
      expect(prompt[:user_prompt]).to include('Jira task (AIR-123):')
      expect(prompt[:user_prompt]).to include('QA: please verify dry-run')
      expect(prompt[:user_prompt]).to include("Changes:\ndiff --git a/a.rb b/a.rb")
      expect(prompt[:user_prompt]).to include('+line 3.0')
      expect(context.coverage).to be_complete
    end

    it 'gives both stages the same context' do
      context = builder.prepare(merge_request: merge_request, changes: changes, jira_issue: jira_issue)

      generate = builder.build_generate_prompt(context)
      critique = builder.build_critique_prompt(context, candidates_json: '[{"id":"C1"}]')

      expect(critique[:user_prompt]).to start_with(generate[:user_prompt])
      expect(critique[:user_prompt]).to end_with("Candidates JSON from Generate:\n[{\"id\":\"C1\"}]")
      expect(critique[:system_prompt]).to include('second pass')
      expect(generate[:system_prompt]).to include('first pass')
    end

    it 'truncates long sections keeping their beginning and marks them' do
      config = config_double(max_mr_description_chars: 12, max_jira_description_chars: 4, max_jira_comment_chars: 5)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      context = builder.prepare(
        merge_request: merge_request.merge('description' => 'Requirements first, details later'),
        changes: changes,
        jira_issue: jira_issue.merge('comments' => ['short', 'a longer comment'])
      )

      expect(context.user_prompt).to include("Requirements\n[MR description truncated: 12 of 33 chars shown]")
      expect(context.user_prompt).to include("Need\n[Jira description truncated: 4 of 27 chars shown]")
      expect(context.user_prompt).to include("short\na lon\n[Jira comment 2 truncated: 5 of 16 chars shown]")
      expect(context.coverage.truncated_sections).to eq(['MR description', 'Jira description', 'Jira comment 2'])
    end

    it 'packs the diff by whole files and then whole hunks within the context budget' do
      changes = [change('a.rb', "#{hunk(1, lines: 40)}#{hunk(2, lines: 40)}"), change('b.rb', hunk(3, lines: 40))]
      fixed = builder.prepare(merge_request: merge_request, changes: []).user_prompt.length
      first_hunk_only = "diff --git a/a.rb b/a.rb\n--- a/a.rb\n+++ b/a.rb\n#{hunk(1, lines: 40)}".length + 60
      budget = fixed + Aireview::ContextBudget::TRAILER_RESERVE_CHARS + first_hunk_only
      config = config_double(max_prompt_chars: budget + builder.system_prompt(:generate).length)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      context = builder.prepare(merge_request: merge_request, changes: changes, critique: false)

      expect(context.user_prompt).to include('+line 1.0')
      expect(context.user_prompt).not_to include('+line 2.0')
      expect(context.user_prompt).not_to include('+line 3.0')
      expect(context.user_prompt).to include('[file a.rb: 1 of 2 hunks shown]')
      expect(context.user_prompt).to include('[1 file(s) not shown: b.rb]')
      expect(context.coverage.files_partial).to eq([{ path: 'a.rb', shown: 1, total: 2 }])
      expect(context.coverage.files_not_shown).to eq(['b.rb'])
    end

    it 'sizes the shared context for the tighter critique stage' do
      changes = [change('a.rb', hunk(1, lines: 40)), change('b.rb', hunk(2, lines: 40)), change('c.rb', hunk(3, lines: 40))]
      full = builder.prepare(merge_request: merge_request, changes: changes)
      reserve = described_class::CANDIDATES_RESERVE_CHARS + described_class::CANDIDATES_HEADER.length
      config = config_double(max_prompt_chars: full.sizes[:stages][:critique][:request] + reserve - 300)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      without_critique = builder.prepare(merge_request: merge_request, changes: changes, critique: false)
      with_critique = builder.prepare(merge_request: merge_request, changes: changes, critique: true)

      expect(without_critique.coverage).to be_complete
      expect(with_critique.coverage).not_to be_complete
      expect(with_critique.sizes[:context_budget]).to be < without_critique.sizes[:context_budget]
    end

    it 'raises instead of re-truncating when candidates exceed their reserve' do
      context = builder.prepare(merge_request: merge_request, changes: changes)
      reserve = described_class::CANDIDATES_RESERVE_CHARS + described_class::CANDIDATES_HEADER.length
      limit = context.sizes[:stages][:critique][:request] + reserve + 100
      config = config_double(max_prompt_chars: limit)
      builder = described_class.new(config: config, logger: Logger.new(nil))
      context = builder.prepare(merge_request: merge_request, changes: changes)

      expect(context.coverage).to be_complete
      expect { builder.build_critique_prompt(context, candidates_json: 'x' * (reserve + 200)) }
        .to raise_error(Aireview::ContextBudgetError, /Critique request is \d+ chars, over llm.critique.max_prompt_chars=#{limit}/)
      expect(builder.build_critique_prompt(context, candidates_json: 'x' * 50)[:user_prompt]).to include('x' * 50)
    end

    it 'raises when the system prompt alone exceeds the stage limit' do
      config = config_double(max_prompt_chars: 100)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      expect { builder.prepare(merge_request: merge_request, changes: changes) }
        .to raise_error(Aireview::ContextBudgetError, /System prompt of the critique stage .* review_instructions/)
    end

    it 'caps the diff with max_diff_chars independently of the prompt budget' do
      changes = [change('a.rb', hunk(1, lines: 40)), change('b.rb', hunk(2, lines: 40))]
      a_full = Aireview::DiffFetcher::Entry.new(changes.first).render.length
      config = config_double(max_diff_chars: Aireview::ContextBudget::TRAILER_RESERVE_CHARS + a_full + 20)
      builder = described_class.new(config: config, logger: Logger.new(nil))

      context = builder.prepare(merge_request: merge_request, changes: changes)

      expect(context.sizes[:diff_budget]).to eq(config.max_diff_chars)
      expect(context.coverage.files_not_shown).to eq(['b.rb'])
    end

    it 'reports sizes for the verbose summary' do
      context = builder.prepare(merge_request: merge_request, changes: changes)

      expect(context.sizes[:hunks_shown]).to eq(3)
      expect(context.sizes[:hunks_total]).to eq(3)
      expect(context.sizes[:stages].keys).to eq(%i[generate critique])
      expect(context.sizes[:stages][:critique][:max_prompt_chars]).to eq(400_000)
    end

    it 'scrubs secrets from MR, Jira, instructions, and changes' do
      config = config_double(review_instructions: 'Never expose sk-systemfakefakefakefakefake')
      builder = described_class.new(config: config, logger: Logger.new(nil))

      context = builder.prepare(
        merge_request: merge_request.merge(
          'title' => 'Fix auth sk-titlefakefakefakefakefake',
          'description' => 'Token: Bearer long-description-token-1234567890'
        ),
        changes: [change('a.rb', "@@ -1 +1 @@\n+Authorization: Bearer long-diff-token-1234567890\n")],
        jira_issue: {
          'key' => 'AIR-123',
          'summary' => 'Summary sk-summaryfakefakefakefakefake',
          'description' => 'Jira token glpat_fakefakefakefakefakefakefake',
          'comments' => ['QA: ghp_fakefakefakefakefakefakefake']
        }
      )
      prompt = builder.build_generate_prompt(context)

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
      context = builder.prepare(merge_request: merge_request, changes: changes)

      prompt = builder.build_critique_prompt(
        context,
        candidates_json: '{"quoted_code":"Bearer long-candidate-token-1234567890"}'
      )

      expect(prompt[:user_prompt]).not_to include('long-candidate-token')
      expect(prompt[:user_prompt]).to include('Bearer [REDACTED]')
    end
  end
end
