# Changelog

## 2.0.0

Breaking: the review key of a shared pool includes the pool order and the
critique policy; a single chain without reserves gets three requests instead
of a seventeen-minute schedule; `LLM_PROVIDER` no longer re-targets models
that carry an explicit provider.

- Defaults shipped in the image: `config/defaults.yml` is a configuration
  layer between the built-in values and the project's `.aireview.yml`,
  enabled by `AIREVIEW_DEFAULTS` (set in the Dockerfile). A project needs no
  model names; `--dry-run` prints the layer every setting came from and
  warns when inherited reserves silently change provider.
- Shared model pool: `llm.models` (`LLM_MODELS`) in order of priority,
  `generate.start`, `critique.rank: not_below_generate|any` and
  `critique.allow_weaker`. Generate walks the pool round from its start;
  Critique takes the first live model not below the one that answered in
  Generate, never weaker unless allowed. A stage with a `model` of its own
  keeps an independent chain.
- Router: an overloaded model or a timeout gets one short retry, then a
  quarantine (`llm.overloaded_quarantine`, `LLM_OVERLOADED_QUARANTINE`,
  120 s) and the next model; the walk goes round the pool once every model
  has been tried, waiting for the nearest quarantine to end. Three requests
  per model per stage, counted across keys and including the JSON repair;
  the last model has no special schedule. A model the provider does not
  have (retired, a typo, not pulled into Ollama) is excluded for the run
  instead of failing it; a bare 404 stays fatal.
- An invalid result that the same model cannot repair excludes that model
  for the stage and restarts the stage on the next model with the original
  request; Critique keeps the candidates already obtained.
- `aireview models check`: two probe requests per model with the production
  schemas and validation, statuses `ok / missing / invalid / unverified /
  failed / skipped`, `--strict` turns a skipped (unreachable) Ollama into a
  failure. Meant for release pipelines and schedules.
- `templates/review.gitlab-ci.yml`: a job template projects include with
  `ref: stable`; every config variable is passed into the container by name.
- The log names the model that answered each stage and its place in the
  chain; the report notes a critique that ran on a weaker model.
- Fixed: with `json` 3.0 every provider answer failed to parse
  (`Faraday::ParsingError`, "wrong number of arguments") — `faraday` 2.14.4
  in the lockfile. The suite did not catch it because it stubs the network;
  `aireview models check` did.
- Internals: routing plans (`StageChains`, `ModelPool`) and the router's
  `ModelState` are objects, `ConfigLoader` owns loading and env parsing,
  `ResultParser` parses LLM results, `LlmClient` makes one request while
  the router retries. Specs run against the real RubyLLM classes.

## 0.3.0

- Fallback models per stage (`llm.<stage>.fallbacks`,
  `LLM_<STAGE>_FALLBACK_MODEL`) and fallback API keys (`GEMINI_API_KEYS`).
  An overloaded model or a timeout switches to the next model after one
  short retry; an exhausted daily quota switches to the next key without
  waiting; the last route keeps the full retry schedule.
- A time budget for the LLM part of the run (`llm.time_budget`,
  `LLM_TIME_BUDGET`, 30 minutes by default) bounds pauses and request
  timeouts; the built-in RubyLLM retries are disabled.
- The report names the fallback model a stage used; `--dry-run` prints the
  chains and the number of keys; `--no-fallbacks` disables the reserves.
- Candidates are checked against the diff shown to the model: a file outside
  the merge request drops the candidate, a line outside the shown hunks is
  reset, a quote not found in the diff is marked in the report and reported
  to Critique.
- Critique is skipped when Generate returns no candidates.
- Report limits are applied after selecting the findings to show, so a
  finding that is never shown no longer displaces a useful one.

## 0.2.1

- An overloaded LLM (503) gets a fifth attempt: the pauses are now about
  2, 5, 5 and 5 minutes. Rate limits and network errors keep their three
  retries.

## 0.2.0

- Context budget: `llm.max_prompt_chars` caps the request of each stage,
  `context.max_*_chars` cap the MR description, the Jira description and
  comments and the diff. The diff is cut by whole files and hunks, never in
  the middle of a hunk, and both stages share the same context.
- Truncation is marked in the prompt and reported in the review: the result
  line gets a `Partial review` suffix and a `Not reviewed` section lists the
  files and sections that were left out. `--dry-run` and `--verbose` show the
  sizes and the coverage.
- Renames, mode changes and empty new or deleted files are told apart from
  diffs GitLab did not return (too large, binary, empty without a reason); the
  latter are reported as not reviewed.
- Unparsable limits in the environment (`MAX_DIFF_CHARS=oops`) fail with a
  `ConfigError` instead of silently falling back to the defaults.
- A run fails with a clear error when not even one hunk fits next to the
  system prompt, or when the candidates push the Critique request over its
  limit.

## 0.1.1

- The prompts no longer ask the model to check whether dependency and image
  versions exist; candidates about nonexistent versions are rejected.
- An overloaded LLM (503) is retried up to three times with pauses of about
  2, 5 and 5 minutes instead of two retries of 1.5-2.5 minutes.

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
