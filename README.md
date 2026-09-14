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

Secrets live in environment variables or in a local `.env` file. In `.env` the
Generate and Critique models are set explicitly:

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
run right away: without a fallback model such a request gets up to five
attempts, the original one and four retries with pauses of about 2, 5, 5 and
5 minutes; with a fallback model, one short retry and a switch (see
"Fallback models and keys"). Only the failed stage is repeated, not the
whole run.

Project rules live in `.aireview.yml`. In YAML the `generate.model` and
`critique.model` settings are required for each stage and are not inherited
from the base `llm` settings. `llm.provider` is used as the default when
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

What happens on which error:

| Error | Reaction |
|---|---|
| Daily quota (`quotaId` like `…PerDay…` in Google's answer) | No retries: the next key on the same model. The "key + model" pair is remembered until the end of the run so that Critique and the JSON repair do not hit it again. Out of keys: the next model with the first key. |
| Per-minute limit (429 with a "retry in N s" hint) | Retry after the hinted delay; one retry while there is somewhere to switch to, up to three on the last route. Then the next key, then the next model. |
| Overloaded (503) or timeout | One short retry (~30 s) and the next model with the same key. The last model in the chain gets the full 2/5/5/5 minute schedule. |
| Other API errors (schema, context length, auth) | The run fails right away: a fallback model would answer the same. |

All of this is bounded by a time budget for the LLM part of the run:
`llm.time_budget` / `LLM_TIME_BUDGET`, 1800 seconds by default. A pause that
does not fit into the remainder is skipped and the request timeout is capped
by the remainder; when the time is up, the run fails with an error listing
everything that was tried. Because of this keep `LLM_TIMEOUT` around 120–300
seconds: one hung request must not eat the whole budget.

The review key (see "A single comment per merge request") is computed from
the configured primary model, not from the one that answered: a review made
by a fallback model is not rewritten on the next push without changes in the
MR, and adding a fallback model to the config does not re-run the review on
every open MR. When a stage went to a fallback model, the report ends with a
`Fallback model used: critique — …` line. A key switch stays in the log only,
and key values never reach the log. `--dry-run` prints the model chains and
the number of keys per provider, `--no-fallbacks` leaves one model and one
key per stage.

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
