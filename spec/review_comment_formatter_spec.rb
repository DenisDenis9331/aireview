require 'aireview/context_budget'
require 'aireview/review_comment_formatter'
require 'aireview/review_renderer'

RSpec.describe Aireview::ReviewCommentFormatter do
  let(:finding) do
    {
      'id' => 'C1',
      'file' => 'app/models/order.rb',
      'line' => 12,
      'category' => 'bug',
      'severity' => 'major',
      'problem' => 'Tax is no longer included',
      'why' => 'Breaks checkout',
      'suggestion' => 'Keep the previous calculation'
    }
  end

  it 'returns body unchanged when within limit' do
    body = Aireview::ReviewRenderer.new.render([finding], summary: 'Short summary')

    expect(described_class.fit(body, limit: body.length)).to eq(body)
  end

  it 'truncates the Not reviewed list first in Russian' do
    coverage = Aireview::ContextBudget::Coverage.empty
    coverage.files_not_shown.push(*(1..40).map { |i| "app/models/very_long_model_name_#{i}.rb" })
    body = Aireview::ReviewRenderer.new(language: 'ru').render([finding], summary: 'Ок', coverage: coverage)
    limit = body.length - 200

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include('Tax is no longer included', 'файлов не показано')
  end

  it 'truncates Summary in Russian when there is no Not reviewed list' do
    body = Aireview::ReviewRenderer.new(language: 'ru').render([finding], summary: 'а' * 800)
    limit = body.length - 400

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include('[сводка усечена]', 'Tax is no longer included')
  end

  it 'closes an unclosed fenced code block when truncating Summary' do
    summary = "Intro\n\n```ruby\n#{"puts :ok\n" * 100}```"
    body = Aireview::ReviewRenderer.new.render([finding], summary: summary)
    limit = body.length - 400

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include("\n```\n[summary truncated]")
    expect(fitted.scan(/^[ \t]*```/).size).to be_even
  end

  it 'closes tilde and longer fences with the matching marker' do
    summary = "Intro\n\n~~~~markdown\n#{"line\n" * 120}~~~~"
    body = Aireview::ReviewRenderer.new.render([finding], summary: summary)
    limit = body.length - 400

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include("\n~~~~\n[summary truncated]")
  end

  it 'drops the summary instead of failing when room is too small for a fence' do
    summary = "```ruby\n#{'x' * 500}\n```"
    body = Aireview::ReviewRenderer.new.render([finding], summary: summary)
    limit = body.sub(summary, '').length + "\n[summary truncated]".length + 3

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include('[summary truncated]', 'Tax is no longer included')
    expect(fitted).not_to include('```')
  end

  it 'does not stop Summary at a ## heading inside a fenced code block' do
    summary = "Intro\n\n```markdown\n#{'x' * 250}\n\n## Example heading\n\ntext\n```"
    body = Aireview::ReviewRenderer.new.render([finding], summary: summary)
    limit = body.length - 150

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include("\n```\n[summary truncated]\n\n## Mismatches")
    expect(fitted.scan(/^[ \t]*```/).size).to eq(2)
  end

  it 'does not treat tab-indented backticks as a fenced code block' do
    summary = "Intro\n\n\t``` literal marker in indented code\n\t#{'x' * 250}\n\nDone"
    body = Aireview::ReviewRenderer.new.render([finding], summary: summary)
    limit = body.length - 150

    fitted = described_class.fit(body, limit: limit)

    expect(fitted.length).to be <= limit
    expect(fitted).to include("[summary truncated]\n\n## Mismatches")
  end

  it 'returns nil when findings alone exceed the limit' do
    large_finding = finding.merge('problem' => 'x' * 500)
    body = Aireview::ReviewRenderer.new.render([large_finding], summary: 'Short')

    expect(described_class.fit(body, limit: 300)).to be_nil
  end
end
