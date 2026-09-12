require 'aireview/context_budget'
require 'aireview/diff_fetcher'

RSpec.describe Aireview::ContextBudget do
  def change(path, diff, **extra)
    { 'old_path' => path, 'new_path' => path, 'diff' => diff }.merge(extra)
  end

  def hunk(index, lines: 30)
    "@@ -#{index * 10},#{lines} +#{index * 10},#{lines} @@\n" + Array.new(lines) { |i| "+#{index}.#{i}\n" }.join
  end

  def entries(changes)
    Aireview::DiffFetcher.new(ignore_paths: [], logger: Logger.new(nil)).entries(changes)
  end

  def pack(changes, budget:)
    coverage = described_class::Coverage.empty
    packed = described_class.pack_entries(entries(changes), budget: budget, coverage: coverage)
    [packed, coverage]
  end

  let(:trailer) { described_class::TRAILER_RESERVE_CHARS }

  describe '.truncate_section' do
    it 'keeps the beginning and records the section' do
      coverage = described_class::Coverage.empty

      text = described_class.truncate_section('abcdefgh', limit: 3, label: 'MR description', coverage: coverage)

      expect(text).to eq("abc\n[MR description truncated: 3 of 8 chars shown]")
      expect(coverage.truncated_sections).to eq(['MR description'])
    end

    it 'leaves short text untouched' do
      coverage = described_class::Coverage.empty

      expect(described_class.truncate_section('abc', limit: 3, label: 'x', coverage: coverage)).to eq('abc')
      expect(coverage).to be_complete
    end
  end

  describe '.pack_entries' do
    it 'returns the whole diff without markers when it fits' do
      changes = [change('a.rb', hunk(1)), change('b.rb', hunk(2))]

      packed, coverage = pack(changes, budget: 10_000)

      expect(packed.text).to eq(Aireview::DiffFetcher.new(ignore_paths: [], logger: Logger.new(nil)).render(changes))
      expect(packed.shown_hunks).to eq(2)
      expect(coverage).to be_complete
    end

    it 'takes whole files in order and lists the rest' do
      changes = [change('a.rb', hunk(1)), change('b.rb', hunk(2)), change('c.rb', hunk(3))]
      a = entries(changes).first.render

      packed, coverage = pack(changes, budget: trailer + a.length + 10)

      expect(packed.text).to include('+1.0')
      expect(packed.text).not_to include('+2.0', '+3.0')
      expect(packed.text).to end_with("[2 file(s) not shown: b.rb, c.rb]\n")
      expect(coverage.files_not_shown).to eq(['b.rb', 'c.rb'])
      expect(coverage.files_partial).to be_empty
      expect(packed.shown_hunks).to eq(1)
    end

    it 'shows whole hunks of the first file that does not fit and stops there' do
      changes = [change('a.rb', "#{hunk(1, lines: 80)}#{hunk(2, lines: 80)}#{hunk(3, lines: 80)}"), change('b.rb', hunk(4))]
      entry = entries(changes).first
      two_hunks = entry.header.length + hunk(1, lines: 80).length + hunk(2, lines: 80).length + 60

      packed, coverage = pack(changes, budget: trailer + two_hunks)

      expect(packed.text).to include('+1.0', '+2.0')
      expect(packed.text).not_to include('+3.0', '+4.0')
      expect(packed.text).to include('[file a.rb: 2 of 3 hunks shown]')
      expect(coverage.files_partial).to eq([{ path: 'a.rb', shown: 2, total: 3 }])
      expect(coverage.files_not_shown).to eq(['b.rb'])
    end

    it 'skips a hunk larger than the whole budget and keeps packing the smaller ones' do
      changes = [change('a.rb', "#{hunk(1)}#{hunk(2, lines: 200)}#{hunk(3)}")]
      entry = entries(changes).first
      budget = trailer + entry.header.length + hunk(1).length + hunk(3).length + 200

      packed, coverage = pack(changes, budget: budget)

      expect(packed.text).to include('+1.0', '+3.0')
      expect(packed.text).not_to include('+2.0')
      expect(packed.text).to include('[hunk 2 of 3 skipped: larger than the context budget]')
      expect(packed.text).to include('[file a.rb: 2 of 3 hunks shown]')
      expect(coverage.hunks_skipped).to eq([{ path: 'a.rb', hunk: 2 }])
      expect(coverage.files_partial).to eq([{ path: 'a.rb', shown: 2, total: 3 }])
    end

    it 'shows files without text changes first and counts them in the budget' do
      changes = [
        change('big.rb', hunk(1, lines: 100)),
        change('renamed.rb', '', 'renamed_file' => true),
        change('small.rb', hunk(2, lines: 3)),
        change('huge.bin', '', 'too_large' => true)
      ]
      non_text = entries(changes).reject(&:text?).sum { |entry| entry.render.length }
      small = entries(changes)[2].render.length

      packed, coverage = pack(changes, budget: trailer + non_text + small + 40)

      expect(packed.text).to start_with("diff --git a/renamed.rb b/renamed.rb\n--- a/renamed.rb\n+++ b/renamed.rb\n[no text changes]")
      expect(packed.text).to include("+++ b/huge.bin\n[diff not available]")
      expect(packed.text).to include('+2.0')
      expect(coverage.files_unavailable).to eq(['huge.bin'])
      expect(coverage.files_not_shown).to eq(['big.rb'])
      expect(packed.shown_hunks).to eq(1)
    end

    it 'reports an unexplained empty diff as unavailable, not as complete coverage' do
      changes = [change('a.rb', '')]

      packed, coverage = pack(changes, budget: 10_000)

      expect(packed.text).to include('[diff not available]')
      expect(coverage.files_unavailable).to eq(['a.rb'])
      expect(coverage).not_to be_complete
    end

    it 'is not an error when a merge request has no text hunks at all' do
      changes = [change('a.rb', '', 'renamed_file' => true)]

      packed, coverage = pack(changes, budget: 10_000)

      expect(packed.total_hunks).to eq(0)
      expect(coverage).to be_complete
      expect(packed.text).to include('[no text changes]')
    end

    it 'raises when the entries without hunks alone exceed the budget' do
      changes = [change('a.rb', '', 'renamed_file' => true), change('b.rb', hunk(1))]

      expect { pack(changes, budget: 20) }
        .to raise_error(Aireview::ContextBudgetError, /files without text changes alone exceed it/)
    end

    it 'raises when not a single hunk fits' do
      changes = [change('a.rb', hunk(1, lines: 100)), change('b.rb', hunk(2, lines: 100))]

      expect { pack(changes, budget: trailer + 100) }
        .to raise_error(Aireview::ContextBudgetError, /not a single hunk fits/)
    end

    it 'never exceeds the budget even with many oversized hunks and their markers' do
      diff = hunk(1, lines: 3) + Array.new(20) { |i| hunk(i + 2, lines: 200) }.join
      changes = [change('a.rb', diff), change('b.rb', hunk(30, lines: 3))]

      [600, 700, 800, 1_000, 1_500].each do |budget|
        packed, coverage = pack(changes, budget: budget)

        expect(packed.text.length).to be <= budget
        expect(packed.text).to include('+1.0')
        expect(coverage.hunks_skipped.size).to eq(20)
      end
    end

    it 'counts separators between files against the budget' do
      changes = Array.new(6) { |i| change("f#{i}.rb", hunk(i, lines: 40)) }
      fetcher = Aireview::DiffFetcher.new(ignore_paths: [], logger: Logger.new(nil))
      first_four = fetcher.render(changes.first(4)).length

      exact, exact_coverage = pack(changes, budget: first_four + trailer)
      expect(exact_coverage.files_not_shown).to eq(['f4.rb', 'f5.rb'])
      expect(exact.text.length).to be <= first_four + trailer

      short, short_coverage = pack(changes, budget: first_four + trailer - 1)
      expect(short_coverage.files_not_shown).to eq(['f3.rb', 'f4.rb', 'f5.rb'])
      expect(short.text.length).to be <= first_four + trailer - 1
    end

    it 'caps the list of files that were not shown' do
      changes = [change('shown.rb', hunk(1))] +
                Array.new(40) { |i| change("app/very/long/directory/name/number/#{i}/file_#{i}.rb", hunk(2)) }
      first = entries(changes).first.render

      packed, coverage = pack(changes, budget: trailer + first.length + 10)

      trailer_line = packed.text.lines.last
      expect(trailer_line).to start_with('[40 file(s) not shown: ')
      expect(trailer_line).to match(/ and \d+ more\]\n\z/)
      expect(trailer_line.length).to be <= trailer
      expect(coverage.files_not_shown.size).to eq(40)
    end
  end
end
