require 'securerandom'

module Aireview
  class CLI
    def self.start(argv, out: $stdout, err: $stderr)
      new(argv, out: out, err: err).start
    end

    def initialize(argv, out:, err:)
      @argv = argv.dup
      @out = out
      @err = err
      @run_id = SecureRandom.hex(4)
      @logger = Logger.new(err)
      @logger.level = Logger::INFO
      @logger.formatter = proc { |severity, _, _, message| "[#{severity.downcase}] [run=#{@run_id}] #{message}\n" }
    end

    def start
      command = @argv.shift

      case command
      when 'review'
        run_review(@argv)
      when '--help', '-h', nil
        @out.puts(help)
        0
      else
        @err.puts("Unknown command: #{command}")
        @err.puts(help)
        1
      end
    rescue Aireview::HelpRequested
      0
    rescue Aireview::Error => e
      @err.puts("Error: #{e.message}")
      1
    end

    private

    def run_review(argv)
      options = parse_review_options(argv)
      @logger.level = Logger::DEBUG if options[:verbose]

      mr_url = argv.shift
      raise ParseError, 'Merge request URL is required' unless mr_url
      raise ParseError, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      @logger.info("Starting review command for #{mr_url}")

      parser_result = MrParser.parse(mr_url)
      config = Config.load(config_path: options[:config], cwd: Dir.pwd, env: ENV, logger: @logger)
      config = config.with_overrides(
        generate_model: options[:generate_model],
        critique_model: options[:critique_model],
        generate_temperature: options[:generate_temperature],
        critique_temperature: options[:critique_temperature]
      )
      config.require_llm_configuration!

      gitlab_client = GitlabClient.new(
        base_url: config.gitlab_url || parser_result.base_url,
        token: config.require_gitlab_token!,
        logger: @logger
      )

      @logger.info("Loading MR #{parser_result.project_path}!#{parser_result.iid}")
      merge_request = gitlab_client.fetch_merge_request(parser_result.project_id, parser_result.iid)
      changes = gitlab_client.fetch_merge_request_changes(parser_result.project_id, parser_result.iid)

      diff_fetcher = DiffFetcher.new(ignore_paths: config.ignore_paths, logger: @logger)
      filtered_changes = diff_fetcher.filter(changes)
      raise Error, 'No changes left after filtering ignore_paths' if filtered_changes.empty?

      scrubbed_changes = SecretScrubber.new(
        secret_patterns: config.secret_patterns,
        secret_files: config.secret_files,
        logger: @logger
      ).scrub_changes(filtered_changes)

      rendered_changes = diff_fetcher.render(scrubbed_changes)
      jira_issue = maybe_load_jira_issue(config, merge_request, options)

      pipeline = ReviewPipeline.new(config: config, logger: @logger)

      if options[:dry_run]
        dry_run = pipeline.dry_run_prompts(
          merge_request: merge_request,
          changes_text: rendered_changes,
          jira_issue: jira_issue,
          critique: !options[:no_critique]
        )
        render_dry_run(dry_run)
        return 0
      end

      review = pipeline.run(
        merge_request: merge_request,
        changes_text: rendered_changes,
        jira_issue: jira_issue,
        critique: !options[:no_critique]
      )

      if options[:post]
        Publisher.new(gitlab_client: gitlab_client, logger: @logger).publish(
          project_id: parser_result.project_id,
          iid: parser_result.iid,
          review_body: review
        )
      end

      @out.puts(review)
      0
    end

    def maybe_load_jira_issue(config, merge_request, options)
      return nil if options[:no_jira]

      key = JiraClient.extract_issue_key([merge_request['title'], merge_request['description']].compact.join("\n"))
      return nil unless key
      return nil unless config.jira_configured?

      @logger.info("Loading Jira issue #{key}")
      JiraClient.new(
        base_url: config.jira_url,
        email: config.jira_email,
        token: config.jira_token,
        logger: @logger
      ).fetch_issue(key)
    rescue Aireview::Error => e
      @logger.warn("Jira lookup skipped: #{e.message}")
      nil
    end

    def parse_review_options(argv)
      options = {
        post: false,
        no_jira: false,
        dry_run: false,
        verbose: false,
        no_critique: false
      }

      OptionParser.new do |parser|
        parser.banner = 'Usage: aireview review <merge_request_url> [options]'

        parser.on('--post', 'Post review back to GitLab merge request') do
          options[:post] = true
        end

        parser.on('--generate-model MODEL', 'Override Generate pass model') do |value|
          options[:generate_model] = value
        end

        parser.on('--critique-model MODEL', 'Override Critique pass model') do |value|
          options[:critique_model] = value
        end

        parser.on('--generate-temperature VALUE', Float, 'Override Generate pass temperature') do |value|
          options[:generate_temperature] = value
        end

        parser.on('--critique-temperature VALUE', Float, 'Override Critique pass temperature') do |value|
          options[:critique_temperature] = value
        end

        parser.on('--config PATH', 'Path to .aireview.yml') do |value|
          options[:config] = value
        end

        parser.on('--no-jira', 'Disable Jira enrichment') do
          options[:no_jira] = true
        end

        parser.on('--dry-run', 'Print prompts and skip LLM calls') do
          options[:dry_run] = true
        end

        parser.on('--no-critique', 'Skip critique pass and render Generate candidates directly') do
          options[:no_critique] = true
        end

        parser.on('--verbose', 'Enable verbose logging') do
          options[:verbose] = true
        end

        parser.on('-h', '--help', 'Show help') do
          @out.puts(parser)
          raise HelpRequested
        end
      end.parse!(argv)

      options
    end

    def render_dry_run(dry_run)
      @out.puts('=== LLM SETTINGS ===')
      @out.puts("Generate: #{dry_run[:generate_model]} temperature=#{dry_run[:generate_temperature]}")
      if dry_run[:critique_prompt]
        @out.puts("Critique: #{dry_run[:critique_model]} temperature=#{dry_run[:critique_temperature]}")
      else
        @out.puts('Critique: disabled')
      end
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

    def help
      <<~HELP
        Usage:
          aireview review <merge_request_url> [options]

        Commands:
          review    Run review for a GitLab merge request URL

        Options:
          --post           Post review as a merge request note
          --generate-model MODEL
                           Override Generate pass model
          --critique-model MODEL
                           Override Critique pass model
          --generate-temperature VALUE
                           Override Generate pass temperature
          --critique-temperature VALUE
                           Override Critique pass temperature
          --config PATH    Path to .aireview.yml
          --no-jira        Disable Jira enrichment
          --dry-run        Print prompts without LLM calls
          --no-critique    Skip second LLM critique pass
          --verbose        Enable verbose logging
          -h, --help       Show help
      HELP
    end
  end
end
