# frozen_string_literal: true
require 'json'

module Aireview
  # The --dry-run output: settings, the context summary and the prompts of both stages.
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
      render_critique_prompt(dry_run[:critique_prompt]) if dry_run[:critique_prompt]
      render_jev_request(dry_run[:jev_critique]) if dry_run[:jev_critique]
    end

    private

    def render_critique_prompt(prompt)
      @out.puts
      @out.puts('=== CRITIQUE SYSTEM PROMPT ===')
      @out.puts(prompt[:system_prompt])
      @out.puts
      @out.puts('=== CRITIQUE USER PROMPT ===')
      @out.puts(prompt[:user_prompt])
    end

    # The request Jev would get for the stub candidate.
    def render_jev_request(jev)
      @out.puts
      @out.puts('=== JEV STATE ===')
      @out.puts(JSON.pretty_generate(jev[:state]))
      @out.puts
      @out.puts('=== JEV QUESTIONS ===')
      @out.puts(JSON.pretty_generate(jev[:questions]))
    end

    # With Jev as the engine the LLM Critique line is its fallback.
    def render_settings(dry_run)
      @out.puts('=== LLM SETTINGS ===')
      render_config_paths(dry_run[:config_paths])
      render_stage(dry_run, :generate)
      render_jev_critique(dry_run[:jev_critique])
      if dry_run[:critique_prompt]
        render_stage(dry_run, :critique, title: dry_run[:jev_critique] ? 'Critique fallback' : 'Critique')
      elsif !dry_run[:jev_critique]
        @out.puts('Critique: disabled')
      end
      @out.puts("Critique rule: #{dry_run[:critique_rule]}") if dry_run[:critique_rule]
      render_jev_shadow(dry_run[:jev_shadow])
      render_reserves(dry_run)
      list('warnings', dry_run[:warnings], separator: "\n  ")
    end

    def render_jev_critique(jev)
      return unless jev

      thresholds = jev[:thresholds].map { |name, value| "#{name}=#{value}" }.join(' ')
      @out.puts("Critique: jev #{jev[:model]} (key #{jev[:key] ? 'set' : 'missing'}; " \
                "fallback: #{jev[:fallback]}; #{thresholds})")
    end

    def render_jev_shadow(jev)
      return unless jev

      thresholds = jev[:thresholds].map { |name, value| "#{name}=#{value}" }.join(' ')
      @out.puts("Jev shadow: #{jev[:model]} (key #{jev[:key] ? 'set' : 'missing'}; log only, #{thresholds})")
    end

    def render_config_paths(paths)
      return if paths.nil? || paths.empty?

      @out.puts("Config: #{paths.map { |name, path| "#{name} #{path}" }.join(', ')}")
    end

    # The source of every setting is the layer it came from: built-in, image
    # defaults, .aireview.yml, env or cli.
    def render_stage(dry_run, stage, title: stage.capitalize)
      sources = dry_run.dig(:sources, stage) || {}
      @out.puts("#{title}: #{dry_run[:"#{stage}_model"]} " \
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
      return if coverage.files_not_returned.zero?

      @out.puts("  files not returned by the platform: #{coverage.files_not_returned}")
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
