# frozen_string_literal: true
require 'securerandom'

module Aireview
  class CLI
    def self.start(argv, out: $stdout, err: $stderr, env: ENV)
      new(argv, out: out, err: err, env: env).start
    end

    def initialize(argv, out:, err:, env: ENV)
      @argv = argv.dup
      @env = env
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
      options, mr_url = review_options_and_url(argv)
      parser_result = MrParser.parse(mr_url)
      config = load_review_config(options)
      context = load_review_context(parser_result, config, options)

      execute_review(config, context, options)
    end

    def review_options_and_url(argv)
      options = parse_review_options(argv)
      @logger.level = Logger::DEBUG if options[:verbose]

      mr_url = argv.shift
      raise ParseError, 'Merge request URL is required' unless mr_url
      raise ParseError, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      @logger.info("Starting review command for #{mr_url}")
      [options, mr_url]
    end

    def load_review_config(options)
      config = Config.load(config_path: options[:config], cwd: Dir.pwd, env: @env, logger: @logger)
      config = config.with_overrides(
        generate_model: options[:generate_model],
        critique_model: options[:critique_model],
        generate_temperature: options[:generate_temperature],
        critique_temperature: options[:critique_temperature]
      )
      config.require_llm_configuration!
      config
    end

    def load_review_context(parser_result, config, options)
      gitlab_client = build_gitlab_client(config, parser_result)
      merge_request, changes = fetch_merge_request_data(gitlab_client, parser_result)

      {
        parser_result: parser_result,
        gitlab_client: gitlab_client,
        merge_request: merge_request,
        changes: prepare_changes(changes, config),
        jira_issue: maybe_load_jira_issue(config, merge_request, options)
      }
    end

    def build_gitlab_client(config, parser_result)
      GitlabClient.new(
        base_url: config.gitlab_url || parser_result.base_url,
        token: config.require_gitlab_token!,
        logger: @logger
      )
    end

    def fetch_merge_request_data(gitlab_client, parser_result)
      @logger.info("Loading MR #{parser_result.project_path}!#{parser_result.iid}")
      merge_request = gitlab_client.fetch_merge_request(parser_result.project_id, parser_result.iid)
      changes = gitlab_client.fetch_merge_request_changes(parser_result.project_id, parser_result.iid)
      [merge_request, changes]
    end

    # Дифф уходит дальше по файлам, а не одной строкой: бюджет контекста
    # режет его по границам файлов и хунков.
    def prepare_changes(changes, config)
      diff_fetcher = DiffFetcher.new(ignore_paths: config.ignore_paths, logger: @logger)
      filtered_changes = diff_fetcher.filter(changes)
      raise Error, 'No changes left after filtering ignore_paths' if filtered_changes.empty?

      SecretScrubber.new(
        secret_patterns: config.secret_patterns,
        secret_files: config.secret_files,
        logger: @logger
      ).scrub_changes(filtered_changes)
    end

    def execute_review(config, context, options)
      pipeline = ReviewPipeline.new(config: config, logger: @logger)

      if options[:dry_run]
        dry_run = pipeline.dry_run_prompts(
          merge_request: context[:merge_request],
          changes: context[:changes],
          jira_issue: context[:jira_issue],
          critique: !options[:no_critique]
        )
        render_dry_run(dry_run)
        return 0
      end

      publication = prepare_publication(pipeline, config, context, options)
      return 0 if publication == :skip

      review = pipeline.run(
        merge_request: context[:merge_request],
        changes: context[:changes],
        jira_issue: context[:jira_issue],
        critique: !options[:no_critique]
      )

      # Печатаем до публикации: если публикация не состоится, текст ревью
      # останется хотя бы в логе джоба.
      @out.puts(review)

      publish_review(review, context, publication) if publication

      0
    end

    # Поиск прошлого ревью идёт до вызова LLM: иначе запросы тратятся впустую,
    # даже когда публиковать нечего.
    def prepare_publication(pipeline, config, context, options)
      return nil unless options[:post]

      publisher = Publisher.new(gitlab_client: context[:gitlab_client], logger: @logger)
      prompts = pipeline.dry_run_prompts(
        merge_request: context[:merge_request],
        changes: context[:changes],
        jira_issue: context[:jira_issue],
        critique: !options[:no_critique]
      )
      key = ReviewMarker.key(prompts: prompts, config: config)
      existing = publisher.existing_review(
        project_id: context[:parser_result].project_id,
        iid: context[:parser_result].iid
      )

      mode = options[:review_mode] || config.review_mode
      return :skip if skip_review?(existing, key: key, mode: mode, force: options[:force],
                                             gitlab_client: context[:gitlab_client])

      {publisher: publisher, existing: existing, key: key}
    end

    def skip_review?(existing, key:, mode:, force:, gitlab_client:)
      return false if existing.nil? || force

      up_to_date = existing[:key] == key
      return false unless up_to_date || (mode == 'once' && !retried_ci_job?(gitlab_client))

      reason = up_to_date ? 'existing review is up to date' : 'merge request already reviewed (review_mode=once)'
      @out.puts("Review skipped: #{reason}")
      true
    end

    def retried_ci_job?(gitlab_client)
      project_id, job_id = @env.values_at('CI_PROJECT_ID', 'CI_JOB_ID')
      return false if Aireview::Utils.blank?(project_id) || Aireview::Utils.blank?(job_id)

      gitlab_client.retried_job?(project_id, job_id)
    end

    def publish_review(review, context, publication)
      return if merge_request_moved?(context)

      publication[:publisher].publish(
        project_id: context[:parser_result].project_id,
        iid: context[:parser_result].iid,
        review_body: review,
        key: publication[:key],
        existing: publication[:existing]
      )
    end

    # Пока работала LLM, MR мог уехать: новый коммит, перебазирование или смена
    # целевой ветки. Публиковать ревью неактуального диффа хуже, чем не
    # публиковать ничего, а ошибку проверки нельзя трактовать как «всё на
    # месте», поэтому её не глушим.
    def merge_request_moved?(context)
      current = context[:gitlab_client].fetch_merge_request(
        context[:parser_result].project_id,
        context[:parser_result].iid
      )
      return false if ReviewMarker.state(current) == ReviewMarker.state(context[:merge_request])

      @logger.warn("Merge request moved to #{current['sha']} (#{current['target_branch']}) " \
                   'while review was running; skipping publication')
      true
    end

    def maybe_load_jira_issue(config, merge_request, options)
      return nil if options[:no_jira]

      key = JiraClient.extract_issue_key([merge_request['title'], merge_request['description']].compact.join("\n"))
      return nil unless key
      return nil unless config.jira_configured?

      @logger.info("Loading Jira issue #{key}")
      JiraClient.new(
        base_url: config.jira_url,
        login: config.jira_login,
        password: config.jira_password,
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
        no_critique: false,
        force: false
      }

      OptionParser.new do |parser|
        parser.banner = 'Usage: aireview review <merge_request_url> [options]'

        add_llm_options(parser, options)
        add_publication_options(parser, options)
        add_general_options(parser, options)
      end.parse!(argv)

      options
    end

    def add_llm_options(parser, options)
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

      parser.on('--no-critique', 'Skip critique pass and render Generate candidates directly') do
        options[:no_critique] = true
      end
    end

    def add_publication_options(parser, options)
      parser.on('--post', 'Post review back to GitLab merge request') do
        options[:post] = true
      end

      parser.on('--review-mode MODE', Aireview::Config::REVIEW_MODES,
                'How to treat an existing review: update or once') do |value|
        options[:review_mode] = value
      end

      parser.on('--force', 'Review again even if the merge request was already reviewed') do
        options[:force] = true
      end
    end

    def add_general_options(parser, options)
      parser.on('--config PATH', 'Path to .aireview.yml') do |value|
        options[:config] = value
      end

      parser.on('--no-jira', 'Disable Jira enrichment') do
        options[:no_jira] = true
      end

      parser.on('--dry-run', 'Print prompts and skip LLM calls') do
        options[:dry_run] = true
      end

      parser.on('--verbose', 'Enable verbose logging') do
        options[:verbose] = true
      end

      parser.on('-h', '--help', 'Show help') do
        @out.puts(parser)
        raise HelpRequested
      end
    end

    def render_dry_run(dry_run)
      DryRunReport.new(@out).render(dry_run)
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
          --review-mode MODE
                           How to treat an existing review: update (default) or once
          --force          Review again even if the merge request was already reviewed
          --no-jira        Disable Jira enrichment
          --dry-run        Print prompts without LLM calls
          --no-critique    Skip second LLM critique pass
          --verbose        Enable verbose logging
          -h, --help       Show help
      HELP
    end
  end
end
