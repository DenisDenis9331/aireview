require 'base64'
require 'json'
require_relative 'utils'

module Aireview
  class JiraClient
    ISSUE_KEY = /\b([A-Z][A-Z0-9]+-\d+)\b/.freeze
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def self.extract_issue_key(text)
      match = ISSUE_KEY.match(text.to_s)
      match && match[1]
    end

    def initialize(base_url:, email:, token:, logger: Logger.new($stderr))
      require 'faraday'

      raise ConfigError, 'Jira base URL is required' if Aireview::Utils.blank?(base_url)
      raise ConfigError, 'Jira email is required' if Aireview::Utils.blank?(email)
      raise ConfigError, 'Jira token is required' if Aireview::Utils.blank?(token)

      @logger = logger
      @connection = Faraday.new(url: base_url) do |builder|
        builder.request :json
        builder.options.open_timeout = OPEN_TIMEOUT
        builder.options.timeout = READ_TIMEOUT
        builder.adapter Faraday.default_adapter
      end
      @authorization = "Basic #{Base64.strict_encode64("#{email}:#{token}")}"
    end

    def fetch_issue(key)
      payload = get_json("/rest/api/2/issue/#{key}", fields: 'summary,description,comment')

      {
        'key' => payload['key'],
        'summary' => payload.dig('fields', 'summary'),
        'description' => plain_text(payload.dig('fields', 'description')),
        'comments' => extract_comments(payload.dig('fields', 'comment', 'comments'))
      }
    end

    private

    def get_json(path, params = {})
      response = @connection.get(path, params, headers)
      body = response.body.to_s
      status = response.status.to_i

      return JSON.parse(body) if status.between?(200, 299)

      raise ApiError, "Jira API error #{status}: #{body}"
    rescue Faraday::Error => e
      raise ApiError, "Jira API request failed: #{e.message}"
    rescue JSON::ParserError
      raise ApiError, "Jira API returned invalid JSON: #{body}"
    end

    def headers
      {
        'Accept' => 'application/json',
        'Authorization' => @authorization
      }
    end

    def extract_comments(comments)
      Array(comments).last(3).map do |comment|
        author = comment.dig('author', 'displayName') || 'Unknown'
        body = plain_text(comment['body'])
        "#{author}: #{body}".strip
      end.reject(&:empty?)
    end

    def plain_text(value)
      case value
      when String
        value
      when Array
        value.map { |item| plain_text(item) }.join("\n")
      when Hash
        hash_to_text(value)
      else
        value.to_s
      end
    end

    def hash_to_text(value)
      if value['type'] == 'text'
        value['text'].to_s
      elsif value.key?('content')
        value['content'].map { |item| plain_text(item) }.reject(&:empty?).join("\n")
      else
        value.values.map { |item| plain_text(item) }.reject(&:empty?).join("\n")
      end
    end
  end
end
