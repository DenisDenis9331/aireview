require 'uri'

module Aireview
  class MrParser
    Result = Struct.new(:url, :base_url, :project_path, :project_id, :iid, keyword_init: true)

    MR_PATH = %r{\A/(?<project>.+)/-/merge_requests/(?<iid>\d+)\z}.freeze

    def self.parse(url)
      uri = URI.parse(url.to_s)
      raise ParseError, 'Merge request URL must include http:// or https://' unless uri.is_a?(URI::HTTP)

      match = MR_PATH.match(uri.path)
      raise ParseError, "Unsupported merge request URL: #{url}" unless match

      project_path = match[:project]

      Result.new(
        url: url,
        base_url: "#{uri.scheme}://#{uri.host}#{uri.port && ![80, 443].include?(uri.port) ? ":#{uri.port}" : nil}",
        project_path: project_path,
        project_id: URI.encode_www_form_component(project_path),
        iid: match[:iid].to_i
      )
    rescue URI::InvalidURIError => e
      raise ParseError, "Invalid merge request URL: #{e.message}"
    end
  end
end
