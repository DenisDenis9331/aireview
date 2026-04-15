require 'aireview/diff_fetcher'

RSpec.describe Aireview::DiffFetcher do
  describe '#filter' do
    it 'filters ignored paths' do
      fetcher = described_class.new(ignore_paths: ['vendor/**', '*.lock'], logger: Logger.new(nil))
      changes = [
        { 'new_path' => 'app/models/user.rb', 'old_path' => 'app/models/user.rb', 'diff' => '@@ -1 +1 @@' },
        { 'new_path' => 'vendor/lib/file.rb', 'old_path' => 'vendor/lib/file.rb', 'diff' => '@@ -1 +1 @@' },
        { 'new_path' => 'Gemfile.lock', 'old_path' => 'Gemfile.lock', 'diff' => '@@ -1 +1 @@' }
      ]

      filtered = fetcher.filter(changes)

      expect(filtered.size).to eq(1)
      expect(filtered.first['new_path']).to eq('app/models/user.rb')
    end
  end

  describe '#render' do
    it 'renders a unified diff' do
      fetcher = described_class.new(ignore_paths: [], logger: Logger.new(nil))
      rendered = fetcher.render([
        { 'new_path' => 'app/models/user.rb', 'old_path' => 'app/models/user.rb', 'diff' => "@@ -1 +1 @@\n-test\n+prod" }
      ])

      expect(rendered).to include('diff --git a/app/models/user.rb b/app/models/user.rb')
      expect(rendered).to include('+prod')
    end
  end
end
