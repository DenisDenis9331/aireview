# frozen_string_literal: true
require 'ruby_llm/schema'

module Aireview
  module OutputSchemaValues
    CATEGORIES = %w[
      task_mismatch
      bug
      regression
      security
      performance
      data_loss
      edge_case
      test_gap
      maintainability
    ].freeze
    SEVERITIES = %w[critical major minor].freeze
    DECISIONS = %w[keep reject].freeze
  end

  class GenerateOutputSchema < RubyLLM::Schema
    string :summary
    array :candidates, max_items: 3 do
      object do
        string :id
        string :file
        any_of :line do
          integer
          null
        end
        string :quoted_code
        string :problem
        string :why
        string :suggestion
        string :category, enum: OutputSchemaValues::CATEGORIES
        string :severity, enum: OutputSchemaValues::SEVERITIES
      end
    end
  end

  class CritiqueOutputSchema < RubyLLM::Schema
    array :verdicts do
      object do
        string :id
        string :decision, enum: OutputSchemaValues::DECISIONS
        string :reason
        object :refinement, required: false do
          string :problem
          string :why
          string :suggestion
          string :category, enum: OutputSchemaValues::CATEGORIES
          string :severity, enum: OutputSchemaValues::SEVERITIES
        end
      end
    end
  end
end
