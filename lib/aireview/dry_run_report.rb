# frozen_string_literal: true

module Aireview
  # Вывод --dry-run: настройки, сводка контекста и промпты обеих стадий.
  class DryRunReport
    def initialize(out)
      @out = out
    end

    def render(dry_run)
      @out.puts('=== LLM SETTINGS ===')
      @out.puts("Generate: #{dry_run[:generate_model]} temperature=#{dry_run[:generate_temperature]}")
      if dry_run[:critique_prompt]
        @out.puts("Critique: #{dry_run[:critique_model]} temperature=#{dry_run[:critique_temperature]}")
      else
        @out.puts('Critique: disabled')
      end
      @out.puts
      @out.puts('=== CONTEXT ===')
      render_context_sizes(dry_run[:sizes])
      render_coverage(dry_run[:coverage])
      @out.puts
      @out.puts('=== GENERATE SYSTEM PROMPT ===')
      @out.puts(dry_run.dig(:generate_prompt, :system_prompt))
      @out.puts
      @out.puts('=== GENERATE USER PROMPT ===')
      @out.puts(dry_run.dig(:generate_prompt, :user_prompt))
      return unless dry_run[:critique_prompt]

      @out.puts
      @out.puts('=== CRITIQUE SYSTEM PROMPT ===')
      @out.puts(dry_run.dig(:critique_prompt, :system_prompt))
      @out.puts
      @out.puts('=== CRITIQUE USER PROMPT ===')
      @out.puts(dry_run.dig(:critique_prompt, :user_prompt))
    end

    private

    def render_context_sizes(sizes)
      @out.puts("Sections: #{sizes[:sections]} chars, diff: #{sizes[:diff]} chars " \
                "(budget #{sizes[:diff_budget]}, hunks #{sizes[:hunks_shown]}/#{sizes[:hunks_total]})")
      sizes[:stages].each do |stage, stage_sizes|
        @out.puts("#{stage.capitalize} request: #{stage_sizes[:request]} chars " \
                  "(~#{stage_sizes[:request] / 4} tokens) of max #{stage_sizes[:max_prompt_chars]}, " \
                  "system prompt #{stage_sizes[:system_prompt]}")
      end
    end

    def render_coverage(coverage)
      return @out.puts('Coverage: complete') if coverage.complete?

      @out.puts('Coverage: partial')
      list('truncated sections', coverage.truncated_sections)
      list('files not shown', coverage.files_not_shown)
      coverage.files_partial.each { |file| @out.puts("  #{file[:path]}: #{file[:shown]} of #{file[:total]} hunks") }
      list('diff not available', coverage.files_unavailable)
    end

    def list(title, items)
      @out.puts("  #{title}: #{items.join(', ')}") unless items.empty?
    end
  end
end
