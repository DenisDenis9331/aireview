require 'aireview/config'

# Config.env_names — список, который CI-шаблон пробрасывает в контейнер. Он
# поддерживается руками, поэтому сверяется с тем, что код реально читает:
# каждый литерал env['ИМЯ'] в lib/ обязан быть в списке, иначе переменная
# проекта до ревью не доедет.
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
