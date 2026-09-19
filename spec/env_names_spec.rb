require 'aireview/config'

# Config.env_names is the list the CI template passes into the container. It
# is maintained by hand, so it is checked against what the code really reads:
# every env['NAME'] literal in lib/ must be in the list, otherwise a project
# variable never reaches the review.
RSpec.describe 'Config.env_names' do
  it 'covers every env variable the config code reads' do
    sources = Dir[File.expand_path('../lib/aireview/config*.rb', __dir__)].map { |path| File.read(path) }.join
    literals = sources.scan(/env\[['"]([A-Z][A-Z0-9_]+)['"]\]/).flatten.uniq
    literals += sources.scan(/env\["LLM_#\{stage\}_([A-Z_]+)"\]/).flatten.uniq.flat_map do |suffix|
      %w[GENERATE CRITIQUE].map { |stage| "LLM_#{stage}_#{suffix}" }
    end
    literals -= [Aireview::ConfigLoader::IMAGE_DEFAULTS_ENV]

    expect(literals).not_to be_empty
    expect(Aireview::Config.env_names).to include(*literals)
  end
end
