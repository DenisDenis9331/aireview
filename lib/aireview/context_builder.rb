# frozen_string_literal: true
require_relative 'utils'
require_relative 'errors'
require_relative 'stages'
require_relative 'secret_scrubber'
require_relative 'diff_fetcher'
require_relative 'context_budget'

module Aireview
  class ContextBuilder
    GENERATE_PROMPT_TEMPLATE = File.read(File.expand_path('prompts/generate.txt', __dir__)).strip.freeze
    CRITIQUE_PROMPT_TEMPLATE = File.read(File.expand_path('prompts/critique.txt', __dir__)).strip.freeze
    LANGUAGE_NAMES = {
      'ru' => 'Russian',
      'en' => 'English'
    }.freeze
    CHANGES_HEADER = "Changes:\n"
    CANDIDATES_HEADER = "\n\nCandidates JSON from Generate:\n"
    # Резерв под кандидатов в промпте критика: три кандидата по ~1 500
    # символов. Оценка, не гарантия; фактический размер проверяется перед
    # отправкой.
    CANDIDATES_RESERVE_CHARS = 4_500

    # Контекст одного прогона: обе стадии получают одинаковые MR, Jira и дифф,
    # усечённые один раз под самую тесную из стадий.
    Context = Struct.new(:user_prompt, :diff_text, :coverage, :sizes, keyword_init: true)

    def initialize(config:, logger: Logger.new($stderr))
      @config = config
      @logger = logger
      @secret_scrubber = SecretScrubber.new(
        secret_patterns: config.secret_patterns,
        secret_files: config.secret_files,
        logger: logger
      )
      @diff_fetcher = DiffFetcher.new(ignore_paths: [], logger: logger)
    end

    def prepare(merge_request:, changes:, jira_issue: nil, critique: true)
      coverage = ContextBudget::Coverage.empty
      budget = context_budget(critique: critique)
      sections = merge_request_sections(merge_request, coverage: coverage)
      sections << jira_section(jira_issue, coverage: coverage) if jira_issue
      fixed = "#{sections.join("\n\n")}\n\n#{CHANGES_HEADER}"

      diff_budget = [budget - fixed.length, @config.max_diff_chars].min
      entries = @diff_fetcher.entries(@secret_scrubber.scrub_changes(changes))
      packed = ContextBudget.pack_entries(entries, budget: diff_budget, coverage: coverage)

      sizes = context_sizes(fixed: fixed, packed: packed, budget: budget, diff_budget: diff_budget, critique: critique)
      log_sizes(sizes)
      Context.new(user_prompt: fixed + packed.text, diff_text: packed.text, coverage: coverage, sizes: sizes)
    end

    def build_generate_prompt(context)
      check_stage_size!('generate', system_prompt('generate'), context.user_prompt)
    end

    def build_critique_prompt(context, candidates_json:)
      user = "#{context.user_prompt}#{CANDIDATES_HEADER}#{scrub_text(candidates_json)}"
      check_stage_size!('critique', system_prompt('critique'), user)
    end

    def system_prompt(stage)
      template = stage.to_s == 'critique' ? CRITIQUE_PROMPT_TEMPLATE : GENERATE_PROMPT_TEMPLATE
      extras = []
      if Aireview::Utils.present?(@config.review_instructions)
        extras << "Additional project instructions:\n#{scrub_text(@config.review_instructions.strip)}"
      end
      extras << "Response language: #{language_name(@config.review_language)}."

      [template, *extras].join("\n\n")
    end

    # Проверка перед отправкой: если кандидаты вышли за резерв и запрос не
    # помещается, это ошибка, а не повод молча резать контекст, который
    # генератор уже видел.
    def check_stage_size!(stage, system, user)
      stage = stage.to_s
      limit = @config.max_prompt_chars(stage)
      total = system.length + user.length
      if total > limit
        raise ContextBudgetError,
              "#{stage.capitalize} request is #{total} chars, over llm.#{stage}.max_prompt_chars=#{limit} " \
              "(system prompt #{system.length}, context #{user.length})"
      end

      {system_prompt: system, user_prompt: user}
    end

    private

    # Минимум по стадиям: контекст один на прогон, поэтому он должен
    # помещаться в каждую из них вместе с её системным промптом и резервом.
    def context_budget(critique:)
      stages = critique ? STAGES : ['generate']
      budgets = stages.to_h { |stage| [stage, stage_budget(stage)] }
      stage, budget = budgets.min_by { |_, value| value }
      return budget if budget.positive?

      raise ContextBudgetError,
            "System prompt of the #{stage} stage (#{system_prompt(stage).length} chars, including " \
            "review_instructions) leaves no room for the merge request within llm.#{stage}.max_prompt_chars=" \
            "#{@config.max_prompt_chars(stage)}"
    end

    def stage_budget(stage)
      reserve = stage == 'critique' ? CANDIDATES_RESERVE_CHARS + CANDIDATES_HEADER.length : 0
      @config.max_prompt_chars(stage) - system_prompt(stage).length - reserve
    end

    def merge_request_sections(merge_request, coverage:)
      source_branch = scrub_text(merge_request['source_branch'])
      target_branch = scrub_text(merge_request['target_branch'])
      description = ContextBudget.truncate_section(
        scrub_optional_text(merge_request['description']),
        limit: @config.max_mr_description_chars,
        label: 'MR description',
        coverage: coverage
      )

      [
        "MR: #{scrub_text(merge_request['title'])}",
        "Author: #{scrub_text(merge_request.dig('author', 'name'))}",
        "Branch: #{source_branch} -> #{target_branch}",
        "Description:\n#{description}"
      ]
    end

    def jira_section(jira_issue, coverage:)
      description = ContextBudget.truncate_section(
        scrub_optional_text(jira_issue['description']),
        limit: @config.max_jira_description_chars,
        label: 'Jira description',
        coverage: coverage
      )
      section = "Jira task (#{scrub_text(jira_issue['key'])}):\n"
      section << "Summary: #{scrub_text(jira_issue['summary'])}\n"
      section << "Description:\n#{description}"

      comments = Array(jira_issue['comments'])
      return section if comments.empty?

      rendered = comments.each_with_index.map do |comment, index|
        ContextBudget.truncate_section(
          scrub_text(comment),
          limit: @config.max_jira_comment_chars,
          label: "Jira comment #{index + 1}",
          coverage: coverage
        )
      end
      section << "\nRecent comments:\n#{rendered.join("\n")}"
    end

    def context_sizes(fixed:, packed:, budget:, diff_budget:, critique:)
      stages = critique ? STAGES : ['generate']
      {
        context_budget: budget,
        diff_budget: diff_budget,
        sections: fixed.length,
        diff: packed.text.length,
        hunks_shown: packed.shown_hunks,
        hunks_total: packed.total_hunks,
        stages: stages.to_h do |stage|
          system = system_prompt(stage).length
          [stage, {system_prompt: system, request: system + fixed.length + packed.text.length,
                   max_prompt_chars: @config.max_prompt_chars(stage)}]
        end
      }
    end

    def log_sizes(sizes)
      @logger.debug(
        "Context: sections #{sizes[:sections]} chars, diff #{sizes[:diff]} chars " \
        "(budget #{sizes[:diff_budget]}, hunks #{sizes[:hunks_shown]}/#{sizes[:hunks_total]})"
      )
      sizes[:stages].each do |stage, stage_sizes|
        @logger.debug(
          "Context #{stage}: request #{stage_sizes[:request]} chars (~#{stage_sizes[:request] / 4} tokens) " \
          "of max #{stage_sizes[:max_prompt_chars]}, system prompt #{stage_sizes[:system_prompt]}"
        )
      end
    end

    def scrub_optional_text(text)
      scrubbed = scrub_text(text)
      Aireview::Utils.presence(scrubbed) || '(empty)'
    end

    def scrub_text(text)
      @secret_scrubber.scrub_text(text.to_s)
    end

    def language_name(code)
      LANGUAGE_NAMES.fetch(code.to_s, code.to_s)
    end
  end
end
