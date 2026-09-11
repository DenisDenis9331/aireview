# frozen_string_literal: true

module Aireview
  module ReviewSchemas
    module_function

    def generate
      <<~SCHEMA.strip
        {
          "summary": "1-2 sentences about the essence of the MR changes",
          "candidates": [
            {
              "id": "C1",
              "file": "path/from/diff.rb",
              "line": 42,
              "quoted_code": "changed code fragment",
              "problem": "finding text",
              "why": "why it matters",
              "suggestion": "what to fix or check",
              "category": "bug",
              "severity": "major"
            }
          ]
        }
      SCHEMA
    end

    def critique
      <<~SCHEMA.strip
        {
          "verdicts": [
            {
              "id": "C1",
              "decision": "keep",
              "reason": "why the finding is confirmed",
              "refinement": {
                "problem": "refined finding text",
                "why": "why this is really a problem",
                "suggestion": "what to fix or check",
                "category": "bug",
                "severity": "major"
              }
            },
            {
              "id": "C2",
              "decision": "reject",
              "reason": "why the finding is rejected"
            }
          ]
        }
      SCHEMA
    end
  end
end
