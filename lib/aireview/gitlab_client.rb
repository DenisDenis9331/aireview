require 'json'
require_relative 'utils'

module Aireview
  class GitlabClient
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def initialize(base_url:, token:, logger: Logger.new($stderr))
      require 'faraday'

      raise ConfigError, 'GitLab base URL is required' if Aireview::Utils.blank?(base_url)
      raise ConfigError, 'GitLab token is required' if Aireview::Utils.blank?(token)

      @logger = logger
      @connection = Faraday.new(url: "#{base_url}/api/v4/") do |builder|
        builder.request :json
        builder.options.open_timeout = OPEN_TIMEOUT
        builder.options.timeout = READ_TIMEOUT
        builder.adapter Faraday.default_adapter
      end
      @token = token
    end

    def fetch_merge_request(project_id, iid)
      get_json("projects/#{project_id}/merge_requests/#{iid}")
    end

    def fetch_merge_request_changes(project_id, iid)
      payload = get_json("projects/#{project_id}/merge_requests/#{iid}/changes")
      Array(payload['changes'])
    end

    def post_merge_request_note(project_id, iid, body)
      post_json("projects/#{project_id}/merge_requests/#{iid}/notes", body: body)
    end

    private

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
