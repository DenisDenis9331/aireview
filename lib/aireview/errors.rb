# frozen_string_literal: true
module Aireview
  class Error < StandardError; end
  class ConfigError < Error; end
  class ParseError < Error; end
  # Repairing invalid JSON is impossible: the model that answered is out of
  # attempts or quarantined with no budget to wait. For the pipeline it is
  # the same as an invalid result — the stage restarts on another model.
  class RepairImpossibleError < ParseError; end
  class ApiError < Error; end
  # A pinned route (the JSON repair by the same model) could not answer: out
  # of attempts, excluded, or quarantined with no budget to wait. Not fatal
  # for the run — the stage restarts on another model.
  class RouteExhaustedError < ApiError; end
  class ContextBudgetError < Error; end
  class HelpRequested < Error; end
end
