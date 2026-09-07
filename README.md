# aireview

`aireview` — это локальная CLI-утилита для ревью merge request'ов в GitLab с
помощью LLM. Использует двухпроходный пайплайн ревью: первый проход находит
кандидатов в замечания, второй критикует их и отбрасывает слабые или
невалидные.

Утилита поддерживает только self-hosted GitLab и self-hosted Jira. GitLab.com
и Jira Cloud не поддерживаются.

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
- API-ключ удалённого LLM-провайдера; для локальной Ollama ключ не нужен
- Опционально — логин и пароль Jira

## Configuration

Секреты живут в переменных окружения или в локальном `.env`-файле. В `.env`
Generate- и Critique-модели задаются явно:

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
```

На текущий момент поддерживаются только провайдеры `gemini` и `ollama`.
Провайдеры и модели каждой стадии задаются через `LLM_GENERATE_PROVIDER`,
`LLM_GENERATE_MODEL`, `LLM_CRITIQUE_PROVIDER` и `LLM_CRITIQUE_MODEL`.
`LLM_PROVIDER` остаётся общим значением по умолчанию, если отдельный провайдер
стадии не указан.

Если через прокси нужно гонять только LLM-трафик, задайте `LLM_HTTP_PROXY` или
`llm.http_proxy`. Это настраивает только RubyLLM; запросы к GitLab и Jira
продолжают идти напрямую.

### Локальная Ollama

Установите Ollama по [официальной инструкции](https://docs.ollama.com/quickstart),
затем загрузите локальную модель
[`qwen2.5-coder:7b`](https://ollama.com/library/qwen2.5-coder:7b):

```bash
ollama pull qwen2.5-coder:7b
```

Если сервис не запустился автоматически, запустите его отдельно и оставьте
работать во время ревью:

```bash
ollama serve
```

Для качественного результата используйте для Critique более мощную модель,
чем для Generate. Например, для генерации через локальную Ollama и критики
через Gemini настройте `.env`:

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

Проверенные модели Ollama:

- `qwen2.5-coder:7b`
- `qwen2.5-coder:14b`
- `qwen3:8b`
- `qwen3:14b`
- `gpt-oss:20b`

Размер контекстного окна настраивается на машине, где запущена Ollama. Для
постоянной настройки в Linux откройте конфигурацию сервиса:

```bash
sudo systemctl edit ollama.service
```

Добавьте настройку:

```ini
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=8192"
```

Затем примените её и перезапустите Ollama:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

При ручном запуске сервера контекст можно задать только для текущего процесса:

```bash
OLLAMA_CONTEXT_LENGTH=8192 ollama serve
```

Для локальной Ollama API-ключ не требуется. Провайдеры можно поменять местами,
изменив `LLM_GENERATE_PROVIDER`, `LLM_CRITIQUE_PROVIDER` и соответствующие
модели. Чтобы обе стадии работали локально, укажите `ollama` в обеих
переменных провайдера. Адрес с `/v1` соответствует
[конфигурации Ollama в RubyLLM](https://rubyllm.com/configuration/#provider-configuration).
`LLM_TIMEOUT` задаёт время ожидания каждого LLM-запроса в секундах; для
медленной локальной модели его можно увеличить.

Проектные правила живут в `.aireview.yml`. В YAML параметры `generate.model`
и `critique.model` для каждой стадии обязательны и не наследуются от базовых
настроек `llm`. Параметр `llm.provider` используется по умолчанию, если
`generate.provider` или `critique.provider` не задан:

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

Секреты вроде `GITLAB_TOKEN`, `GEMINI_API_KEY` и опциональные креды Jira
задавайте в CI/CD-переменных GitLab. Если нужно, чтобы джоб публиковал
результат обратно в merge request, добавьте `--post` к команде review.

Для раннеров, где LLM-провайдер доступен только через WireGuard, поднимайте
локальный HTTP-прокси (например, `wireproxy`) до старта `aireview` и
указывайте на него `LLM_HTTP_PROXY`. Это позволяет не задавать глобальные
`https_proxy`/`no_proxy`, так что GitLab и Jira остаются на прямых
соединениях, а RubyLLM ходит через туннель.

### Раннеры с shell executor

На раннерах с `shell`-executor'ом (как в `gitlab.railsc.ru`) секция `image:`
не работает — джоб выполняется прямо на хосте раннера. В этом случае образ
`aireview` собирается и публикуется в общий registry, а джоб проекта просто
запускает его через `docker run`:

```yaml
stages:
  - review

aireview:
  stage: review
  only:
    - merge_requests
  variables:
    AIREVIEW_IMAGE: "index.exp.railsc.ru/apress/aireview:latest"
    GITLAB_TOKEN: "$AIREVIEW_GITLAB_TOKEN"
  allow_failure: true
  interruptible: true
  script:
    - >
       if echo "$CI_MERGE_REQUEST_TITLE" | grep -q "\[skip review\]"; then
         echo "Skipping aireview due to [skip review] tag in merge request title"
         exit 0
       fi
    - docker pull "$AIREVIEW_IMAGE"
    - >
       docker run --rm
       --network host
       -e "GITLAB_URL=$CI_SERVER_URL"
       -e GITLAB_TOKEN
       -e GEMINI_API_KEY
       -e LLM_HTTP_PROXY
       -e LLM_TIMEOUT
       -e JIRA_URL
       -e JIRA_LOGIN
       -e JIRA_PASSWORD
       -v "$(pwd)/.aireview.yml:/app/.aireview.yml:ro"
       "$AIREVIEW_IMAGE"
       review "$CI_MERGE_REQUEST_PROJECT_URL/-/merge_requests/$CI_MERGE_REQUEST_IID"
       --post --verbose
```

Что здесь важно:

- `.aireview.yml` монтируется отдельным файлом в `/app`, а не подменяет весь
  рабочий каталог: в образе по этому пути лежит сам гем. Модели и правила
  проекта живут в этом файле, а в переменные CI/CD выносятся только секреты и
  адрес прокси.
- Секреты передаются в контейнер по имени (`-e GITLAB_TOKEN`), а не как
  `-e "GITLAB_TOKEN=$..."`. На shell-раннере значение из второй формы попадает
  в argv процесса `docker` и видно в `ps` любому соседнему джобу на том же
  хосте.
- `--network host` нужен, чтобы контейнер видел `wireproxy`, поднятый на
  `127.0.0.1` хоста раннера.
- `allow_failure: true` оставляет ревью необязательным: недоступный LLM не
  должен блокировать merge request.
- `--post` публикует ревью комментарием в MR; без него результат остаётся
  только в логе джоба.
- Токен в `GITLAB_TOKEN` должен иметь scope `api`: он и читает дифф, и пишет
  комментарий.

Про доступ к секретам: пайплайн merge request'а выполняет `.gitlab-ci.yml` из
ветки MR, поэтому автор ветки может подменить джоб и вытащить любую переменную,
доступную пайплайну. Маскирование от этого не спасает. Отсюда правила:

- заводите переменные на уровне проекта, а не группы: иначе ключ, доступный
  ревьюеру в одном проекте, утекает через любой другой проект группы;
- в `GITLAB_TOKEN` кладите отдельный project access token с ролью Reporter и
  scope `api`, выданный только на этот проект, а не личный или групповой токен;
- для `GEMINI_API_KEY` заводите отдельный ключ с собственной квотой, чтобы его
  компрометация не задевала остальные интеграции;
- protected-переменные надёжнее, но пайплайнам из обычных feature-веток они
  недоступны, так что для ревью на каждый MR они не подходят.

### Выпуск образа

1) Внести правки и смержить их в `master`
2) Создать и отправить тег с версией образа, например:

```
git switch master
git pull
git tag 0.1.1
git push upstream 0.1.1
```

Пайплайн автоматически соберёт и отправит в registry
`index.exp.railsc.ru/apress/aireview:<тег>` и обновит для него тег `latest`.
Тег `latest` обновляется каждым релизом, поэтому в подключённых проектах
надёжнее указывать конкретную версию в переменной `AIREVIEW_IMAGE`.

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
