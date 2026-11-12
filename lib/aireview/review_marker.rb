# frozen_string_literal: true
require 'digest'
require 'json'

module Aireview
  # A hidden marker in the note body: it lets the review find its own
  # comment and tell whether anything that affects the result changed.
  module ReviewMarker
    PATTERN = /<!--\s*aireview:key=([0-9a-f]+)\s*-->/

    module_function

    def build(key)
      "<!-- aireview:key=#{key} -->"
    end

    def extract(body)
      match = PATTERN.match(body.to_s)
      match && match[1]
    end

    # The key is computed from the assembled prompts, not from a single SHA:
    # that way the diff, the MR description, the Jira context, the review
    # instructions and ignore_paths enter it by themselves. What else affects
    # the result — provider, model and temperature of the stages, the shared
    # pool with its critique policy, Jev as the critique engine — is known by
    # Config#result_signature. Without a pool the key is the same as before.
    # The LLM Critique counts only when it can run (its prompt is there),
    # Jev only when it decides (its question templates are there): with the
    # default engine the key is what it was before Jev. Files the platform did
    # not return never reach the prompts, yet the report counts them: a
    # nonzero count enters the key, zero leaves it as before.
    def key(prompts:, config:)
      signature = config.result_signature
      source = {
        'generate' => [*signature['generate'], prompts[:generate_prompt]],
        'critique' => prompts[:critique_prompt] ? [*signature['critique'], prompts[:critique_prompt]] : nil
      }
      jev = prompts[:jev_questions]
      source['critique_engine'] = [*signature['critique_engine'], jev] if jev
      source['pool'] = signature['pool'] if signature['pool']
      missing = prompts[:coverage]&.files_not_returned.to_i
      source['files_not_returned'] = missing if missing.positive?

      Digest::SHA256.hexdigest(JSON.generate(source))[0, 16]
    end

    # What makes a review result stale: a new commit, a target branch change,
    # a rebase that moves the comparison base, and an edit of the title or
    # the description — the requirements the review checks the code against
    # come from those.
    def state(merge_request)
      {
        'sha' => merge_request['sha'],
        'target_branch' => merge_request['target_branch'],
        'diff_refs' => merge_request['diff_refs'],
        'title' => merge_request['title'],
        'description' => merge_request['description']
      }
    end
  end
end
