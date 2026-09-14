require 'aireview/candidate_checker'
require 'aireview/context_budget'
require 'stringio'

RSpec.describe Aireview::CandidateChecker do
  let(:changes) do
    [
      {'old_path' => 'app/models/order.rb', 'new_path' => 'app/models/order.rb'},
      {'old_path' => 'lib/old_name.rb', 'new_path' => 'lib/new_name.rb', 'renamed_file' => true},
      {'old_path' => 'app/big.rb', 'new_path' => 'app/big.rb'},
      {'old_path' => 'assets/logo.png', 'new_path' => 'assets/logo.png'},
      {'old_path' => 'app/hidden.rb', 'new_path' => 'app/hidden.rb'},
      {'old_path' => 'a/worker.rb', 'new_path' => 'a/worker.rb'},
      {'old_path' => 'lib/gone.rb', 'new_path' => 'lib/gone.rb', 'deleted_file' => true}
    ]
  end

  let(:diff_text) do
    <<~DIFF
      diff --git a/app/models/order.rb b/app/models/order.rb
      --- a/app/models/order.rb
      +++ b/app/models/order.rb
      @@ -10,3 +10,3 @@
       def total
      -  subtotal + tax
      +  subtotal
       end
      @@ -40,2 +40,3 @@
       def discount
      +  amount * rate
       end
      diff --git a/lib/old_name.rb b/lib/new_name.rb
      --- a/lib/old_name.rb
      +++ b/lib/new_name.rb
      [no text changes]
      diff --git a/app/big.rb b/app/big.rb
      --- a/app/big.rb
      +++ b/app/big.rb
      @@ -1,2 +1,2 @@
      -old
      +new
      [file app/big.rb: 1 of 3 hunks shown]
      diff --git a/assets/logo.png b/assets/logo.png
      --- a/assets/logo.png
      +++ b/assets/logo.png
      [diff not available]
      diff --git a/a/worker.rb b/a/worker.rb
      --- a/a/worker.rb
      +++ b/a/worker.rb
      @@ -1,2 +1,3 @@
       first()
      +++ counter
      +--- marker
      diff --git a/lib/gone.rb b/lib/gone.rb
      --- a/lib/gone.rb
      +++ b/lib/gone.rb
      @@ -1 +0,0 @@
      -gone
      [1 file(s) not shown: app/hidden.rb]
    DIFF
  end

  let(:coverage) do
    coverage = Aireview::ContextBudget::Coverage.empty
    coverage.files_partial << {path: 'app/big.rb', shown: 1, total: 3}
    coverage.files_unavailable << 'assets/logo.png'
    coverage.files_not_shown << 'app/hidden.rb'
    coverage
  end

  let(:log_output) { StringIO.new }
  let(:checker) do
    described_class.new(changes: changes, diff_text: diff_text, coverage: coverage, logger: Logger.new(log_output))
  end

  def candidate(overrides = {})
    {
      'id' => 'C1', 'file' => 'app/models/order.rb', 'line' => 11, 'quoted_code' => 'subtotal',
      'category' => 'bug', 'severity' => 'major', 'problem' => 'Tax is lost'
    }.merge(overrides)
  end

  it 'keeps a candidate whose file, line and quote match the shown diff, without a note' do
    result = checker.check([candidate])

    expect(result).to eq([candidate])
    expect(log_output.string).to be_empty
  end

  it 'drops a candidate whose file is not in the merge request' do
    result = checker.check([candidate('file' => 'app/models/invoice.rb'), candidate('id' => 'C2')])

    expect(result.map { |c| c['id'] }).to eq(['C2'])
    expect(log_output.string).to include('Candidate C1 dropped: file "app/models/invoice.rb" is not in the merge request')
  end

  it 'normalizes a/, b/ and ./ prefixes and accepts the old path of a renamed file' do
    result = checker.check([
      candidate('file' => 'b/app/models/order.rb'),
      candidate('id' => 'C2', 'file' => './lib/old_name.rb', 'line' => nil, 'quoted_code' => nil)
    ])

    expect(result.map { |c| c['file'] }).to eq(['b/app/models/order.rb', './lib/old_name.rb'])
    expect(result.last).not_to have_key('note')
  end

  it 'resets a line outside the shown hunks to null and tells the critic' do
    result = checker.check([candidate('line' => 25)])

    expect(result.first['line']).to be_nil
    expect(result.first['note']).to eq(described_class::NOTE_LINE_RESET)
    expect(log_output.string).to include('Candidate C1: line 25 is outside the shown hunks, reset to null')
  end

  it 'accepts a line from any shown hunk, including a hunk without a length' do
    expect(checker.check([candidate('line' => 42)]).first['line']).to eq(42)
  end

  it 'finds a quote across lines and whitespace differences' do
    result = checker.check([candidate('quoted_code' => "def total\n    subtotal\nend")])

    expect(result.first).not_to have_key('note')
  end

  it 'finds a quote in a removed line' do
    expect(checker.check([candidate('quoted_code' => 'subtotal + tax')]).first).not_to have_key('note')
  end

  it 'marks a quote that is not in the shown diff without dropping the candidate' do
    result = checker.check([candidate('quoted_code' => 'subtotal * tax')])

    expect(result.first['quote_missing']).to be(true)
    expect(result.first['line']).to eq(11)
    expect(result.first['note']).to eq(described_class::NOTE_QUOTE_NOT_FOUND)
    expect(log_output.string).to include('Candidate C1: quoted_code not found in the diff shown to the model')
  end

  it 'combines a reset line and a missing quote in one note' do
    result = checker.check([candidate('line' => 99, 'quoted_code' => 'nope')])

    expect(result.first['note']).to eq("#{described_class::NOTE_LINE_RESET}; #{described_class::NOTE_QUOTE_NOT_FOUND}")
  end

  it 'does not judge a partially shown file: the location is left as is and only noted' do
    result = checker.check([candidate('file' => 'app/big.rb', 'line' => 500, 'quoted_code' => 'nope')])

    expect(result.first['line']).to eq(500)
    expect(result.first).not_to have_key('quote_missing')
    expect(result.first['note']).to eq(described_class::NOTE_NOT_VERIFIED)
    expect(log_output.string).not_to include('WARN')
  end

  it 'treats files without a diff or left out of the context as not verifiable' do
    result = checker.check([
      candidate('file' => 'assets/logo.png', 'line' => nil, 'quoted_code' => 'binary'),
      candidate('id' => 'C2', 'file' => 'app/hidden.rb', 'line' => 3, 'quoted_code' => 'x')
    ])

    expect(result.map { |c| c['note'] }).to eq([described_class::NOTE_NOT_VERIFIED] * 2)
    expect(result.last['line']).to eq(3)
  end

  it 'prefers the exact path when a real a/ or b/ directory exists' do
    result = checker.check([candidate('file' => 'a/worker.rb', 'line' => 2, 'quoted_code' => '++ counter')])

    expect(result.first).not_to have_key('note')
  end

  it 'does not read added code that looks like a file header as a header' do
    result = checker.check([
      candidate('file' => 'a/worker.rb', 'line' => 3, 'quoted_code' => '-- marker'),
      candidate('id' => 'C2', 'file' => 'a/worker.rb', 'line' => nil, 'quoted_code' => 'first() ++ counter')
    ])

    expect(result.map { |c| c['note'] }).to eq([nil, nil])
  end

  it 'does not find a quote that spans two hunks' do
    result = checker.check([candidate('quoted_code' => "end\ndef discount")])

    expect(result.first['quote_missing']).to be(true)
  end

  it 'gives a hunk without new lines no valid line numbers' do
    result = checker.check([candidate('file' => 'lib/gone.rb', 'line' => 0, 'quoted_code' => 'gone')])

    expect(result.first['line']).to be_nil
    expect(result.first['note']).to eq(described_class::NOTE_LINE_RESET)
  end

  it 'keeps symbol keys when the candidate uses them' do
    result = checker.check([{id: 'C1', file: 'app/models/order.rb', line: 99, quoted_code: 'nope'}])

    expect(result.first).to eq(id: 'C1', file: 'app/models/order.rb', line: nil, quoted_code: 'nope',
                                'quote_missing' => true,
                                'note' => "#{described_class::NOTE_LINE_RESET}; #{described_class::NOTE_QUOTE_NOT_FOUND}")
  end
end
