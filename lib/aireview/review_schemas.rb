# frozen_string_literal: true

module Aireview
  module ReviewSchemas
    module_function

    def generate
      <<~SCHEMA.strip
        {
          "summary": "1-2 предложения о сути изменений в MR",
          "candidates": [
            {
              "id": "C1",
              "file": "path/from/diff.rb",
              "line": 42,
              "quoted_code": "изменённый фрагмент кода",
              "problem": "текст замечания",
              "why": "почему это важно",
              "suggestion": "что исправить или проверить",
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
              "reason": "почему замечание подтверждено",
              "refinement": {
                "problem": "уточнённый текст замечания",
                "why": "почему это действительно проблема",
                "suggestion": "что исправить или проверить",
                "category": "bug",
                "severity": "major"
              }
            },
            {
              "id": "C2",
              "decision": "reject",
              "reason": "почему замечание отклонено"
            }
          ]
        }
      SCHEMA
    end
  end
end
