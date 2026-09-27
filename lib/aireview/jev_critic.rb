# frozen_string_literal: true
require 'json'
require 'logger'
require 'yaml'
require_relative 'utils'
require_relative 'candidate_checker'
require_relative 'jev_client'

module Aireview
  # Jev as a critic. Every candidate becomes a few questions
  # (prompts/jev_questions.yml) over one state: the MR and Jira sections, the
  # candidates with the hunks they point at, the diff. The answers turn into
  # keep, reject or unverifiable by thresholds, then duplicates among the
  # kept ones are dropped. Jev cannot rewrite a finding, so there is no
  # refinement. Used as the critique engine (JevStage) and in shadow mode.
  class JevCritic
    QUESTIONS = YAML.safe_load_file(File.expand_path('prompts/jev_questions.yml', __dir__)).freeze
    # The questions whose answers decide; severity only goes to the log. Their
    # templates go into the review key whole, not as asked about a stub
    # candidate: a single stub gets no duplicate_of question.
    DECISION_QUESTIONS = %w[real_issue enough_context version_claim duplicate_of].freeze
    # Jev limits (docs.typesafe.ai/models): the state plus the longest
    # question, and the state plus all questions together. Questions count
    # in both, so the state budget is what they leave.
    STATE_WITH_LONGEST_QUESTION_TOKENS = 32_000
    REQUEST_TOKENS = 64_000
    # There is no Jev tokenizer here: characters are converted pessimistically
    # (code and Cyrillic take more tokens than English prose) with a margin.
    # Every request logs the real input_tokens to compare against.
    CHARS_PER_TOKEN = 2.5
    SAFETY = 0.9
    CANDIDATE_FIELDS = %w[id file line quoted_code category severity problem why suggestion note].freeze
    TRUNCATED = '[truncated to fit the Jev request]'
    NOT_SHOWN = '(the file is not shown in the diff)'
    TASK = 'Second pass of a merge request review: check the candidate findings of the first pass ' \
           'against the diff and the requirements.'
    SEVERITY_RANK = {'critical' => 0, 'major' => 1, 'minor' => 2}.freeze
    # The docs only say that a 422 body names the offending field; a size
    # rejection is recognized by an explicit phrase about going over a limit.
    # Bare words like "context" are not enough: they occur in question names
    # (enough_context_C1). Any other 422 is a malformed request, and asking
    # again would not help.
    SIZE_ERROR = /
      \bexceed(?:s|ed|ing)?\b |
      \btoo\s+(?:long|large|many\s+tokens)\b |
      \bmaximum\s+(?:context|length|tokens?)\b |
      \b(?:token|context|length)\s+limit\b
    /ix

    # decision — :keep, :reject or :unverifiable; answers — the numbers
    # behind it, for the log.
    Assessment = Struct.new(:id, :decision, :reason, :answers, keyword_init: true) do
      # Rounded for reading; the exact numbers stay in answers.
      def numbers
        answers.map do |name, value|
          value.is_a?(Hash) ? "#{name}=#{value[:choice]}/#{round(value[:confidence])}" : "#{name}=#{round(value)}"
        end.join(' ')
      end

      private

      def round(value)
        value.is_a?(Numeric) ? value.round(2) : value
      end
    end
    # answers — every answer by question key, for dropping duplicates once
    # the verdicts of Jev and of the LLM are merged.
    Result = Struct.new(:assessments, :answers, :requests, :model, keyword_init: true)
    Request = Struct.new(:candidates, :state, :questions, keyword_init: true)
    # What the requests of one assessment gathered.
    Asked = Struct.new(:answers, :unfit, :requests, :model, keyword_init: true)

    # scrub — the secret scrubber of the context: the candidates are LLM text
    # and are scrubbed like the candidates JSON of the Critique prompt.
    def initialize(client:, thresholds:, review_instructions: nil, scrub: ->(text) { text },
                   logger: Logger.new($stderr))
      @client = client
      @thresholds = thresholds
      @scrub = scrub
      instructions = Aireview::Utils.presence(review_instructions.to_s.strip)
      @review_instructions = instructions && scrub.call(instructions)
      @logger = logger
    end

    # Kept candidates in generate order: an edge comes from a
    # duplicate_of_<id> answer that names another kept id with enough
    # confidence. In a group of duplicates the most severe one stays, on a
    # tie the one generate listed first. Returns {dropped id => kept id}.
    # The client and the critic as the config sets them up; scrub — the
    # secret scrubber of the context.
    def self.build(config:, scrub:, logger:)
      new(client: JevClient.new(config: config, logger: logger), thresholds: config.jev_thresholds,
          review_instructions: config.review_instructions, scrub: scrub, logger: logger)
    end

    def self.decision_templates
      QUESTIONS.slice(*DECISION_QUESTIONS)
    end

    def self.duplicates(kept, answers, threshold:)
      ids = kept.map { |candidate| field(candidate, 'id') }
      rank = kept.to_h do |candidate|
        [field(candidate, 'id'), SEVERITY_RANK.fetch(field(candidate, 'severity'), SEVERITY_RANK.size)]
      end
      duplicate_groups(ids, answers, threshold).each_with_object({}) do |group, dropped|
        winner = group.min_by { |id| [rank[id], ids.index(id)] }
        (group - [winner]).each { |id| dropped[id] = winner }
      end
    end

    def self.duplicate_groups(ids, answers, threshold)
      group_of = ids.to_h { |id| [id, [id]] }
      ids.each do |id|
        other = duplicate_answer(id, ids, answers, threshold)
        join_groups(group_of, id, other) if other
      end
      group_of.values.uniq(&:object_id).select { |group| group.size > 1 }
    end

    def self.join_groups(group_of, id, other)
      return if group_of[id].equal?(group_of[other])

      merged = group_of[id] + group_of[other]
      merged.each { |member| group_of[member] = merged }
    end

    # The other kept id a duplicate_of answer names with enough confidence.
    def self.duplicate_answer(id, ids, answers, threshold)
      answer = answers["duplicate_of_#{id}"]
      return nil unless answer.is_a?(Hash) && answer['confidence'].to_f >= threshold

      other = answer['choice']
      other if other != id && ids.include?(other)
    end

    def self.field(candidate, key)
      (candidate[key] || candidate[key.to_sym]).to_s.strip
    end

    # dedupe — false when the caller merges the verdicts with the LLM ones
    # first and drops duplicates over the whole set (JevStage).
    def assess(context:, candidates:, dedupe: true)
      candidates = candidates.map { |candidate| normalize(candidate) }
      sections = diff_sections(context.diff_text)
      asked = Asked.new(answers: {}, unfit: [], requests: 0, model: nil)
      plan_requests(context, candidates, sections).each { |request| ask(request, asked, context, sections) }
      assessments = candidates.map { |candidate| decide(candidate, asked.answers, asked.unfit) }
      assessments = drop_duplicates(assessments, candidates, asked.answers) if dedupe
      Result.new(assessments: assessments, answers: asked.answers, requests: asked.requests, model: asked.model)
    end

    # The first request as it would be sent, for --dry-run.
    def preview(context:, candidates:)
      candidates = candidates.map { |candidate| normalize(candidate) }
      plan_requests(context, candidates, diff_sections(context.diff_text)).first
    end

    private

    def normalize(candidate)
      CANDIDATE_FIELDS.to_h do |field|
        value = candidate[field] || candidate[field.to_sym]
        [field, value.is_a?(String) ? @scrub.call(value) : value]
      end.compact.merge('id' => self.class.field(candidate, 'id'))
    end

    # One request for all candidates when it fits, otherwise one per
    # candidate (then without duplicate_of: a request sees one candidate).
    # A candidate that does not fit even alone is unverifiable.
    def plan_requests(context, candidates, sections)
      shared = build_request(context, candidates, sections)
      return [shared] if shared.state || candidates.size == 1

      @logger.info('Jev: the candidates do not fit one request, asking about each separately')
      candidates.map { |candidate| build_request(context, [candidate], sections) }
    end

    def build_request(context, candidates, sections)
      ids = candidates.map { |candidate| candidate['id'] }
      questions = candidates.map { |candidate| questions_for(candidate['id'], ids) }.reduce({}, :merge)
      state = {
        'task' => TASK,
        'requirements' => context.sections,
        'project_instructions' => @review_instructions,
        'context_truncated' => coverage_notes(context.coverage),
        'candidates' => candidates.to_h { |candidate| [candidate['id'], with_evidence(candidate, sections)] },
        'diff' => context.diff_text
      }.compact
      Request.new(candidates: candidates, state: fit(state, state_budget(questions)), questions: questions)
    end

    def questions_for(id, ids)
      questions = %w[real_issue enough_context version_claim severity].to_h do |name|
        ["#{name}_#{id}", question(QUESTIONS.fetch(name), id)]
      end
      others = ids - [id]
      questions["duplicate_of_#{id}"] = duplicate_question(id, others) unless others.empty?
      questions
    end

    def question(template, id)
      {
        'type' => template.fetch('type'),
        'instructions' => format(template.fetch('instructions'), id: id),
        'criteria' => template.fetch('criteria').transform_values { |text| format(text, id: id) }
      }
    end

    def duplicate_question(id, others)
      template = QUESTIONS.fetch('duplicate_of')
      criteria = others.to_h { |other| [other, format(template.fetch('other'), other: other)] }
      {
        'type' => template.fetch('type'),
        'instructions' => format(template.fetch('instructions'), id: id),
        'criteria' => criteria.merge('none' => template.fetch('none'))
      }
    end

    def state_budget(questions)
      sizes = questions.values.map { |question| tokens(JSON.generate(question).length) }
      room = [STATE_WITH_LONGEST_QUESTION_TOKENS - sizes.max, REQUEST_TOKENS - sizes.sum].min
      (room * SAFETY * CHARS_PER_TOKEN).floor
    end

    def tokens(chars)
      (chars / CHARS_PER_TOKEN).ceil
    end

    # The diff goes first, then the MR and Jira sections; the candidates and
    # their evidence are never cut. nil — does not fit even then.
    def fit(state, budget)
      %w[diff requirements].each do |key|
        break if size(state) <= budget

        state = shrink(state, key, budget) if state[key]
      end
      size(state) <= budget ? state : nil
    end

    # Every character of the text takes at least one character of JSON, so
    # cutting the overflow in characters is enough; the marker costs its
    # length plus the escaped newline.
    def shrink(state, key, budget)
      text = state[key].to_s
      keep = text.length - (size(state) - budget) - TRUNCATED.length - 2
      state.merge(key => keep.positive? ? "#{text[0, keep]}\n#{TRUNCATED}" : TRUNCATED)
    end

    def size(state)
      JSON.generate(state).length
    end

    def coverage_notes(coverage)
      return nil if coverage.nil? || coverage.complete?

      notes = coverage.truncated_sections.map { |label| "#{label} truncated" }
      notes << "files not shown: #{coverage.files_not_shown.join(', ')}" unless coverage.files_not_shown.empty?
      notes += coverage.files_partial.map { |file| "#{file[:path]}: #{file[:shown]} of #{file[:total]} hunks shown" }
      notes << "diff not available: #{coverage.files_unavailable.join(', ')}" unless coverage.files_unavailable.empty?
      notes
    end

    # The hunk the line falls into; the whole shown diff of the file when
    # the line is unknown or the anchoring check left a note.
    def with_evidence(candidate, sections)
      section = sections[candidate['file'].to_s] || sections[candidate['file'].to_s.sub(%r{\A(?:\./|[ab]/)}, '')]
      evidence = if section.nil?
                   NOT_SHOWN
                 elsif candidate['line'].is_a?(Integer) && !candidate['note']
                   hunk = section[:hunks].find { |item| item[:range].cover?(candidate['line']) }
                   hunk ? hunk[:text] : section[:text]
                 else
                   section[:text]
                 end
      candidate.merge('evidence' => evidence)
    end

    # The shown diff by file: its whole text and every hunk with the range of
    # new-file lines it covers (the headers as CandidateChecker reads them).
    def diff_sections(diff_text)
      sections = {}
      section = nil
      diff_text.to_s.each_line do |line|
        if (header = line.match(CandidateChecker::FILE_HEADER))
          section = {text: +'', hunks: []}
          header.captures.map(&:strip).each { |path| sections[path] = section }
        elsif section && (hunk_header = line.match(CandidateChecker::HUNK_HEADER))
          section[:hunks] << new_hunk(hunk_header)
        end
        add_line(section, line) if section
      end
      sections
    end

    def new_hunk(header)
      start = header[1].to_i
      length = header[2] ? header[2].to_i : 1
      {range: start..(start + length - 1), text: +''}
    end

    def add_line(section, line)
      section[:text] << line
      section[:hunks].last[:text] << line unless section[:hunks].empty?
    end

    # The estimate goes to the log next to the input_tokens Jev reports, to
    # check CHARS_PER_TOKEN against real requests. When Jev rejects a request
    # as too large after all (the estimate missed), its candidates are asked
    # about one by one; one that is too large alone is unverifiable.
    def ask(request, asked, context, sections)
      ids = request.candidates.map { |candidate| candidate['id'] }
      return asked.unfit.concat(ids) unless request.state

      chars = size(request.state) + request.questions.values.sum { |question| JSON.generate(question).length }
      @logger.info("Jev request estimated at ~#{tokens(chars)} tokens (#{chars} chars of state and questions)")
      asked.requests += 1
      result = @client.evaluate(state: request.state, questions: request.questions)
      asked.answers.merge!(result.answers)
      asked.model = result.model
    rescue JevError => e
      raise unless e.status == 422 && e.message.match?(SIZE_ERROR)

      ask_separately(request, asked, context, sections, e)
    end

    def ask_separately(request, asked, context, sections, error)
      ids = request.candidates.map { |candidate| candidate['id'] }
      if ids.size == 1
        @logger.warn("Jev rejected the request about #{ids.first} as too large, " \
                     "it stays unverifiable: #{error.message}")
        return asked.unfit.concat(ids)
      end

      @logger.warn("Jev rejected the request as too large, asking about each candidate separately: #{error.message}")
      request.candidates.each do |candidate|
        ask(build_request(context, [candidate], sections), asked, context, sections)
      end
    end

    def decide(candidate, answers, unfit)
      id = candidate['id']
      numbers = numbers(id, answers)
      assessment = ->(decision, reason) { Assessment.new(id: id, decision: decision, reason: reason, answers: numbers) }
      if unfit.include?(id)
        return assessment.call(:unverifiable, 'the candidate and its evidence do not fit a Jev request')
      end
      if numbers[:version_claim] >= @thresholds[:version_claim]
        return assessment.call(:reject, 'claims that a version does not exist')
      end
      if numbers[:enough_context] < @thresholds[:enough_context]
        return assessment.call(:unverifiable, 'not enough context in the request')
      end

      if numbers[:real_issue] >= @thresholds[:keep_above]
        assessment.call(:keep, 'real issue')
      else
        assessment.call(:reject, 'not a confirmed issue')
      end
    end

    def numbers(id, answers)
      noul = ->(name) { answers.dig("#{name}_#{id}", 'noul') }
      choice = lambda do |name|
        answer = answers["#{name}_#{id}"]
        answer && {choice: answer['choice'], confidence: answer['confidence']}
      end
      {
        real_issue: noul.call('real_issue'), enough_context: noul.call('enough_context'),
        version_claim: noul.call('version_claim'), duplicate_of: choice.call('duplicate_of'),
        severity: choice.call('severity')
      }.compact
    end

    def drop_duplicates(assessments, candidates, answers)
      kept_ids = assessments.select { |assessment| assessment.decision == :keep }.map(&:id)
      kept = candidates.select { |candidate| kept_ids.include?(candidate['id']) }
      dropped = self.class.duplicates(kept, answers, threshold: @thresholds[:duplicate])
      assessments.map do |assessment|
        winner = dropped[assessment.id]
        next assessment unless winner

        Assessment.new(id: assessment.id, decision: :reject, reason: "duplicate of #{winner}",
                       answers: assessment.answers)
      end
    end
  end
end
