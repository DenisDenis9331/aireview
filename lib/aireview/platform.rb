# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'
require_relative 'gitlab_client'

module Aireview
  # The only place that knows which platform a review target belongs to:
  # which client to build, how to tell a CI retry from a new push and how to
  # name the target in messages. No requests and no response handling here —
  # those live in the clients.
  module Platform
    module_function

    def client(config:, target:, logger:)
      case platform(target)
      when :gitlab
        GitlabClient.new(
          base_url: config.gitlab_url || target.base_url,
          token: config.require_gitlab_token!,
          logger: logger
        )
      end
    end

    # A Retry of the GitLab job, not a new pipeline: see
    # GitlabClient#retried_job?. Outside GitLab CI nothing is a retry.
    def retried_run?(client:, target:, env:)
      case platform(target)
      when :gitlab
        project_id, job_id = gitlab_job(env)
        project_id ? client.retried_job?(project_id, job_id) : false
      end
    end

    def update_hint(target:, env:)
      case platform(target)
      when :gitlab
        gitlab_job(env) ? 'retry the job to update' : 'use --force to review again'
      end
    end

    def label(target)
      case platform(target)
      when :gitlab then "MR #{target.project_path}!#{target.iid}"
      end
    end

    def name(target)
      case platform(target)
      when :gitlab then 'GitLab'
      end
    end

    def platform(target)
      platform = target.platform
      raise ArgumentError, "Unsupported platform: #{platform.inspect}" unless platform == :gitlab

      platform
    end
    private_class_method :platform

    def gitlab_job(env)
      project_id, job_id = env.values_at('CI_PROJECT_ID', 'CI_JOB_ID')
      return if Aireview::Utils.blank?(project_id) || Aireview::Utils.blank?(job_id)

      [project_id, job_id]
    end
    private_class_method :gitlab_job
  end
end
