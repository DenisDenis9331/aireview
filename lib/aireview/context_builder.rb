require_relative 'utils'
require_relative 'secret_scrubber'

module Aireview
  class ContextBuilder
    MAX_DIFF_CHARS = 120_000
    GENERATE_PROMPT_TEMPLATE = File.read(File.expand_path('prompts/generate.txt', __dir__)).strip.freeze
    CRITIQUE_PROMPT_TEMPLATE = File.read(File.expand_path('prompts/critique.txt', __dir__)).strip.freeze
    LANGUAGE_NAMES = {
      'ru' => 'русский',
      'en' => 'английский'
    }.freeze

    def initialize(config:, logger: Logger.new($stderr))
      @config = config
      @logger = logger
      @secret_scrubber = SecretScrubber.new(
        secret_patterns: config.secret_patterns,
        secret_files: config.secret_files,
        logger: logger
      )
    end

    def build(merge_request:, changes_text:, jira_issue: nil)
      build_generate_prompt(merge_request: merge_request, changes_text: changes_text, jira_issue: jira_issue)
    end

    def build_generate_prompt(merge_request:, changes_text:, jira_issue: nil)
      {
        system_prompt: system_prompt(GENERATE_PROMPT_TEMPLATE),
        user_prompt: user_prompt(merge_request: merge_request, changes_text: changes_text, jira_issue: jira_issue)
      }
    end

    def build_critique_prompt(merge_request:, changes_text:, candidates_json:, jira_issue: nil)
      user = +"#{user_prompt(merge_request: merge_request, changes_text: changes_text, jira_issue: jira_issue)}\n\n"
      user << "Candidates JSON from Generate:\n#{scrub_text(candidates_json)}"

      {
        system_prompt: system_prompt(CRITIQUE_PROMPT_TEMPLATE),
        user_prompt: user
      }
    end

    private

    def system_prompt(template)
      extras = []
      if Aireview::Utils.present?(@config.review_instructions)
        extras << "Дополнительные инструкции проекта:\n#{scrub_text(@config.review_instructions.strip)}"
      end
      extras << "Язык ответа: #{language_name(@config.review_language)}."

      [template, *extras].join("\n\n")
    end

    def user_prompt(merge_request:, changes_text:, jira_issue:)
      truncated_changes = truncate_changes(scrub_text(changes_text))

      sections = []
      sections << "MR: #{scrub_text(merge_request['title'])}"
      sections << "Author: #{scrub_text(merge_request.dig('author', 'name'))}"
      sections << "Branch: #{scrub_text(merge_request['source_branch'])} -> #{scrub_text(merge_request['target_branch'])}"
      sections << "Description:\n#{scrub_optional_text(merge_request['description'])}"

      if jira_issue
        jira_section = +"Jira task (#{scrub_text(jira_issue['key'])}):\n"
        jira_section << "Summary: #{scrub_text(jira_issue['summary'])}\n"
        jira_section << "Description:\n#{scrub_optional_text(jira_issue['description'])}"

        if jira_issue['comments'] && !jira_issue['comments'].empty?
          jira_section << "\nRecent comments:\n#{jira_issue['comments'].map { |comment| scrub_text(comment) }.join("\n")}"
        end

        sections << jira_section
      end

      sections << "Changes:\n#{truncated_changes}"
      sections.join("\n\n")
    end

    def truncate_changes(changes_text)
      text = changes_text.to_s
      return text if text.length <= MAX_DIFF_CHARS

      omitted = text.length - MAX_DIFF_CHARS
      "#{text[0, MAX_DIFF_CHARS]}\n\n[TRUNCATED #{omitted} chars]"
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
