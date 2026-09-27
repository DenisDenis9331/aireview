# frozen_string_literal: true
require 'json'
require 'logger'
require_relative 'errors'
require_relative 'utils'
require_relative 'jev_client'
require_relative 'jev_critic'

module Aireview
  # llm.jev.shadow: after the LLM Critique the same candidates go to Jev, and
  # its decisions are logged next to the Critique verdicts. The review result
  # and the review key do not depend on it, and a Jev failure is a warning:
  # this is data for choosing thresholds, not a check.
  class JevShadow
    def initialize(config:, scrub:, logger: Logger.new($stderr), critic: nil)
      @config = config
      @scrub = scrub
      @logger = logger
      @critic = critic
    end

    # accepted — what the LLM Critique kept; only the ids are compared.
    def run(context:, candidates:, accepted:)
      critic = self.critic
      return @logger.warn('Jev shadow skipped: JEV_API_KEY is not set') unless critic

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = critic.assess(context: context, candidates: candidates)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      log(result, accepted.map { |candidate| (candidate['id'] || candidate[:id]).to_s }, seconds)
    rescue JevError => e
      @logger.warn("Jev shadow failed, the review is not affected: #{e.message}")
    # The shadow is an experiment running in real review jobs: a bug in it
    # must not cost a review either, but it must stay visible as a bug.
    rescue StandardError => e
      @logger.warn("Jev shadow crashed, the review is not affected: #{e.class}: #{e.message} " \
                   "(#{e.backtrace&.first})")
    end

    private

    def critic
      return @critic if @critic
      return nil if Aireview::Utils.blank?(@config.jev_api_key)

      client = JevClient.new(config: @config, logger: @logger)
      @critic = JevCritic.new(client: client, thresholds: @config.jev_thresholds,
                              review_instructions: @config.review_instructions, scrub: @scrub, logger: @logger)
    end

    def log(result, critique_kept, seconds)
      result.assessments.each do |assessment|
        critique = critique_kept.include?(assessment.id) ? 'keep' : 'reject'
        @logger.info("Jev shadow #{assessment.id}: #{assessment.decision} (#{assessment.reason}; " \
                     "#{numbers(assessment.answers)}), critique: #{critique}")
      end
      @logger.info("Jev shadow: #{summary(result.assessments, critique_kept)} " \
                   "(model=#{result.model}, requests=#{result.requests}, #{format('%.1fs', seconds)})")
      @logger.info("Jev shadow data: #{JSON.generate(data(result, critique_kept))}")
    end

    # The lines above round for reading; thresholds are chosen from this one,
    # which keeps the numbers exactly as Jev returned them.
    def data(result, critique_kept)
      {
        model: result.model,
        candidates: result.assessments.map do |assessment|
          {id: assessment.id, decision: assessment.decision, reason: assessment.reason,
           critique: critique_kept.include?(assessment.id) ? 'keep' : 'reject', **assessment.answers}
        end
      }
    end

    def numbers(answers)
      answers.map do |name, value|
        value.is_a?(Hash) ? "#{name}=#{value[:choice]}/#{round(value[:confidence])}" : "#{name}=#{round(value)}"
      end.join(' ')
    end

    def summary(assessments, critique_kept)
      decided = assessments.reject { |assessment| assessment.decision == :unverifiable }
      agreed = decided.count do |assessment|
        (assessment.decision == :keep) == critique_kept.include?(assessment.id)
      end
      counts = %i[keep reject unverifiable].map do |decision|
        "#{decision} #{assessments.count { |assessment| assessment.decision == decision }}"
      end
      "agrees with critique on #{agreed} of #{decided.size} decided candidate(s); #{counts.join(', ')}"
    end

    def round(value)
      value.is_a?(Numeric) ? value.round(2) : value
    end
  end
end
