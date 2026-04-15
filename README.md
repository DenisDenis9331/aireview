# aireview

`aireview` — это локальная CLI-утилита для ревью merge request'ов в GitLab с
помощью LLM. Использует двухпроходный пайплайн ревью: первый проход находит
кандидатов в замечания, второй критикует их и отбрасывает слабые или
невалидные.

MVP-flow:

1. Принимает URL merge request'а GitLab.
2. Загружает метаданные и изменения MR из GitLab.
3. Фильтрует игнорируемые пути и вырезает секреты из диффов.
4. Опционально обогащает промпт контекстом из задачи Jira.
5. Запускает Generate-проход через RubyLLM, чтобы получить саммари MR и
   кандидатов в замечания.
6. Опционально запускает Critique-проход, который возвращает вердикт по
   каждому id кандидата.
7. Рендерит финальное markdown-ревью в stdout или постит обратно в merge
   request.

## Requirements

- Ruby 3.1.3
- Bundler 2.3.26
- Personal access token для GitLab
- API-ключ провайдера
- Опционально — API-токен Jira

## Configuration

Секреты живут в переменных окружения или в локальном `.env`-файле. В `.env`
Generate- и Critique-модели задаются явно:

```bash
GITLAB_URL=https://gitlab.company.com
GITLAB_TOKEN=glpat-xxx
JIRA_URL=https://company.atlassian.net
JIRA_EMAIL=user@company.com
JIRA_TOKEN=xxx
GEMINI_API_KEY=xxx
LLM_PROVIDER=gemini
LLM_TEMPERATURE=0
LLM_TIMEOUT=60
LLM_HTTP_PROXY=http://127.0.0.1:8888
LLM_GENERATE_MODEL=gemini-2.5-pro
LLM_GENERATE_TEMPERATURE=0.3
LLM_CRITIQUE_MODEL=gemini-2.5-flash
LLM_CRITIQUE_TEMPERATURE=0
REVIEW_LANGUAGE=ru
```

Для других провайдеров используйте соответствующий ключ, например
`OPENAI_API_KEY`, `OPENROUTER_API_KEY` или `ANTHROPIC_API_KEY`, и задайте оба
параметра — `LLM_GENERATE_MODEL` и `LLM_CRITIQUE_MODEL`. Эти две настройки
моделей обязательны и могут указывать на одну и ту же модель.

Если через прокси нужно гонять только LLM-трафик, задайте `LLM_HTTP_PROXY` или
`llm.http_proxy`. Это настраивает только RubyLLM; запросы к GitLab и Jira
продолжают идти напрямую.

Проектные правила живут в `.aireview.yml`. В YAML параметры `generate.model`
и `critique.model` для каждой стадии обязательны и не наследуются от базовых
настроек `llm`:

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
  Это Rails-проект. Обращай внимание на:
  - N+1 запросы
  - strong params
  - отсутствие тестов для новой логики
  Игнорируй стилистику — для этого есть линтеры.

llm:
  provider: gemini
  temperature: 0
  timeout: 60
  http_proxy: http://127.0.0.1:8888
  generate:
    model: gemini-2.5-pro
    temperature: 0.3
  critique:
    model: gemini-2.5-flash
    temperature: 0
```

## Usage

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --post
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --no-jira
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --dry-run --verbose
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --generate-model gemini-2.5-pro --critique-model gemini-2.5-flash
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --generate-model gemini-2.5-pro --generate-temperature 0.3 --critique-model gemini-2.5-flash --critique-temperature 0
bundle _2.3.26_ exec bin/aireview review https://gitlab.company.com/team/project/-/merge_requests/123 --no-critique
```

- `--generate-model MODEL` переопределяет модель только для Generate-прохода.
- `--critique-model MODEL` переопределяет модель только для Critique-прохода.
- `--generate-temperature VALUE` переопределяет температуру только для Generate-прохода.
- `--critique-temperature VALUE` переопределяет температуру только для Critique-прохода.
- `--config PATH` указывает на конкретный `.aireview.yml`.
- `--no-jira` выключает обогащение из Jira, даже если ключ задачи есть в MR.
- `--dry-run` печатает настройки LLM и промпт Generate, а также промпт Critique, если не задан `--no-critique`.
- `--no-critique` пропускает второй проход и рендерит кандидатов Generate напрямую.

## GitLab CI

Для пайплайнов merge request'ов можно запускать `aireview` в отдельном CI-джобе
и давать GitLab подставлять текущий URL MR:

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
    LLM_GENERATE_MODEL: "gemini-2.5-pro"
    LLM_CRITIQUE_MODEL: "gemini-2.5-flash"
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

Секреты вроде `GITLAB_TOKEN`, `GEMINI_API_KEY` и опциональные креды Jira
задавайте в CI/CD-переменных GitLab. Если нужно, чтобы джоб публиковал
результат обратно в merge request, добавьте `--post` к команде review.

Для раннеров, где LLM-провайдер доступен только через WireGuard, поднимайте
локальный HTTP-прокси (например, `wireproxy`) до старта `aireview` и
указывайте на него `LLM_HTTP_PROXY`. Это позволяет не задавать глобальные
`https_proxy`/`no_proxy`, так что GitLab и Jira остаются на прямых
соединениях, а RubyLLM ходит через туннель.

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

## Проверки на реальных MR

Что удалось подтвердить вручную на боевых merge request'ах.

### Несоответствия кода и постановки в Jira

Нашёл ключи, которых нет в задаче [GOODS-5061](https://jira.railsc.ru/browse/GOODS-5061). Вывод: https://gitlab.railsc.ru/-/snippets/52

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.railsc.ru/abak-press/spider/-/merge_requests/1074 --verbose
```

Поймал добавленный тестовый метод. Вывод: https://gitlab.railsc.ru/-/snippets/53

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.railsc.ru/DenisDenis9331/spider/-/merge_requests/76 --verbose
```

### Поиск ошибок в коде

Нашёл баг, который позже починили в [другом MR](https://gitlab.railsc.ru/abak-press/spider/-/merge_requests/1076/diffs#c77d49536a6d43fa2953c59b5e8757f084dbbe9e_33_32). Вывод: https://gitlab.railsc.ru/-/snippets/54

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.railsc.ru/abak-press/spider/-/merge_requests/1071 --verbose
```

### Вырезание секретов перед отправкой в LLM

Контекст, который реально уходит в нейронку: https://gitlab.railsc.ru/-/snippets/55

```bash
bundle _2.3.26_ exec bin/aireview review https://gitlab.railsc.ru/abak-press/spider/-/merge_requests/1078 --verbose --dry-run
```

Пример вырезанного секрета из вывода:

```diff
diff --git a/spec/fixtures/cassettes/openai_images_2_images_size_1024.yml b/spec/fixtures/cassettes/openai_images_2_images_size_1024.yml
--- a/spec/fixtures/cassettes/openai_images_2_images_size_1024.yml
+++ b/spec/fixtures/cassettes/openai_images_2_images_size_1024.yml
[REDACTED: secret file spec/fixtures/cassettes/openai_images_2_images_size_1024.yml]
```

## Notes

- CLI ищет `.aireview.yml` и `.env`, поднимаясь вверх от текущей рабочей директории, так что проектный конфиг можно держать в корне репозитория, даже когда инструмент запускается из `aireview/`.
