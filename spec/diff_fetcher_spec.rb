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

RSpec.describe Aireview::DiffFetcher::Entry do
  def entry(diff, **extra)
    described_class.new({ 'old_path' => 'a.rb', 'new_path' => 'b.rb', 'diff' => diff }.merge(extra))
  end

  it 'splits a diff into hunks by their headers' do
    parsed = entry("@@ -1,2 +1,2 @@\n-a\n+b\n@@ -10,1 +10,1 @@\n+c")

    expect(parsed).to be_text
    expect(parsed.hunks).to eq(["@@ -1,2 +1,2 @@\n-a\n+b\n", "@@ -10,1 +10,1 @@\n+c\n"])
    expect(parsed.header).to eq("diff --git a/a.rb b/b.rb\n--- a/a.rb\n+++ b/b.rb\n")
    expect(parsed.render).to eq(parsed.header + parsed.hunks.join)
  end

  it 'treats a diff without hunk headers as one hunk' do
    parsed = entry('[REDACTED: secret file config/secrets.yml]')

    expect(parsed.hunks).to eq(["[REDACTED: secret file config/secrets.yml]\n"])
  end

  it 'marks explained empty diffs as having no text changes' do
    expect(entry('', 'renamed_file' => true).kind).to eq(:no_text_changes)
    expect(entry('', 'new_file' => true).kind).to eq(:no_text_changes)
    expect(entry('', 'deleted_file' => true).kind).to eq(:no_text_changes)
    expect(entry('', 'a_mode' => '100644', 'b_mode' => '100755').kind).to eq(:no_text_changes)
    expect(entry('', 'renamed_file' => true).render).to end_with("[no text changes]\n")
  end

  it 'marks an unexplained empty diff as unavailable' do
    parsed = entry('', 'renamed_file' => false, 'new_file' => false, 'deleted_file' => false,
                       'a_mode' => '100644', 'b_mode' => '100644')

    expect(parsed.kind).to eq(:unavailable)
    expect(parsed).to be_unavailable
    expect(entry('').kind).to eq(:unavailable)
  end

  it 'marks too large and binary diffs as unavailable' do
    expect(entry("@@ -1 +1 @@\n+x", 'too_large' => true).kind).to eq(:unavailable)
    expect(entry("Binary files a/x.png and b/x.png differ\n").kind).to eq(:unavailable)
    expect(entry('', 'too_large' => true).render).to end_with("[diff not available]\n")
  end
end
