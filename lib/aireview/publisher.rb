# frozen_string_literal: true
require_relative 'review_marker'

module Aireview
  class Publisher
    PREFIX = '**aireview review**'

    def initialize(gitlab_client:, logger: Logger.new($stderr))
      @gitlab_client = gitlab_client
      @logger = logger
    end

    # Собственная заметка с ревью: {id:, key:} или nil. Метки недостаточно —
    # её может процитировать кто угодно, поэтому сверяем ещё и автора. Старый
    # формат без метки подхватываем только если заметки с меткой нет.
    def existing_review(project_id:, iid:)
      author_id = current_user_id
      legacy = nil

      @gitlab_client.fetch_merge_request_notes(project_id, iid).each do |note|
        next if note['system']
        next if note.dig('author', 'id') != author_id

        key = ReviewMarker.extract(note['body'])
        return {id: note['id'], key: key} if key

        legacy ||= {id: note['id'], key: nil} if note['body'].to_s.start_with?(PREFIX)
      end

      legacy
    end

    def publish(project_id:, iid:, review_body:, key: nil, existing: nil)
      body = compose(review_body, key)

      if existing
        @logger.info("Updating review note #{existing[:id]}")
        @gitlab_client.update_merge_request_note(project_id, iid, existing[:id], body)
      else
        @gitlab_client.post_merge_request_note(project_id, iid, body)
      end
    end

    private

    def compose(review_body, key)
      return "#{PREFIX}\n\n#{review_body}" if Aireview::Utils.blank?(key)

      "#{ReviewMarker.build(key)}\n#{PREFIX}\n\n#{review_body}"
    end

    # Без надёжного автора матчинг по одной метке небезопасен: процитировать её
    # может кто угодно, и тогда чужая заметка либо отменит ревью, либо будет
    # перезаписана. Поэтому ошибку не глушим.
    def current_user_id
      return @current_user_id if defined?(@current_user_id)

      id = @gitlab_client.fetch_current_user['id']
      raise ApiError, 'GitLab did not return the current user id' if Aireview::Utils.blank?(id)

      @current_user_id = id
    end
  end
end
