require 'yaml'
require 'aireview/config'

RSpec.describe 'templates/review.gitlab-ci.yml' do
  let(:path) { File.expand_path('../templates/review.gitlab-ci.yml', __dir__) }
  let(:template) { YAML.load_file(path) }

  it 'pins a released image tag and runs it in the built-in .post stage' do
    expect(template.dig('variables', 'AIREVIEW_IMAGE_TAG')).to match(/\A\d+\.\d+\.\d+\z/)
    expect(template.dig('variables', 'AIREVIEW_IMAGE')).not_to include(':')

    job = template.fetch('aireview')
    expect(job['stage']).to eq('.post')
    expect(job['allow_failure']).to be(true)
    expect(job['resource_group']).to include('CI_MERGE_REQUEST_IID')
    expect(job['script'].join("\n")).to include('${AIREVIEW_IMAGE}:${AIREVIEW_IMAGE_TAG}')
  end

  it 'passes every env variable the config reads into the container by name' do
    script = template.dig('aireview', 'script').join("\n")
    passed = script.scan(/-e ([A-Z_]+)(?=\s)/).flatten
    # GITLAB_URL берётся из CI_SERVER_URL и передаётся со значением.
    expected = Aireview::Config.env_names - ['GITLAB_URL']

    expect(passed).to include(*expected)
    expect(script).to include('-e "GITLAB_URL=$CI_SERVER_URL"')
  end

  it 'passes secrets by name only and mounts .aireview.yml conditionally' do
    script = template.dig('aireview', 'script').join("\n")

    expect(script).to include('-e GITLAB_TOKEN')
    expect(script).not_to match(/-e "?(GITLAB_TOKEN|GEMINI_API_KEYS?)=/)
    expect(script).to include('if [ -f "$CI_PROJECT_DIR/.aireview.yml" ]')
    expect(script).to include('/app/.aireview.yml:ro')
  end
end
