# frozen_string_literal: true

require 'json'
require 'stringio'
require 'aireview/context_builder'
require 'aireview/jev_client'
require 'aireview/jev_critic'

RSpec.describe Aireview::JevCritic do
  # Answers every question it is asked: noul values from `values` by key,
  # otherwise a confident "real, enough context, no version claim"; choice
  # questions from `choices`, otherwise none / major.
  let(:fake_client_class) do
    Class.new do
      attr_reader :requests
      # reject — raises a JevError for the questions it returns one for.
      attr_writer :reject

      def initialize(values, choices)
        @values = values
        @choices = choices
        @requests = []
      end

      def evaluate(state:, questions:)
        @requests << {state: state, questions: questions}
        error = @reject&.call(questions)
        raise error if error

        answers = questions.to_h { |key, question| [key, answer(key, question)] }
        Aireview::JevClient::Result.new(model: 'jev-1.13.0', answers: answers, usage: {})
      end

      private

      def answer(key, question)
        if question['type'] == 'noul'
          default = key.start_with?('version_claim') ? 0.0 : 0.9
          {'type' => 'noul', 'noul' => @values.fetch(key, default)}
        else
          choice, confidence = @choices.fetch(key) { [key.start_with?('severity') ? 'major' : 'none', 0.9] }
          {'type' => 'choice', 'choice' => choice, 'confidence' => confidence}
        end
      end
    end
  end
  let(:values) { {} }
  let(:choices) { {} }
  let(:client) { fake_client_class.new(values, choices) }
  let(:thresholds) { {keep_above: 0.5, enough_context: 0.5, version_claim: 0.5, duplicate: 0.5} }
  let(:log) { StringIO.new }
  let(:critic) { described_class.new(client: client, thresholds: thresholds, logger: Logger.new(log)) }

  let(:diff_text) do
    "diff --git a/app/order.rb b/app/order.rb\n--- a/app/order.rb\n+++ b/app/order.rb\n" \
      "@@ -1,2 +1,2 @@\n def total\n-  subtotal + tax\n+  subtotal\n" \
      "@@ -40,2 +40,2 @@\n def tax\n-  0.2\n+  0.1\n"
  end
  let(:coverage) { Aireview::ContextBudget::Coverage.empty }

  def context(diff: diff_text, sections: "MR: Fix order total\nDescription:\nTax must stay.")
    Aireview::ContextBuilder::Context.new(user_prompt: '', sections: sections, diff_text: diff,
                                          coverage: coverage, sizes: {})
  end

  def candidate(id, file: 'app/order.rb', line: 2, severity: 'major', **extra)
    {'id' => id, 'file' => file, 'line' => line, 'quoted_code' => 'subtotal', 'category' => 'bug',
     'severity' => severity, 'problem' => "Problem #{id}", 'why' => 'Why', 'suggestion' => 'Fix'}.merge(extra)
  end

  def decisions(result)
    result.assessments.to_h { |assessment| [assessment.id, [assessment.decision, assessment.reason]] }
  end

  it 'asks about every candidate in one request and decides by the thresholds' do
    values.merge!('real_issue_C2' => 0.2, 'enough_context_C3' => 0.3, 'version_claim_C4' => 0.8)
    candidates = %w[C1 C2 C3 C4].map { |id| candidate(id) }

    result = critic.assess(context: context, candidates: candidates)

    expect(client.requests.size).to eq(1)
    expect(result.requests).to eq(1)
    expect(result.model).to eq('jev-1.13.0')
    expect(decisions(result)).to eq(
      'C1' => [:keep, 'real issue'],
      'C2' => [:reject, 'not a confirmed issue'],
      'C3' => [:unverifiable, 'not enough context in the request'],
      'C4' => [:reject, 'claims that a version does not exist']
    )
    expect(result.assessments.first.answers).to include(real_issue: 0.9, severity: {choice: 'major', confidence: 0.9})
    expect(log.string).to match(/Jev request estimated at ~\d+ tokens \(\d+ chars of state and questions\)/)
  end

  it 'builds the questions from the template and the state from the requirements, candidates and diff' do
    critic.assess(context: context, candidates: [candidate('C1'), candidate('C2')])
    request = client.requests.first

    expect(request[:questions].keys).to contain_exactly(
      'real_issue_C1', 'enough_context_C1', 'version_claim_C1', 'severity_C1', 'duplicate_of_C1',
      'real_issue_C2', 'enough_context_C2', 'version_claim_C2', 'severity_C2', 'duplicate_of_C2'
    )
    real_issue = request[:questions]['real_issue_C1']
    expect(real_issue['type']).to eq('noul')
    expect(real_issue['instructions']).to include('`candidates.C1`')
    expect(real_issue['criteria'].keys).to eq(%w[true false])
    expect(real_issue['criteria']['false']).to include('assumption about code outside the diff')
    expect(request[:questions]['duplicate_of_C1']['criteria'].keys).to eq(%w[C2 none])

    state = request[:state]
    expect(state['requirements']).to include('Tax must stay.')
    expect(state['diff']).to eq(diff_text)
    expect(state['candidates'].keys).to eq(%w[C1 C2])
    expect(state['candidates']['C1']).to include('problem' => 'Problem C1', 'suggestion' => 'Fix')
    expect(state).not_to have_key('context_truncated')
  end

  it 'gives the hunk of the line as evidence, the whole file without a confirmed line, and says when the file is absent' do
    candidates = [
      candidate('C1', line: 41),
      candidate('C2', line: 2, 'note' => 'quoted_code not found in the diff shown to the model'),
      candidate('C3', line: nil),
      candidate('C4', file: 'b/app/order.rb', line: 1),
      candidate('C5', file: 'app/other.rb')
    ]

    critic.assess(context: context, candidates: candidates)
    evidence = client.requests.first[:state]['candidates'].transform_values { |item| item['evidence'] }

    expect(evidence['C1']).to eq("@@ -40,2 +40,2 @@\n def tax\n-  0.2\n+  0.1\n")
    expect(evidence['C2']).to eq(diff_text)
    expect(evidence['C3']).to eq(diff_text)
    expect(evidence['C4']).to start_with('@@ -1,2 +1,2 @@').and(end_with("+  subtotal\n"))
    expect(evidence['C5']).to eq(described_class::NOT_SHOWN)
  end

  it 'passes truncation marks, project instructions and scrubbed candidate text' do
    coverage.truncated_sections << 'Jira description'
    coverage.files_not_shown << 'big.rb'
    critic = described_class.new(client: client, thresholds: thresholds, review_instructions: ' Ignore specs ',
                                 scrub: ->(text) { text.gsub('token-123', '[REDACTED]') },
                                 logger: Logger.new(File::NULL))

    critic.assess(context: context, candidates: [candidate('C1', 'problem' => 'leaks token-123')])
    state = client.requests.first[:state]

    expect(state['context_truncated']).to eq(['Jira description truncated', 'files not shown: big.rb'])
    expect(state['project_instructions']).to eq('Ignore specs')
    expect(state['candidates']['C1']['problem']).to eq('leaks [REDACTED]')
  end

  describe 'duplicates' do
    it 'keeps the more severe of two duplicates, and the earlier one on a tie' do
      choices['duplicate_of_C1'] = ['C2', 0.9]
      choices['duplicate_of_C3'] = ['C4', 0.9]
      candidates = [candidate('C1', severity: 'minor'), candidate('C2', severity: 'major'),
                    candidate('C3'), candidate('C4')]

      result = critic.assess(context: context, candidates: candidates)

      expect(decisions(result)).to include('C1' => [:reject, 'duplicate of C2'], 'C2' => [:keep, 'real issue'],
                                           'C3' => [:keep, 'real issue'], 'C4' => [:reject, 'duplicate of C3'])
    end

    it 'ignores a weak duplicate answer and a duplicate of a rejected candidate' do
      choices['duplicate_of_C1'] = ['C2', 0.4]
      choices['duplicate_of_C3'] = ['C2', 0.9]
      values['real_issue_C2'] = 0.1

      result = critic.assess(context: context, candidates: %w[C1 C2 C3].map { |id| candidate(id) })

      expect(decisions(result).transform_values(&:first)).to eq('C1' => :keep, 'C2' => :reject, 'C3' => :keep)
    end

    it 'works on candidates with symbol keys, for a Critique that mixes Jev and LLM verdicts' do
      kept = [{id: 'C1', severity: 'major'}, {id: 'C2', severity: 'critical'}, {id: 'C3', severity: 'minor'}]
      answers = {
        'duplicate_of_C1' => {'choice' => 'C3', 'confidence' => 0.8},
        'duplicate_of_C3' => {'choice' => 'C2', 'confidence' => 0.8}
      }

      expect(described_class.duplicates(kept, answers, threshold: 0.5)).to eq('C1' => 'C2', 'C3' => 'C2')
    end
  end

  describe 'request budget' do
    def question_tokens(questions)
      questions.values.map { |question| (JSON.generate(question).length / described_class::CHARS_PER_TOKEN).ceil }
    end

    def state_tokens(state)
      (JSON.generate(state).length / described_class::CHARS_PER_TOKEN).ceil
    end

    def big_hunk(path, lines)
      "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1,#{lines} +1,#{lines} @@\n" +
        ("+#{'x' * 99}\n" * lines)
    end

    it 'cuts the diff first, then the requirements, leaving room for the questions in both limits' do
      diff = big_hunk('app/order.rb', 2) + big_hunk('app/huge.rb', 2_000)
      sections = "MR: Fix\n#{'requirement ' * 10_000}"

      critic.assess(context: context(diff: diff, sections: sections), candidates: [candidate('C1'), candidate('C2')])
      request = client.requests.first
      questions = question_tokens(request[:questions])

      expect(client.requests.size).to eq(1)
      expect(request[:state]['diff']).to end_with(described_class::TRUNCATED)
      expect(request[:state]['requirements']).to start_with('MR: Fix').and(end_with(described_class::TRUNCATED))
      expect(request[:state]['candidates']['C1']['evidence']).to include('+xxx')
      expect(state_tokens(request[:state]) + questions.max).to be <= described_class::STATE_WITH_LONGEST_QUESTION_TOKENS
      expect(state_tokens(request[:state]) + questions.sum).to be <= described_class::REQUEST_TOKENS
    end

    it 'asks about each candidate separately when the evidence does not fit one request' do
      diff = %w[a.rb b.rb c.rb].map { |path| big_hunk(path, 300) }.join
      candidates = %w[a.rb b.rb c.rb].each_with_index.map { |path, index| candidate("C#{index + 1}", file: path) }

      result = critic.assess(context: context(diff: diff), candidates: candidates)

      expect(client.requests.size).to eq(3)
      expect(result.requests).to eq(3)
      expect(client.requests.map { |request| request[:state]['candidates'].keys }).to eq([%w[C1], %w[C2], %w[C3]])
      expect(client.requests.flat_map { |request| request[:questions].keys }).not_to include(/duplicate_of/)
      expect(decisions(result).values.map(&:first)).to eq(%i[keep keep keep])
    end

    it 'asks about each candidate separately when Jev rejects the request as too large after all' do
      too_large = Aireview::JevError.new('Jev API error 422: {"detail":"state exceeds 32000 tokens"}', status: 422)
      client.reject = ->(questions) { too_large if questions.key?('duplicate_of_C1') }

      result = critic.assess(context: context, candidates: [candidate('C1'), candidate('C2')])

      expect(client.requests.map { |request| request[:state]['candidates'].keys }).to eq([%w[C1 C2], %w[C1], %w[C2]])
      expect(result.requests).to eq(3)
      expect(decisions(result).values.map(&:first)).to eq(%i[keep keep])
      expect(log.string).to include('asking about each candidate separately: Jev API error 422')
    end

    it 'leaves a candidate unverifiable when Jev rejects it as too large even alone' do
      too_large = Aireview::JevError.new('Jev API error 422: context length exceeded', status: 422)
      client.reject = ->(questions) { too_large if questions.key?('real_issue_C2') }

      result = critic.assess(context: context, candidates: [candidate('C1'), candidate('C2')])

      expect(client.requests.size).to eq(3)
      expect(decisions(result)).to eq(
        'C1' => [:keep, 'real issue'],
        'C2' => [:unverifiable, 'the candidate and its evidence do not fit a Jev request']
      )
    end

    it 'does not ask again after a 422 that is not about the size, even when a field name looks like one' do
      ['questions.real_issue_C1.criteria: field required', 'questions.enough_context_C1.criteria: field required']
        .each do |detail|
          client = fake_client_class.new(values, choices)
          client.reject = ->(_questions) { Aireview::JevError.new("Jev API error 422: #{detail}", status: 422) }
          critic = described_class.new(client: client, thresholds: thresholds, logger: Logger.new(log))

          expect { critic.assess(context: context, candidates: [candidate('C1'), candidate('C2')]) }
            .to raise_error(Aireview::JevError, /field required/)
          expect(client.requests.size).to eq(1)
        end
    end

    it 'recognizes only explicit size rejections' do
      size = ['state exceeds 32000 tokens', 'context length exceeded', 'Request too large',
              'maximum context is 64k tokens', 'token limit reached']
      other = ['questions.enough_context_C1.criteria: field required', 'state: field required',
               'criteria: ensure this value has at most 255 items', 'model: unknown jev-1.99.0']

      expect(size.grep(described_class::SIZE_ERROR)).to eq(size)
      expect(other.grep(described_class::SIZE_ERROR)).to be_empty
    end

    it 'marks a candidate unverifiable without a request when its evidence does not fit even alone' do
      result = critic.assess(context: context(diff: big_hunk('a.rb', 1_000)), candidates: [candidate('C1', file: 'a.rb')])

      expect(client.requests).to be_empty
      expect(result.requests).to eq(0)
      expect(decisions(result)).to eq('C1' => [:unverifiable, 'the candidate and its evidence do not fit a Jev request'])
    end
  end
end
