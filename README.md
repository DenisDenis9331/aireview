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
LLM_PROVIDER=gemini
LLM_TEMPERATURE=0
LLM_TIMEOUT=60
LLM_HTTP_PROXY=http://127.0.0.1:8888
LLM_GENERATE_PROVIDER=gemini
LLM_GENERATE_MODEL=gemini-3.7-flash
LLM_GENERATE_TEMPERATURE=0.3
LLM_CRITIQUE_PROVIDER=gemini
LLM_CRITIQUE_MODEL=gemini-3.8-flash
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
local model it can be raised.

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

llm:
  provider: gemini
  temperature: 0
  timeout: 60
  http_proxy: http://127.0.0.1:8888
  generate:
    provider: gemini
    model: gemini-3.7-flash
    temperature: 0.3
  critique:
    provider: ollama
    model: qwen2.5-coder:7b
    temperature: 0
```

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
- `--dry-run` prints the LLM settings and the Generate prompt, plus the Critique prompt unless `--no-critique` is given.
- `--no-critique` skips the second pass and renders the Generate candidates directly.
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
  retry:
    max: 1
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
```

Set secrets such as `GITLAB_TOKEN`, `GEMINI_API_KEY` and the optional Jira
credentials in the GitLab CI/CD variables. If the job should publish the result
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

- The CLI looks for `.aireview.yml` and `.env` walking up from the current working directory, so the project config can be kept in the repository root even when the tool is run from `aireview/`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
