# Changelog

## 0.1.0

Initial release.

- Two-pass review of self-hosted GitLab merge requests: Generate finds
  candidate findings, Critique filters out the weak ones.
- Gemini and local Ollama providers via RubyLLM, with a separate provider,
  model and temperature per stage.
- Optional Jira issue context and per-project `review_instructions`.
- Path filtering and secret scrubbing before the diff reaches the LLM.
- A single updatable review note per merge request with `update` and `once`
  modes, Retry detection in GitLab CI and a staleness check before posting.
- `.aireview.yml` and `.env` discovery walking up from the working directory.
