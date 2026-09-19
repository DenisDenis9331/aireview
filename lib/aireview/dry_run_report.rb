# frozen_string_literal: true

module Aireview
  # Вывод --dry-run: настройки, сводка контекста и промпты обеих стадий.
  class DryRunReport
    def initialize(out)
      @out = out
    end

    def render(dry_run)
      render_settings(dry_run)
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

    def render_settings(dry_run)
      @out.puts('=== LLM SETTINGS ===')
      render_config_paths(dry_run[:config_paths])
      render_stage(dry_run, :generate)
      if dry_run[:critique_prompt]
        render_stage(dry_run, :critique)
      else
        @out.puts('Critique: disabled')
      end
      @out.puts("Critique rule: #{dry_run[:critique_rule]}") if dry_run[:critique_rule]
      render_reserves(dry_run)
      list('warnings', dry_run[:warnings], separator: "\n  ")
    end

    def render_config_paths(paths)
      return if paths.nil? || paths.empty?

      @out.puts("Config: #{paths.map { |name, path| "#{name} #{path}" }.join(', ')}")
    end

    # Источник каждой настройки — слой, откуда она пришла: built-in, image
    # defaults, .aireview.yml, env или cli.
    def render_stage(dry_run, stage)
      sources = dry_run.dig(:sources, stage) || {}
      @out.puts("#{stage.capitalize}: #{dry_run[:"#{stage}_model"]} " \
                "temperature=#{dry_run[:"#{stage}_temperature"]}#{origin(sources, :model, :provider)}")
      fallbacks = dry_run[:"#{stage}_fallbacks"]
      list('fallbacks', fallbacks, separator: ' -> ', suffix: origin(sources, :fallbacks))
    end

    def origin(sources, *keys)
      parts = keys.filter_map { |key| "#{key} from #{sources[key]}" if sources[key] }
      parts.empty? ? '' : " (#{parts.join(', ')})"
    end

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

    def render_reserves(dry_run)
      keys = Array(dry_run[:api_keys]).map { |provider, count| "#{provider} #{count}" }
      @out.puts("API keys: #{keys.join(', ')}") unless keys.empty?
      return unless dry_run[:time_budget]

      quarantine = dry_run[:overloaded_quarantine]
      @out.puts("Time budget: #{dry_run[:time_budget]}s#{", overloaded quarantine: #{quarantine}s" if quarantine}")
    end

    def list(title, items, separator: ', ', suffix: '')
      items = Array(items)
      @out.puts("  #{title}: #{items.join(separator)}#{suffix}") unless items.empty?
    end
  end
end
