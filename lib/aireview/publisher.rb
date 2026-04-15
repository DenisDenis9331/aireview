module Aireview
  class Publisher
    PREFIX = '**aireview review**'.freeze

    def initialize(gitlab_client:, logger: Logger.new($stderr))
      @gitlab_client = gitlab_client
      @logger = logger
    end

    def publish(project_id:, iid:, review_body:)
      body = "#{PREFIX}\n\n#{review_body}"
      @gitlab_client.post_merge_request_note(project_id, iid, body)
    end
  end
end
