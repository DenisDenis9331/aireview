require 'json'
require 'aireview/result_parser'

RSpec.describe Aireview::ResultParser do
  let(:parser) { described_class.new }

  describe 'generate results' do
    it 'accepts JSON, JSON in code fences, a bare candidates array and a ready structure with symbol keys' do
      expected = {'summary' => nil, 'candidates' => [{'id' => 'C1', 'file' => 'a.rb'}]}

      expect(parser.parse('{"candidates":[{"id":"C1","file":"a.rb"}]}', expected: :generate)).to eq(expected)
      expect(parser.parse("```json\n{\"candidates\":[{\"id\":\"C1\",\"file\":\"a.rb\"}]}\n```", expected: :generate))
        .to eq(expected)
      expect(parser.parse('[{"id":"C1","file":"a.rb"}]', expected: :generate)).to eq(expected)
      expect(parser.parse({candidates: [{id: 'C1', file: 'a.rb'}]}, expected: 'generate')).to eq(expected)
      expect(parser.parse({summary: 'ok', candidates: []}, expected: :generate)).to eq('summary' => 'ok', 'candidates' => [])
    end

    it 'rejects the wrong shape and bad ids with the reason' do
      expect { parser.parse('{"summary":"x"}', expected: :generate) }
        .to raise_error(described_class::SchemaError, 'expected an object with summary and candidates array')
      expect { parser.parse('{"candidates":["x"]}', expected: :generate) }
        .to raise_error(described_class::SchemaError, 'each generate candidate must be an object')
      expect { parser.parse('{"candidates":[{"file":"a.rb"}]}', expected: :generate) }
        .to raise_error(described_class::SchemaError, 'each generate candidate must include a non-empty id')
      expect { parser.parse('{"candidates":[{"id":"C1"},{"id":"C1"}]}', expected: :generate) }
        .to raise_error(described_class::SchemaError, 'duplicate generate candidate ids: C1')
      expect { parser.parse('not json', expected: :generate) }.to raise_error(JSON::ParserError)
    end
  end

  describe 'critique results' do
    def verdicts(*items)
      JSON.generate(verdicts: items)
    end

    it 'accepts keep and reject verdicts for exactly the expected candidates' do
      result = parser.parse(verdicts({id: 'C1', decision: 'Keep ', reason: 'r', refinement: {severity: 'minor'}},
                                     {id: 'C2', decision: 'reject', reason: 'r'}),
                            expected: :critique, critique_candidate_ids: %w[C1 C2])

      expect(result['verdicts'].map { |verdict| verdict['id'] }).to eq(%w[C1 C2])
      expect(result['verdicts'].first['refinement']).to eq('severity' => 'minor')
    end

    it 'rejects unknown, missing and duplicate ids, bad decisions and refinements on rejects' do
      expect { parser.parse(verdicts({id: 'C9', decision: 'keep'}), expected: :critique, critique_candidate_ids: %w[C1]) }
        .to raise_error(described_class::SchemaError, 'unknown verdict ids: C9')
      expect { parser.parse(verdicts({id: 'C1', decision: 'keep'}), expected: :critique, critique_candidate_ids: %w[C1 C2]) }
        .to raise_error(described_class::SchemaError, 'missing verdict ids: C2')
      expect { parser.parse(verdicts({id: 'C1', decision: 'keep'}, {id: 'C1', decision: 'keep'}), expected: :critique) }
        .to raise_error(described_class::SchemaError, 'duplicate verdict ids: C1')
      expect { parser.parse(verdicts({id: 'C1', decision: 'maybe'}), expected: :critique) }
        .to raise_error(described_class::SchemaError, 'invalid verdict decision for C1')
      expect { parser.parse(verdicts({id: 'C1', decision: 'reject', refinement: {}}), expected: :critique) }
        .to raise_error(described_class::SchemaError, 'reject verdict cannot include refinement for C1')
      expect { parser.parse(verdicts({id: 'C1', decision: 'keep', refinement: 'x'}), expected: :critique) }
        .to raise_error(described_class::SchemaError, 'refinement must be an object for C1')
      expect { parser.parse('{"verdicts":"x"}', expected: :critique) }
        .to raise_error(described_class::SchemaError, 'expected an object with verdicts array')
    end
  end

  it 'rejects an unknown schema' do
    expect { parser.parse('{}', expected: :repair) }.to raise_error(ArgumentError, 'Unknown expected JSON schema: :repair')
  end
end
