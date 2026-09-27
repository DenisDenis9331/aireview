# frozen_string_literal: true
require 'logger'
require_relative 'errors'
require_relative 'jev_critic'

module Aireview
  # The Critique stage with llm.critique.engine: jev. Jev decides keep or
  # reject; the candidates it cannot judge (not enough context, too large)
  # and, when Jev fails, all of them go to the LLM Critique with
  # llm.jev.fallback: model, or are rejected / fail the run with fail.
  # Duplicates are dropped once, over the merged verdicts of Jev and the LLM:
  # neither side sees what the other kept.
  class JevStage
    # The report line: :jev (Jev decided everything), :jev_partial (some
    # went to the LLM), :jev_failed (the LLM decided everything).
    Outcome = Struct.new(:accepted, :note, keyword_init: true)

    def initialize(config:, critic:, logger: Logger.new($stderr))
      @config = config
      @critic = critic
      @logger = logger
    end

    # llm_critique — the LLM Critique of the pipeline for a subset of the
    # candidates; returns the kept ones, refined.
    def run(context:, candidates:, llm_critique:)
      @logger.info("Pipeline critique pass started (engine=jev, model=#{@config.jev_model})")
      begin
        result = @critic.assess(context: context, candidates: candidates, dedupe: false)
      rescue JevError => e
        return fall_back(e, candidates, llm_critique)
      end
      result.assessments.each { |assessment| log(assessment) }

      unverifiable = pick(candidates, result, :unverifiable)
      accepted = pick(candidates, result, :keep) + judge_unverifiable(unverifiable, llm_critique)
      accepted = drop_duplicates(in_generate_order(accepted, candidates), result.answers)
      @logger.info("Pipeline critique pass completed with #{accepted.size} kept candidate(s) (engine=jev, " \
                   "model=#{result.model}, requests=#{result.requests})")
      Outcome.new(accepted: accepted, note: unverifiable.empty? || fail? ? :jev : :jev_partial)
    end

    private

    def fail?
      @config.jev_fallback == 'fail'
    end

    def fall_back(error, candidates, llm_critique)
      if fail?
        raise JevError.new("Jev critique failed and llm.jev.fallback is fail: #{error.message}", status: error.status)
      end

      @logger.warn("Jev critique failed, the LLM critique takes over (llm.jev.fallback: model): #{error.message}")
      Outcome.new(accepted: llm_critique.call(candidates), note: :jev_failed)
    end

    def judge_unverifiable(unverifiable, llm_critique)
      return [] if unverifiable.empty?

      ids = unverifiable.map { |candidate| id_of(candidate) }.join(', ')
      if fail?
        @logger.info("Critique reject #{ids}: Jev could not judge them and llm.jev.fallback is fail")
        return []
      end

      @logger.info("Pipeline critique: #{ids} go to the LLM critique, Jev could not judge them " \
                   "(model=#{@config.critique_model})")
      llm_critique.call(unverifiable)
    end

    def pick(candidates, result, decision)
      ids = result.assessments.select { |assessment| assessment.decision == decision }.map(&:id)
      candidates.select { |candidate| ids.include?(id_of(candidate)) }
    end

    def in_generate_order(accepted, candidates)
      order = candidates.map { |candidate| id_of(candidate) }
      accepted.sort_by { |candidate| order.index(id_of(candidate)) || order.size }
    end

    def drop_duplicates(accepted, answers)
      dropped = JevCritic.duplicates(accepted, answers, threshold: @config.jev_thresholds[:duplicate])
      dropped.each { |id, winner| @logger.info("Critique reject #{id}: duplicate of #{winner} (Jev)") }
      accepted.reject { |candidate| dropped.key?(id_of(candidate)) }
    end

    def log(assessment)
      message = "Critique (jev) #{assessment.decision} #{assessment.id}: #{assessment.reason} (#{assessment.numbers})"
      assessment.decision == :keep ? @logger.debug(message) : @logger.info(message)
    end

    def id_of(candidate)
      (candidate['id'] || candidate[:id]).to_s.strip
    end
  end
end
