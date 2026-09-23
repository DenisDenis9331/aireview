# aireview

`aireview` is a local CLI tool that reviews GitLab merge requests with the help
of LLMs. It uses a two-pass review pipeline: the first pass finds candidate
findings, the second one critiques them and drops the weak or invalid ones.

The tool supports self-hosted GitLab and self-hosted Jira only. GitLab.com and
Jira Cloud are not supported.

MVP flow:

1. Takes a GitLab merge request URL.
2. Fetches the MR metadata and changes from GitLab.
3. Filters out ignored paths and scrubs secrets from the diffs.
4. Optionally enriches the prompt with context from a Jira issue.
5. Runs the Generate pass through RubyLLM to get an MR summary and candidate
   findings.
6. Optionally runs the Critique pass, which returns a verdict for every
   candidate id.
7. Renders the final markdown review to stdout or posts it back to the merge
   request.

## Requirements

- Ruby 3.1.3 or newer (CI runs the tests on 3.1, 3.3, 3.4 and 4.0)
- Bundler 2.3.26 for the repository checkout; `gem install` needs no specific Bundler
- A GitLab personal access token
- An API key for a remote LLM provider; a local Ollama needs no key
- Optionally, a Jira login and password

## Installation

From RubyGems:

```bash
gem install aireview
aireview --help
```

From a checkout of the repository:

```bash
bundle _2.3.26_ install
bundle _2.3.26_ exec bin/aireview --help
```

The examples below use `bundle _2.3.26_ exec bin/aireview`; with the gem
installed, replace it with plain `aireview`.

## Configuration

Secrets live in environment variables or in a local `.env` file. The models of
both stages come from the defaults shipped in the Docker image (see "Defaults
shipped in the image"); outside the image they are set in `.env` or
`.aireview.yml`:

```bash
GITLAB_URL=https://gitlab.company.com
GITLAB_TOKEN=glpat-xxx
JIRA_URL=https://jira.company.com
JIRA_LOGIN=user
JIRA_PASSWORD=xxx
GEMINI_API_KEY=xxx
GEMINI_API_KEYS=xxx,yyy
LLM_PROVIDER=gemini
LLM_TEMPERATURE=0
LLM_TIMEOUT=120
LLM_TIME_BUDGET=1800
LLM_HTTP_PROXY=http://127.0.0.1:8888
LLM_GENERATE_PROVIDER=gemini
LLM_GENERATE_MODEL=gemini-3.7-flash
LLM_GENERATE_FALLBACK_MODEL=gemini-3.8-flash
LLM_GENERATE_TEMPERATURE=0.3
LLM_CRITIQUE_PROVIDER=gemini
LLM_CRITIQUE_MODEL=gemini-3.8-flash
LLM_CRITIQUE_FALLBACK_MODEL=gemini-3.7-flash
LLM_CRITIQUE_TEMPERATURE=0
REVIEW_LANGUAGE=ru
REVIEW_MODE=update
```

At the moment only the `gemini` and `ollama` providers are supported. The
provider and the model of each stage are set through `LLM_GENERATE_PROVIDER`,
`LLM_GENERATE_MODEL`, `LLM_CRITIQUE_PROVIDER` and `LLM_CRITIQUE_MODEL`.
`LLM_PROVIDER` stays the shared default when a stage has no provider of its
own.

`REVIEW_LANGUAGE` (or `review_language` in `.aireview.yml`) sets the language
of the review: both the LLM answers and the headings of the rendered report.
`en` is the default; `ru` is supported as well.

If only the LLM traffic has to go through a proxy, set `LLM_HTTP_PROXY` or
`llm.http_proxy`. That configures RubyLLM only; requests to GitLab and Jira
keep going directly.

### Defaults shipped in the image

Models, timeouts and the report language are baked into the image as
`config/defaults.yml`; inside the image `AIREVIEW_DEFAULTS` points at it. A
project in an organization has nothing to configure: no `.aireview.yml`, no
variables with model names. Changing the model for every project is one
edit of that file and a new image release. Outside the image the variable is
unset and the layer does not exist, so local runs are unaffected; point
`AIREVIEW_DEFAULTS` at any file to get the same layer elsewhere. The
defaults define a shared pool of five Gemini models (see "Shared model
pool"): Generate starts from a mid-range model and goes round the pool,
Critique takes the strongest live model not below the one Generate answered
with; every model of the pool is confirmed by `aireview models check` on
release.

The configuration layers, weakest first:

1. built-in values (`Config::DEFAULTS`);
2. image defaults — the file from `AIREVIEW_DEFAULTS`; no variable, no layer;
3. the project's `.aireview.yml`;
4. environment variables (`LLM_GENERATE_MODEL` and the rest);
5. CLI flags (`--generate-model`, `--critique-model`, the temperatures).

Layers merge by key, so a project overrides only what it needs — with two
caveats about the pool:

- a `llm.generate.model` of its own (in YAML or `LLM_GENERATE_MODEL`) **takes
  the stage out of the pool**: its chain is that model plus its own
  `fallbacks`, if any; the image models are not picked up for that stage and
  the critique rank rule does not apply. To change only the starting model
  while staying in the pool, set `llm.generate.start` / `LLM_GENERATE_START`
  — or replace the whole pool through `llm.models` / `LLM_MODELS`;
- every pool model in the image carries an explicit provider (`gemini`), so
  `LLM_PROVIDER=ollama` on its own does not move the Gemini pool to Ollama:
  it only changes the default provider of models without one. A project on
  Ollama sets its own models — its own pool (`LLM_MODELS=ollama/qwen2.5-coder:7b,…`)
  or per-stage `model`s.

The shared settings `llm.temperature`, `llm.max_prompt_chars` and the default
provider `llm.provider` (env: `LLM_TEMPERATURE`, `LLM_MAX_PROMPT_CHARS`,
`LLM_PROVIDER`) apply to the stages layer by layer: a stage value from the
image defaults does not beat a shared value from the project or the
environment, while within one layer the stage value still wins. For stages
on their own chains the `fallbacks` array is replaced as a whole when given
explicitly; `fallbacks: []` removes the reserves; a reserve without a
`provider` of its own inherits the stage provider — if a project overrode the
stage provider (`LLM_GENERATE_PROVIDER=ollama`) while inherited reserves
without an explicit provider remain in the chain, they silently become
"models" of the new provider. `--dry-run` warns about that and prints, for
every model, the layer it came from:

```
=== LLM SETTINGS ===
Config: image defaults /app/config/defaults.yml, .aireview.yml /app/.aireview.yml
Generate: gemini-3.7-flash temperature=0.1 (model from image defaults, provider from image defaults)
  fallbacks: gemini/gemini-3.6-flash -> ... (fallbacks from image defaults)
Critique: qwen2.5-coder:7b temperature=0 (model from .aireview.yml, provider from .aireview.yml)
Time budget: 1800s, overloaded quarantine: 120s
```

In pool mode the model source is the layer that set the stage `start` or the
`llm.models` list itself; `--critique-model` with a pool model shows up as
`model from cli`.

An `AIREVIEW_DEFAULTS` that points at a missing file is a configuration
error: such an image was built wrong, and failing at once beats reviewing
with the wrong models. Keys and tokens never live in `config/defaults.yml`.

Changing the default models or the pool order changes the review key (see "A
single comment per merge request"). What happens to open MRs depends on
`review_mode`: in `update` the review re-runs on the next push to the MR, in
`once` (as in the CI template) only on a job Retry. In `update` this is a
one-off burst of requests to the provider — better not to ship such a
release at peak hours.

No model is probed before a review: there are no test requests to five
models per MR, availability is learned from the working requests — the first
Generate request is the probe, and what the router learns it remembers until
the end of the run (see "Fallback models and keys"). The separate smoke test
of every model with both schemas (`aireview models check`) runs on an image
release and on a schedule, not on MRs.

### Local Ollama

Install Ollama following the
[official guide](https://docs.ollama.com/quickstart), then pull a local model,
[`qwen2.5-coder:7b`](https://ollama.com/library/qwen2.5-coder:7b):

```bash
ollama pull qwen2.5-coder:7b
```

If the service did not start on its own, start it separately and leave it
running during the review:

```bash
ollama serve
```

For a decent result use a stronger model for Critique than for Generate. For
example, to generate through a local Ollama and critique through Gemini,
configure `.env` like this:

```bash
LLM_GENERATE_PROVIDER=ollama
LLM_GENERATE_MODEL=qwen2.5-coder:7b
LLM_GENERATE_TEMPERATURE=0
LLM_CRITIQUE_PROVIDER=gemini
LLM_CRITIQUE_MODEL=gemini-3.8-flash
LLM_CRITIQUE_TEMPERATURE=0
OLLAMA_API_BASE=http://localhost:11434/v1
GEMINI_API_KEY=xxx
LLM_TIMEOUT=300
```

Ollama models that have been verified:

- `qwen2.5-coder:7b`
- `qwen2.5-coder:14b`
- `qwen3:8b`
- `qwen3:14b`
- `gpt-oss:20b`

The context window size is configured on the machine that runs Ollama. For a
permanent setting on Linux, open the service configuration:

```bash
sudo systemctl edit ollama.service
```

Add the setting:

```ini
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=8192"
```

Then apply it and restart Ollama:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

When the server is started by hand, the context can only be set for the current
process:

```bash
OLLAMA_CONTEXT_LENGTH=8192 ollama serve
```

A local Ollama needs no API key. The providers can be swapped by changing
`LLM_GENERATE_PROVIDER`, `LLM_CRITIQUE_PROVIDER` and the corresponding models.
To run both stages locally, set `ollama` in both provider variables. The
address with `/v1` matches the
[Ollama configuration in RubyLLM](https://rubyllm.com/configuration/#provider-configuration).
`LLM_TIMEOUT` sets the timeout of every LLM request in seconds; for a slow
local model it can be raised, but not without limit: a hung request holds
the job for exactly that long while a fallback model sits idle. An
"overloaded" (503) answer from the provider or a timeout does not fail the
run right away: the model gets one short retry (~30 s), then goes into
quarantine for two minutes while the request goes to the next model;
without a fallback model the router waits for the quarantine to end and
tries once more. Three requests per model per stage in total (see "Fallback
models and keys"). Only the failed stage is repeated, not the whole run.

Project rules live in `.aireview.yml`. The `generate.model` and
`critique.model` settings are not inherited from the base `llm` settings: a
review does not start when a stage has no model in the image defaults, the
YAML or the environment. `llm.provider` is used as the default when
`generate.provider` or `critique.provider` is not set:

```yaml
ignore_paths:
  - db/migrate/**
  - vendor/**
  - node_modules/**
  - "*.lock"

secret_patterns:
  - 'api_key\s*=\s*["'\''].*["'\'']'
  - 'SECRET_[A-Z_]+'

secret_files:
  - .env
  - .env.*
  - config/secrets.yml
  - config/credentials/*.key
  - spec/fixtures/cassettes/*.yml
  - spec/fixtures/cassettes/**/*.yml
  - spec/cassettes/*.yml
  - spec/cassettes/**/*.yml
  - test/fixtures/cassettes/*.yml
  - test/fixtures/cassettes/**/*.yml

review_instructions: |
  This is a Rails project. Pay attention to:
  - N+1 queries
  - strong params
  - missing tests for new logic
  Ignore style — that is what the linters are for.

ollama_api_base: http://localhost:11434/v1

context:
  max_diff_chars: 120000
  max_mr_description_chars: 8000
  max_jira_description_chars: 8000
  max_jira_comment_chars: 2000

llm:
  provider: gemini
  temperature: 0
  timeout: 120
  time_budget: 1800
  http_proxy: http://127.0.0.1:8888
  max_prompt_chars: 400000
  generate:
    provider: gemini
    model: gemini-3.7-flash
    temperature: 0.3
    fallbacks:
      - gemini-3.8-flash
      - provider: ollama
        model: qwen2.5-coder:7b
        max_prompt_chars: 20000
  critique:
    provider: ollama
    model: qwen2.5-coder:7b
    temperature: 0
    max_prompt_chars: 60000
```

### Context budget

The request to each stage is capped by `llm.max_prompt_chars` (or
`LLM_MAX_PROMPT_CHARS`; per stage `llm.generate.max_prompt_chars` /
`LLM_GENERATE_MAX_PROMPT_CHARS` and the same for `critique`). The limits are in
characters, not tokens: there is no exact tokenizer for the providers locally,
and the Ollama window is set on the server where the client cannot see it. As
a rule of thumb one token is three to four characters, so for a local model
with `OLLAMA_CONTEXT_LENGTH=8192` set the stage limit to about 20 000
characters to leave room for the answer.

The MR and Jira context is assembled once per run and shared by both stages,
so it is sized for the tighter of the two: the Critique stage also has to fit
its system prompt and a reserve for the candidates. The sections are cut to
their own limits first, keeping the beginning: `context.max_diff_chars`,
`context.max_mr_description_chars`, `context.max_jira_description_chars` and
`context.max_jira_comment_chars` (`MAX_DIFF_CHARS`, `MAX_MR_DESCRIPTION_CHARS`,
`MAX_JIRA_DESCRIPTION_CHARS`, `MAX_JIRA_COMMENT_CHARS`). Only then is the diff
cut, and only by whole files and whole hunks: files in the order GitLab returns
them, a file that does not fit is shown hunk by hunk, everything after it is
left out, and a single hunk larger than the whole budget is skipped rather
than cut in the middle. Renames, mode changes and other files without text
changes are always listed; files whose diff GitLab did not return (too large,
binary) are listed as well and reported as not reviewed.

Everything that was cut is marked in the prompt, so the model knows that a
missing requirement or missing code may simply be outside the budget. The
review reports it too: the result line gets a `Partial review: ...` suffix
and a `Not reviewed` section lists the files and sections concerned. The
result itself (`ok` / `needs attention`) is still only about the findings.

When even one hunk cannot fit next to the system prompt, or the candidates
returned by Generate push the Critique request over its limit, the run stops
with an error instead of silently reviewing less. Raise the limits or extend
`ignore_paths`. `--dry-run` prints the sizes of every part and the coverage;
`--verbose` logs them during a real run.

### Fallback models and keys

The primary model can sit under load (503) for half a day, and a key can run
out of its daily quota. Neither is cured by waiting, so a stage can have a
fallback model and a provider can have a fallback key:

- `llm.generate.fallbacks` / `llm.critique.fallbacks` in YAML or
  `LLM_GENERATE_FALLBACK_MODEL` / `LLM_CRITIQUE_FALLBACK_MODEL` in the
  environment. One model or several separated by commas, in the order they
  are tried. The provider goes before a slash (`ollama/qwen2.5-coder:7b`);
  without it the stage provider is used. A fallback model can have its own
  `max_prompt_chars`: when the assembled request does not fit, that model is
  skipped, the context is not cut for it.
- `GEMINI_API_KEYS=key1,key2`: keys in order of preference; `GEMINI_API_KEY`
  still works and means a single key. Google counts quotas per Google Cloud
  project and per model, so a reserve key only makes sense from another
  project. Use fallback credentials in compliance with the provider's quota
  and billing terms: Google's
  [API limitations](https://developers.google.com/terms#api_limitations)
  forbid circumventing its limits regardless of the project's billing. Keys
  live only in the environment, never in `.aireview.yml`.

#### Shared model pool

Instead of two independent chains a single pool can be configured:
`llm.models` in order of priority (the first is the preferred one for
Critique). Generate goes through the pool from `generate.start` downwards
and round again; Critique takes the first live model **not below the one
that actually answered in Generate** (`critique.rank: not_below_generate`,
the default), with self-critique by the same model as the last permitted
option. "Above" and "below" are positions in the list, they are not derived
from model names:

```yaml
llm:
  provider: gemini
  models:                          # order = priority for Critique
    - gemini-3.8-flash
    - gemini-3.7-flash
    - gemini-3.6-flash
    - provider: ollama
      model: qwen2.5-coder:7b
      max_prompt_chars: 20000
  generate:
    start: gemini-3.7-flash        # Generate starts here, then downwards and round
  critique:
    rank: not_below_generate       # or any — the chains are independent
    allow_weaker: false            # true — go below when nothing above is alive
```

Environment equivalents: `LLM_MODELS=gemini/gemini-3.8-flash,gemini/gemini-3.7-flash,…`,
`LLM_GENERATE_START`, `LLM_CRITIQUE_START`, `LLM_CRITIQUE_RANK`,
`LLM_CRITIQUE_ALLOW_WEAKER`. The rules:

- no permitted live model for Critique and `allow_weaker: false` — the run
  fails, candidates are not published without a critique; with
  `allow_weaker: true` Critique goes below Generate and the report gets a
  "Critique ran on a model weaker than Generate" line;
- a stage with a `model` of its own (in YAML, the environment or
  `--generate-model` with a model outside the pool) does not use the pool:
  its chain is independent and the rank rule does not apply, as with
  `rank: any`; `--generate-model` / `--critique-model` with a model **from**
  the pool bring the stage back into the pool and make that model the start
  (the stage's own `model` and `fallbacks` are reset), with a model outside
  the pool — a single chain without reserves;
- a project that replaces the whole pool (`llm.models` in YAML or
  `LLM_MODELS`) need not repeat `start`: a start inherited from the image
  that the new pool does not contain is replaced by the first model of the
  new pool with a warning in the log. A start set in the same layer as the
  pool or above it must be in the pool — a typo there stays a configuration
  error;
- `critique.start` goes first only when the rank permits it; a start below
  the model that answered in Generate is skipped with a warning when
  `allow_weaker` is off — it does not bypass the ban on a weaker critique;
- the review key (see "A single comment per merge request") includes the
  whole pool together with the critique policy: its order decides which
  model checks the findings, not just what to fall back to. Reordering the
  pool, changing `start`, `rank` or `allow_weaker` — a new key, open MRs are
  re-reviewed on the next push; moving from per-stage chains to the pool —
  the same, once;
- `--dry-run` prints the chains of both stages and a `Critique rule: …` line.

What happens on which error:

| Error | Reaction |
|---|---|
| Daily quota (`quotaId` like `…PerDay…` in Google's answer) | No retries: the next key on the same model. The "key + model" pair is remembered until the end of the run so that Critique and the JSON repair do not hit it again. Out of keys: the model is excluded until the end of the run, the request goes to the next one. |
| Per-minute limit (429 with a "retry in N s" hint) | One retry after the hinted delay, then the next key. Out of keys: the model is quarantined for the hinted time, the request goes to the next one. |
| Overloaded (503) or timeout | One short retry (~30 s), then a quarantine of `llm.overloaded_quarantine` / `LLM_OVERLOADED_QUARANTINE` (120 s by default) and the next model with the same key. |
| The provider has no such model (the answer text names the model: retired, a typo, not pulled into Ollama) | No retries: the model is excluded until the end of the run, the request goes to the next one. A bare 404 without such text is fatal: a wrong `LLM_API_BASE` answers the same, and the next model will not help. |
| An invalid result (not JSON, not the schema, foreign ids in the verdicts) — and still invalid after one repair by the same model | The model is excluded for this stage, the stage starts over on the next model with the original request. For Critique the candidates already obtained are kept, Generate is not repeated. |
| Other API errors (context length, auth) | The run fails right away: a fallback model would answer the same. |

The chain is walked round: once every model has been tried, the router
returns to those whose quarantine has expired; when all are quarantined, it
waits for the nearest release. The last model in the list is nothing
special, nobody gets a long retry schedule. Two limits keep the walk
finite:

- **three requests per model per stage** (`MAX_ATTEMPTS_PER_MODEL`). Every
  request sent counts regardless of its outcome, including the short retry
  and the JSON repair; the keys of one model share one counter, a quarantine
  does not reset it. Out of requests — the model leaves the stage; a JSON
  repair without requests left is not sent, and the result counts as invalid
  (see the table). When every model of the stage is out or excluded, the
  stage ends at once, quarantines are not waited for;
- **the time budget** of the LLM part of the run: `llm.time_budget` /
  `LLM_TIME_BUDGET`, 1800 seconds by default. A pause or a quarantine wait
  that does not fit into the remainder is skipped, the request timeout is
  capped by the remainder; when the time is up, the run fails with an error
  listing everything that was tried. Because of this keep `LLM_TIMEOUT`
  around 120–300 seconds: one hung request must not eat the whole budget.

**A single chain** — one model without reserves, typically Ollama on its own
box — behaves differently from earlier versions: instead of seventeen minutes
of waiting (retries after 2, 5, 5 and 5 minutes) the model gets three
requests — the original, a short retry after ~30 s and one more after the
two-minute quarantine; after the third failure the stage fails. A timeout is
a failure too, and a quarantine will not help a slow model: it only
lengthens the pause between attempts. A slow local model needs an
`LLM_TIMEOUT` with room for the largest request and an `LLM_TIME_BUDGET`
that fits three such requests with their pauses; `LLM_OVERLOADED_QUARANTINE`
is about a model that is temporarily overloaded and should come back.

The review key (see "A single comment per merge request") is computed from
the configured primary model, not from the one that answered: a review made
by a fallback model is not rewritten on the next push without changes in the
MR, and adding a fallback model to a per-stage chain does not re-run the
review on every open MR. When a stage went to a fallback model, the report
ends with a `Fallback model used: critique — …` line; the log names, for
every stage, the model that answered and its place in the chain
(`model=gemini/gemini-3.6-flash (2/5)`). A key switch stays in the log only,
and key values never reach the log. `--dry-run` prints the model chains, the
number of keys per provider, the time budget and the quarantine length;
`--no-fallbacks` leaves one model and one key per stage.

### Checking that findings point at the diff

Between the passes every candidate is checked against the diff that actually
went to the model (after `ignore_paths`, secret scrubbing and the budget
cut). What is checked is the link to the code, not the bug itself:

- `file` is not among the changed files of the MR (renames included): the
  candidate is dropped before Critique, there is nothing to check it
  against. A file of the MR that was left out of the context by the budget
  is a different case, see below.
- `line` falls into none of the shown hunks: the report shows the finding
  without a line number.
- `quoted_code` is not found in the shown diff (compared ignoring
  whitespace, on the new and on the old side): the candidate stays, but the
  "Where" line of the report gets `(quote not found in the diff)`. Critique
  cannot fix the quote, so the mark survives its keep.
- The file is shown partially, without a diff or not at all: the link cannot
  be checked, and the coverage block of the report already says so.

Critique receives the result of the check in the candidate's `note` field
and decides keep/reject with it in mind. With `--no-critique` the check works
the same way, its marks just go straight to the report.

## Usage

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --post
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --no-jira
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --dry-run --verbose
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --generate-model gemini-3.7-flash --critique-model gemini-3.8-flash
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --generate-model gemini-3.7-flash --generate-temperature 0.3 --critique-model gemini-3.8-flash --critique-temperature 0
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --no-critique
```

- `--generate-model MODEL` overrides the model for the Generate pass only.
- `--critique-model MODEL` overrides the model for the Critique pass only.
- `--generate-temperature VALUE` overrides the temperature for the Generate pass only.
- `--critique-temperature VALUE` overrides the temperature for the Critique pass only.
- `--config PATH` points at a specific `.aireview.yml`.
- `--no-jira` turns off the Jira enrichment even when the MR carries an issue key.
- `--dry-run` prints the LLM settings, the context sizes and coverage, and the Generate prompt, plus the Critique prompt unless `--no-critique` is given.
- `--no-critique` skips the second pass and renders the Generate candidates directly.
- `--no-fallbacks` uses only the primary model and the first API key of each stage.
- `--review-mode MODE` sets the behaviour when a review has already been published: `update` or `once`.
- `--force` reviews again even when a review for this state of the MR is already published.

### Checking the models

```bash
bundle _2.3.26_ exec bin/aireview models check
bundle _2.3.26_ exec bin/aireview models check --config .aireview.yml --strict --verbose
```

Every model of both stage chains gets two small requests — one with the
production Generate schema and one with the Critique schema — on a tiny
synthetic MR, with the same system prompts as a review. The answer goes
through the same validation as in a run (JSON shape, candidate and verdict
ids). The provider's catalog is not consulted: "the model is listed" does
not mean "our request with the schema passes on it". There are no reserves,
retries or quarantine here — this is a check, not a review; only a
per-minute limit gets one retry after the provider's hint.

```
Checking 5 model(s) with the generate and critique schemas
gemini/gemini-3.7-flash          generate ok (4.6s)
gemini/gemini-3.7-flash          critique ok (6.9s)
gemini/gemini-3.6-flash          generate unverified: This model is currently experiencing high demand. …
gemini/gemini-9.9-nope           generate missing: models/gemini-9.9-nope is not found for API version v1beta, …
ollama/qwen2.5-coder:7b          generate skipped: Connection refused
Result: 6 ok, 1 unverified, 2 missing, 2 skipped -> FAILED
```

Statuses: `ok` — an answer matching the schema; `missing` — the provider
has no such model (retired, a typo, not pulled into Ollama); `invalid` — it
answered, but not by the schema; `unverified` — the provider could not
answer right now (overload, quota, timeout), the model is not at fault but
not confirmed either; `failed` — other API errors; `skipped` — Ollama is
unreachable where the check runs (a CI runner has none). The exit code is 0
only when every model is `ok` or `skipped`; with `--strict` — only `ok`: on
a box where Ollama must be running, an unreachable Ollama is a failed check,
not a skip.

### A single comment per merge request

With `--post` the review is not published as a new note every time; it updates
its own note instead. A hidden marker `<!-- aireview:key=... -->` is embedded
into the comment body, and the review uses it to find its own note among the
others. The note is looked up across all pages of the discussion and only among
the ones written by the same user the token belongs to. When there is no note
with the marker, the tool picks up its own older note that starts with
`**aireview review**`. Its key is unknown: on the next allowed run it will be
updated and get a marker. In `once` mode an old review also counts as existing —
updating it needs a Retry. Duplicates that have already piled up are not
removed automatically.

The key is a hash of the assembled prompts together with the providers, models
and temperatures of both stages. So the diff, the merge request description, the
Jira issue context, `review_instructions`, `ignore_paths` and the response
language all end up in it on their own: change any of those and the key differs,
so the review runs again.

The behaviour is set by `review_mode` (or `REVIEW_MODE`, or `--review-mode`):

- `update` (the default) — when the key matches the previous review, no requests
  are sent to the LLM at all; when the diff or the settings have changed, the
  review runs again and **overwrites** the previous comment.
- `once` — the review is done once, and later pushes to the MR do not repeat it.
  To update the review by hand, press **Retry** on the job in GitLab: if the key
  has changed, the LLM runs again and updates the previous comment. If nothing
  changed, no requests are sent to the LLM. The current state of the MR is
  checked, including when the job is restarted from an old pipeline. Note that
  `.aireview.yml` (models, `review_instructions`, `ignore_paths`) is taken from
  the checkout of the restarted pipeline. The `[skip review]` check in the
  example below uses the `CI_MERGE_REQUEST_TITLE` of that pipeline, not the
  fresh title from the API.

Detecting a Retry needs `CI_PROJECT_ID`, `CI_JOB_ID` and access for the
`GITLAB_TOKEN` to the
[Jobs API](https://docs.gitlab.com/api/jobs/#list-all-jobs-by-pipeline).
The tool checks whether an earlier attempt of the same job exists in the same
pipeline. An automatic retry from the GitLab `retry:` setting counts as a repeat
attempt too. Outside of GitLab CI, `once` mode keeps skipping an existing
review. The `--force` flag repeats the review even when nothing has changed.

While the review is running, the merge request can move on. Before publishing,
`aireview` re-reads it and compares `sha`, the target branch, `diff_refs`, the
title and the description: if any of those changed, the result is not published —
a comment must not end up holding a review of a diff that is no longer current.
The review text is printed to stdout before the publishing attempt, so it stays
in the job log. The previous comment is kept until the end of the next run.

## GitLab CI

For merge request pipelines `aireview` can run in a separate CI job, letting
GitLab substitute the current MR URL:

```yaml
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

stages:
  - review

aireview:
  stage: review
  image:
    name: registry.gitlab.example.com/your-group/aireview:latest
    entrypoint: [""]
  variables:
    MR_URL: "$CI_MERGE_REQUEST_PROJECT_URL/-/merge_requests/$CI_MERGE_REQUEST_IID"
    REVIEW_LANGUAGE: "ru"
    LLM_PROVIDER: "gemini"
    LLM_GENERATE_MODEL: "gemini-3.7-flash"
    LLM_CRITIQUE_MODEL: "gemini-3.8-flash"
    LLM_TIMEOUT: "60"
    LLM_HTTP_PROXY: "http://127.0.0.1:8888"
  script:
    - bundle _2.3.26_ exec bin/aireview review "$MR_URL" --verbose
  timeout: 45m
  retry:
    max: 1
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
```

`timeout: 45m` is the job ceiling, not a guarantee: the LLM part of the run
is itself bounded by `LLM_TIME_BUDGET` (30 minutes by default, pauses and
fallback models included), the rest is reading the MR and Jira and
publishing.

Set secrets such as `GITLAB_TOKEN`, `GEMINI_API_KEY` / `GEMINI_API_KEYS` and
the optional Jira credentials in the GitLab CI/CD variables. If the job should publish the result
back to the merge request, add `--post` to the review command.

For runners where the LLM provider is only reachable over WireGuard, bring up a
local HTTP proxy (`wireproxy`, for instance) before `aireview` starts and point
`LLM_HTTP_PROXY` at it. That avoids setting global `https_proxy`/`no_proxy`, so
GitLab and Jira stay on direct connections while RubyLLM goes through the
tunnel.

### Including the job template

Instead of copying the job into every project, it lives in this repository
as `templates/review.gitlab-ci.yml`. A project's `.gitlab-ci.yml` keeps only:

```yaml
include:
  - project: your-group/aireview
    ref: stable
    file: /templates/review.gitlab-ci.yml
```

The template is written for shell-executor runners (the image runs through
`docker run` with secrets passed by name) and carries `[skip review]`,
`resource_group`, `allow_failure` and `REVIEW_MODE=once`. Models come from
the image defaults, `.aireview.yml` is mounted into the container only when
the project has one. The job runs in the `.post` stage: it exists in every
pipeline, so a project does not declare it.

GitLab does not start a pipeline in which, after `rules` and `only` are
applied, only `.pre` and `.post` jobs remain. That happens when a project has
no other merge request jobs (a build that runs on tags only does not count).
In that case add a `review` stage to the project's existing `stages`, without
replacing them, and move the job there:

```yaml
stages:
  - review   # added to the project's stages
  - build

aireview:
  stage: review
```

To keep the review from waiting for other stages to finish, add `needs: []`
to the `aireview` job.

The template sets `REVIEW_MODE` as a job variable, and an environment variable
beats `.aireview.yml`: `review_mode` in the project file has no effect once
the template is included. Change the mode with a `REVIEW_MODE` CI/CD variable
of the project or with `aireview: {variables: {REVIEW_MODE: update}}`.

Every variable the config reads (`Config.env_names`: models, providers,
reserves, temperatures, limits, `OLLAMA_API_BASE` and so on) is passed into
the container by name, so a project can override anything through its CI/CD
variables — for instance, swap an unavailable model with `LLM_CRITIQUE_MODEL`
without waiting for an image release.

Secrets stay CI/CD variables **of the project**: group variables are readable
by any merge request of any project in the group.

The `stable` branch is managed: the copy of the template there pins
`AIREVIEW_IMAGE_TAG` to a verified release. Updating or rolling back every
project that includes the template is one edit of `stable`. A project can
pin another version by overriding `AIREVIEW_IMAGE_TAG` in its `variables`.

A release of the image is: tag → `aireview models check` on the image
defaults (an API error or an answer off the schema for any model stops the
pipeline, the image is not built, the previous version stays in the
registry) → build and push → set the new tag in `stable`. The same check on
a schedule (once a day) is the early signal that the provider retired a
model — otherwise the first to learn about it is a live MR.

## Docker

```bash
docker build -t aireview .
docker run --rm --env-file .env -v "$PWD/.aireview.yml:/app/.aireview.yml:ro" aireview \
  review https://gitlab.company.com/team/project/-/merge_requests/123
```

## Testing

```bash
bundle _2.3.26_ exec rspec
bundle _2.3.26_ exec rspec spec/config_spec.rb
bundle _2.3.26_ exec rspec spec/secret_scrubber_spec.rb
```

## Notes

- The reviewer does not check whether the specified versions of dependencies and images exist: the model's knowledge of releases is outdated, and that is what CI is for. Syntax errors and contradictions with the MR/Jira requirements are checked as usual.
- The CLI looks for `.aireview.yml` and `.env` walking up from the current working directory, so the project config can be kept in the repository root even when the tool is run from `aireview/`.
- How Ollama behaves when a request is still larger than its context window is up to the server, not to `aireview`: check the `ollama serve` log for truncation messages on your setup and size `max_prompt_chars` so it does not happen.

## Releasing

Releases are published to RubyGems.org by the `Release` workflow through
[trusted publishing](https://guides.rubygems.org/trusted-publishing/), so no
API key is stored anywhere. To cut a release:

1. Bump `Aireview::VERSION` in `lib/aireview/version.rb` and move the
   `Unreleased` section of `CHANGELOG.md` under the new version.
2. Commit, then tag the commit with the same version and push the tag:

   ```bash
   git tag v0.2.0
   git push github main v0.2.0
   ```

The workflow refuses to run when the tag does not match `Aireview::VERSION`,
runs the test suite, builds the gem, pushes it and then creates a GitHub
release for the tag with the matching `CHANGELOG.md` section as its notes and
the built `.gem` attached.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Contributors

See [CONTRIBUTORS.md](CONTRIBUTORS.md).

## License

[MIT](LICENSE)
