# frozen_string_literal: true

require 'faraday'
require 'json'
require 'aireview'

RSpec.describe Aireview::GitlabClient do
  def client_for(stubs)
    connection = Faraday.new do |builder|
      builder.request :json
      builder.adapter :test, stubs
    end

    described_class.new(
      base_url: 'https://gitlab.example.com',
      token: 'token',
      logger: Logger.new(File::NULL),
      connection: connection
    )
  end

  def notes_page(size, first_id)
    Array.new(size) { |index| {'id' => first_id + index, 'body' => 'note'} }
  end

  describe '#fetch_merge_request_notes' do
    it 'reads every page, not only the first one' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('projects/1/merge_requests/5/notes') do |env|
        page = env.params['page'].to_i
        body = page == 1 ? notes_page(Aireview::GitlabClient::NOTES_PER_PAGE, 1) : notes_page(3, 1000)
        [200, {'Content-Type' => 'application/json'}, JSON.generate(body)]
      end

      notes = client_for(stubs).fetch_merge_request_notes(1, 5)

      expect(notes.size).to eq(Aireview::GitlabClient::NOTES_PER_PAGE + 3)
      expect(notes.last['id']).to eq(1002)
    end

    it 'asks for the newest notes first instead of relying on the API default' do
      stubs = Faraday::Adapter::Test::Stubs.new
      captured = nil
      stubs.get('projects/1/merge_requests/5/notes') do |env|
        captured = env.params
        [200, {'Content-Type' => 'application/json'}, JSON.generate(notes_page(1, 1))]
      end

      client_for(stubs).fetch_merge_request_notes(1, 5)

      expect(captured).to include('order_by' => 'created_at', 'sort' => 'desc')
    end

    it 'raises instead of returning a truncated list' do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get('projects/1/merge_requests/5/notes') do
        [200, {'Content-Type' => 'application/json'},
         JSON.generate(notes_page(Aireview::GitlabClient::NOTES_PER_PAGE, 1))]
      end

      expect { client_for(stubs).fetch_merge_request_notes(1, 5) }
        .to raise_error(Aireview::ApiError, /more than/)
    end
  end

  describe '#update_merge_request_note' do
    it 'sends the new body with PUT' do
      stubs = Faraday::Adapter::Test::Stubs.new
      captured = nil
      stubs.put('projects/1/merge_requests/5/notes/42') do |env|
        captured = JSON.parse(env.body)
        [200, {'Content-Type' => 'application/json'}, JSON.generate('id' => 42)]
      end

      client_for(stubs).update_merge_request_note(1, 5, 42, 'updated review')

      expect(captured).to eq('body' => 'updated review')
    end
  end
  describe '#retried_job?' do
    let(:current) { {'id' => 200, 'name' => 'aireview', 'stage' => 'review', 'pipeline' => {'id' => 50}} }
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }

    before do
      stubs.get('projects/42/jobs/200') do
        [200, {'Content-Type' => 'application/json'}, JSON.generate(current)]
      end
    end

    def stub_jobs(stubs, jobs)
      stubs.get('projects/42/pipelines/50/jobs') do |env|
        expect(env.params['include_retried']).to eq('true')
        [200, {'Content-Type' => 'application/json'}, JSON.generate(jobs)]
      end
    end

    it 'recognizes an earlier attempt of the same job in its pipeline' do
      stub_jobs(stubs, [current, current.merge('id' => 100)])

      expect(client_for(stubs).retried_job?('42', '200')).to be(true)
      stubs.verify_stubbed_calls
    end

    it 'does not mistake other jobs or later attempts for a retry of the current job' do
      stub_jobs(stubs, [current, current.merge('id' => 201),
                        current.merge('id' => 100, 'name' => 'rspec'),
                        current.merge('id' => 101, 'stage' => 'other')])

      expect(client_for(stubs).retried_job?('42', '200')).to be(false)
    end

    it 'finds a previous attempt beyond the first page' do
      pages = []
      stubs.get('projects/42/pipelines/50/jobs') do |env|
        expect(env.params['include_retried']).to eq('true')
        expect(env.params['per_page']).to eq('100')
        page = env.params['page'].to_i
        pages << page
        jobs = if page == 1
                 Array.new(100) { |i| current.merge('id' => 300 + i, 'name' => 'other') }
               else
                 [current.merge('id' => 100)]
               end
        [200, {'Content-Type' => 'application/json'}, JSON.generate(jobs)]
      end

      expect(client_for(stubs).retried_job?('42', '200')).to be(true)
      expect(pages).to eq([1, 2])
    end

    it 'fails when the history cannot be read completely' do
      stub_const('Aireview::GitlabClient::JOBS_PAGE_LIMIT', 1)
      stub_jobs(stubs, Array.new(100) { |i| current.merge('id' => 300 + i, 'name' => 'other') })

      expect { client_for(stubs).retried_job?('42', '200') }
        .to raise_error(Aireview::ApiError, /Too many pipeline jobs/)
    end

    {
      'a missing pipeline' => ->(job) { job.reject { |key, _| key == 'pipeline' } },
      'a null pipeline' => ->(job) { job.merge('pipeline' => nil) },
      'a pipeline without an id' => ->(job) { job.merge('pipeline' => {}) },
      'a missing job name' => ->(job) { job.reject { |key, _| key == 'name' } },
      'a string job id' => ->(job) { job.merge('id' => '200') },
      'a null job' => ->(_job) { nil }
    }.each do |description, transform|
      context "with #{description}" do
        let(:current) { transform.call(super()) }

        it 'raises an API error instead of leaking Ruby exceptions' do
          expect { client_for(stubs).retried_job?('42', '200') }
            .to raise_error(Aireview::ApiError, /GitLab Jobs API returned an invalid job payload/)
        end
      end
    end

    [nil, {}, 'unexpected response'].each do |payload|
      it "rejects a non-array jobs list: #{payload.inspect}" do
        stub_jobs(stubs, payload)

        expect { client_for(stubs).retried_job?('42', '200') }
          .to raise_error(Aireview::ApiError, /invalid jobs list/)
      end
    end

    [nil, {}, {'id' => '100', 'name' => 'aireview', 'stage' => 'review'},
     {'id' => 100, 'name' => 'aireview', 'stage' => nil}].each do |job|
      it "rejects a malformed job history entry: #{job.inspect}" do
        stub_jobs(stubs, [job])

        expect { client_for(stubs).retried_job?('42', '200') }
          .to raise_error(Aireview::ApiError, /invalid job payload/)
      end
    end

    it 'converts an HTML success response into an API error' do
      stubs.get('projects/42/pipelines/50/jobs') { [200, {}, '<html>Proxy error</html>'] }

      expect { client_for(stubs).retried_job?('42', '200') }
        .to raise_error(Aireview::ApiError, /GitLab API returned invalid JSON/)
    end

    it 'propagates job history API failures' do
      stubs.get('projects/42/pipelines/50/jobs') { [403, {}, 'Forbidden'] }

      expect { client_for(stubs).retried_job?('42', '200') }
        .to raise_error(Aireview::ApiError, /403/)
    end
  end
end
