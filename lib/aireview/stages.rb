# frozen_string_literal: true

module Aireview
  # The two review stages: Generate finds the findings, Critique checks them.
  # The single definition; inside the code a stage is a string.
  STAGES = %w[generate critique].freeze
end
