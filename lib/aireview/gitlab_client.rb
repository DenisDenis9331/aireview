# frozen_string_literal: true
require 'json'
require_relative 'utils'

module Aireview
  class GitlabClient
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    NOTES_PER_PAGE = 100
    NOTES_PAGE_LIMIT = 100
    JOBS_PER_PAGE = 100
    JOBS_PAGE_LIMIT = 100

    def initialize(base_url:, token:, logger: Logger.new($stderr), connection: nil)
      require 'faraday'

      raise ConfigError, 'GitLab base URL is required' if Aireview::Utils.blank?(base_url)
      raise ConfigError, 'GitLab token is required' if Aireview::Utils.blank?(token)

      @logger = logger
      @token = token
      @connection = connection || build_connection(base_url)
    end

    def fetch_merge_request(project_id, iid)
      get_json("projects/#{project_id}/merge_requests/#{iid}")
    end

    def fetch_merge_request_changes(project_id, iid)
      payload = get_json("projects/#{project_id}/merge_requests/#{iid}/changes")
      Array(payload['changes'])
    end

    def fetch_current_user
      get_json('user')
    end

    # Retry создаёт новый job в том же pipeline. Старые попытки видны только
    # с include_retried; один лишь новый CI_JOB_ID бывает и после обычного push.
    def retried_job?(project_id, job_id)
      current = get_json("projects/#{project_id}/jobs/#{job_id}")
      validate_retry_job!(current, pipeline: true)
      path = "projects/#{project_id}/pipelines/#{current.fetch('pipeline').fetch('id')}/jobs"

      (1..JOBS_PAGE_LIMIT).each do |page|
        jobs = get_json(path, include_retried: true, per_page: JOBS_PER_PAGE, page: page)
        raise ApiError, 'GitLab Jobs API returned an invalid jobs list' unless jobs.is_a?(Array)

        jobs.each { |job| validate_retry_job!(job) }
        return true if jobs.any? { |job| previous_attempt?(job, current) }
        return false if jobs.size < JOBS_PER_PAGE
      end

      raise ApiError, 'Too many pipeline jobs to determine whether this job is a retry'
    end

    # Заметки отдаются страницами и сортируются по времени создания, а
    # обновление комментария в этом порядке его не поднимает: на длинном MR
    # своё ревью оказывается далеко не на первой странице. Обрывать обход молча
    # нельзя — по неполному списку ревью решит, что заметки нет, и создаст
    # вторую, поэтому упираемся в предел с ошибкой. Порядок задаётся явно: от
    # него зависит, какую из старых заметок без метки подхватит ревью, и
    # полагаться тут на дефолт API не стоит.
    def fetch_merge_request_notes(project_id, iid)
      notes = []
      page = 1

      loop do
        batch = Array(
          get_json(
            "projects/#{project_id}/merge_requests/#{iid}/notes",
            order_by: 'created_at', sort: 'desc', per_page: NOTES_PER_PAGE, page: page
          )
        )
        notes.concat(batch)
        break if batch.size < NOTES_PER_PAGE

        page += 1
        next unless page > NOTES_PAGE_LIMIT

        raise ApiError, "Merge request has more than #{NOTES_PAGE_LIMIT * NOTES_PER_PAGE} notes"
      end

      notes
    end

    def post_merge_request_note(project_id, iid, body)
      post_json("projects/#{project_id}/merge_requests/#{iid}/notes", body: body)
    end

    def update_merge_request_note(project_id, iid, note_id, body)
      put_json("projects/#{project_id}/merge_requests/#{iid}/notes/#{note_id}", body: body)
    end

    private

    def validate_retry_job!(job, pipeline: false)
      fields = {'id' => Integer, 'name' => String, 'stage' => String}
      valid = job.is_a?(Hash) && fields.all? { |key, type| job[key].is_a?(type) }
      if valid && pipeline
        data = job['pipeline']
        valid = data.is_a?(Hash) && data['id'].is_a?(Integer)
      end
      raise ApiError, 'GitLab Jobs API returned an invalid job payload' unless valid
    end

    def previous_attempt?(job, current)
      job.fetch('id') < current.fetch('id') &&
        job['name'] == current.fetch('name') && job['stage'] == current.fetch('stage')
    end

    def build_connection(base_url)
      Faraday.new(url: "#{base_url}/api/v4/") do |builder|
        builder.request :json
        builder.options.open_timeout = OPEN_TIMEOUT
        builder.options.timeout = READ_TIMEOUT
        builder.adapter Faraday.default_adapter
      end
    end

    def get_json(path, params = {})
      response = @connection.get(path, params, headers)
      parse_json(response)
    rescue Faraday::Error => e
      raise ApiError, "GitLab API request failed: #{e.message}"
    end

    def post_json(path, body)
      response = @connection.post(path) do |request|
        request.headers.update(headers)
        request.body = JSON.generate(body)
      end
      parse_json(response)
    rescue Faraday::Error => e
      raise ApiError, "GitLab API request failed: #{e.message}"
    end

    def put_json(path, body)
      response = @connection.put(path) do |request|
        request.headers.update(headers)
        request.body = JSON.generate(body)
      end
      parse_json(response)
    rescue Faraday::Error => e
      raise ApiError, "GitLab API request failed: #{e.message}"
    end

    def parse_json(response)
      status = response.status.to_i
      body = response.body.to_s

      return JSON.parse(body) if status.between?(200, 299)

      raise ApiError, "GitLab API error #{status}: #{body}"
    rescue JSON::ParserError
      raise ApiError, "GitLab API returned invalid JSON: #{body}"
    end

    def headers
      {
        'Content-Type' => 'application/json',
        'PRIVATE-TOKEN' => @token
      }
    end
  end
end
