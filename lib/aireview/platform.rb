# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'
require_relative 'gitlab_client'
require_relative 'github_client'

module Aireview
  # The only place that knows which platform a review target belongs to:
  # which client to build, how to tell a CI retry from a new push and how to
  # name the target in messages. No requests and no response handling here —
  # those live in the clients.
  module Platform
    PLATFORMS = %i[gitlab github].freeze

    module_function

    def client(config:, target:, logger:)
      case platform(target)
      when :gitlab
        GitlabClient.new(
          base_url: config.gitlab_url || target.base_url,
          token: config.require_gitlab_token!,
          logger: logger
        )
      when :github
        GithubClient.new(
          api_url: config.github_api_url || GithubClient.api_url_for(target.base_url),
          token: config.require_github_token!,
          review_author: config.github_review_author,
          logger: logger
        )
      end
    end

    # A Retry of the GitLab job, not a new pipeline: see
    # GitlabClient#retried_job?. GitHub numbers the attempts of a workflow
    # run itself: "Re-run jobs" makes attempt 2. Outside CI nothing is a retry.
    def retried_run?(client:, target:, env:)
      case platform(target)
      when :gitlab
        project_id, job_id = gitlab_job(env)
        project_id ? client.retried_job?(project_id, job_id) : false
      when :github
        github_actions?(env) && env['GITHUB_RUN_ATTEMPT'].to_i > 1
      end
    end

    def update_hint(target:, env:)
      case platform(target)
      when :gitlab
        gitlab_job(env) ? 'retry the job to update' : 'use --force to review again'
      when :github
        github_actions?(env) ? 're-run the workflow to update' : 'use --force to review again'
      end
    end

    def label(target)
      case platform(target)
      when :gitlab then "MR #{target.project_path}!#{target.iid}"
      when :github then "PR #{target.project_path}##{target.iid}"
      end
    end

    def name(target)
      case platform(target)
      when :gitlab then 'GitLab'
      when :github then 'GitHub'
      end
    end

    def noun(target)
      case platform(target)
      when :gitlab then 'merge request'
      when :github then 'pull request'
      end
    end

    def platform(target)
      platform = target.platform
      raise ArgumentError, "Unsupported platform: #{platform.inspect}" unless PLATFORMS.include?(platform)

      platform
    end
    private_class_method :platform

    def gitlab_job(env)
      project_id, job_id = env.values_at('CI_PROJECT_ID', 'CI_JOB_ID')
      return if Aireview::Utils.blank?(project_id) || Aireview::Utils.blank?(job_id)

      [project_id, job_id]
    end
    private_class_method :gitlab_job

    def github_actions?(env)
      env['GITHUB_ACTIONS'] == 'true'
    end
    private_class_method :github_actions?
  end
end
