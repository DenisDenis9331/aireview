# frozen_string_literal: true

require 'aireview'

class FakeGitlabClient
  attr_reader :created, :updated

  def initialize(notes: [], user: {'id' => 7}, user_error: nil)
    @notes = notes
    @user = user
    @user_error = user_error
    @created = []
    @updated = []
  end

  def fetch_current_user
    raise @user_error if @user_error

    @user
  end

  def fetch_merge_request_notes(_project_id, _iid)
    @notes
  end

  def post_merge_request_note(project_id, iid, body)
    @created << [project_id, iid, body]
  end

  def update_merge_request_note(project_id, iid, note_id, body)
    @updated << [project_id, iid, note_id, body]
  end
end

RSpec.describe Aireview::Publisher do
  def note(id:, body:, author_id: 7, system: false)
    {'id' => id, 'body' => body, 'system' => system, 'author' => {'id' => author_id}}
  end

  let(:logger) { Logger.new(File::NULL) }

  describe '#existing_review' do
    it 'finds its own note by marker' do
      client = FakeGitlabClient.new(
        notes: [
          note(id: 1, body: 'looks good to me'),
          note(id: 2, body: "#{Aireview::ReviewMarker.build('deadbeef')}\nreview")
        ]
      )

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to eq(id: 2, key: 'deadbeef')
    end

    # Клиент запрашивает заметки от новых к старым, поэтому первая подходящая в
    # списке — самое свежее ревью.
    it 'adopts the newest legacy review with an unknown key when no marker exists' do
      client = FakeGitlabClient.new(
        notes: [note(id: 3, body: "#{described_class::PREFIX}\n\nlatest review"),
                note(id: 2, body: "#{described_class::PREFIX}\n\nolder review"),
                note(id: 1, body: "#{described_class::PREFIX}\n\noldest review")]
      )

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to eq(id: 3, key: nil)
    end

    [false, true].each do |legacy_first|
      it "prefers a marked review regardless of note order (legacy_first=#{legacy_first})" do
        notes = [note(id: 2, body: Aireview::ReviewMarker.build('deadbeef')),
                 note(id: 3, body: "#{described_class::PREFIX}\n\nlegacy review")]
        notes.reverse! if legacy_first
        client = FakeGitlabClient.new(notes: notes)

        result = described_class.new(gitlab_client: client, logger: logger)
                                .existing_review(project_id: 'group/project', iid: 5)

        expect(result).to eq(id: 2, key: 'deadbeef')
      end
    end

    it 'ignores legacy prefixes in foreign notes, system notes, and quoted text' do
      body = "#{described_class::PREFIX}\n\nlegacy review"
      client = FakeGitlabClient.new(
        notes: [note(id: 1, body: body, author_id: 99),
                note(id: 2, body: body, system: true),
                note(id: 3, body: "> #{body}"),
                note(id: 4, body: "A quote: #{body}")]
      )

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to be_nil
    end

    it 'ignores a marker quoted by another author' do
      client = FakeGitlabClient.new(
        notes: [note(id: 3, body: Aireview::ReviewMarker.build('deadbeef'), author_id: 99)]
      )

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to be_nil
    end

    it 'ignores system notes' do
      client = FakeGitlabClient.new(
        notes: [note(id: 4, body: Aireview::ReviewMarker.build('deadbeef'), system: true)]
      )

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to be_nil
    end

    it 'fails instead of matching by marker alone when the author is unknown' do
      client = FakeGitlabClient.new(
        notes: [note(id: 5, body: Aireview::ReviewMarker.build('deadbeef'), author_id: 99)],
        user_error: Aireview::ApiError.new('GitLab API request failed: timeout')
      )

      expect do
        described_class.new(gitlab_client: client, logger: logger)
                       .existing_review(project_id: 'group/project', iid: 5)
      end.to raise_error(Aireview::ApiError)
    end

    it 'returns nil when there are no notes at all' do
      client = FakeGitlabClient.new

      result = described_class.new(gitlab_client: client, logger: logger)
                              .existing_review(project_id: 'group/project', iid: 5)

      expect(result).to be_nil
    end
  end

  describe '#publish' do
    it 'creates a note with the marker when no review exists yet' do
      client = FakeGitlabClient.new

      described_class.new(gitlab_client: client, logger: logger).publish(
        project_id: 'group/project', iid: 5, review_body: 'review text', key: 'deadbeef'
      )

      expect(client.updated).to be_empty
      expect(client.created.first[2]).to eq(
        "<!-- aireview:key=deadbeef -->\n**aireview review**\n\nreview text"
      )
    end

    it 'updates the existing note instead of adding a second one' do
      client = FakeGitlabClient.new

      described_class.new(gitlab_client: client, logger: logger).publish(
        project_id: 'group/project', iid: 5, review_body: 'fresh review',
        key: 'cafebabe', existing: {id: 2, key: 'deadbeef'}
      )

      expect(client.created).to be_empty
      expect(client.updated.first[2]).to eq(2)
      expect(client.updated.first[3]).to include('<!-- aireview:key=cafebabe -->', 'fresh review')
    end

    it 'keeps working without a key' do
      client = FakeGitlabClient.new

      described_class.new(gitlab_client: client, logger: logger).publish(
        project_id: 'group/project', iid: 5, review_body: 'review text'
      )

      expect(client.created.first[2]).to eq("**aireview review**\n\nreview text")
    end
  end
end
