# Проектирование подключения локальной Ollama

## Цель

Добавить возможность использовать локально запущенную Ollama вместо облачного
LLM-провайдера. API-ключ для локального режима не требуется, а существующая
работа с Gemini, OpenAI, OpenRouter и Anthropic не должна измениться.

## Текущее состояние

В проекте уже есть часть необходимой конфигурации:

- [`LLM_API_BASE` читается из окружения](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/config.rb#L37-L45).
- [`ollama` зарегистрирована как провайдер без отдельного API-ключа](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/config.rb#L48-L54).
- [Проверка конфигурации разрешает Ollama без API-ключа](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/config.rb#L287-L300).
- [Ollama сейчас настраивается через OpenAI-совместимые поля RubyLLM](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/reviewer.rb#L180-L204).
- [При создании чата провайдер явно не передаётся](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/reviewer.rb#L41-L54).

## Предлагаемая реализация

### Конфигурация

Сохранить существующие переменные:

```env
LLM_PROVIDER=ollama
LLM_API_BASE=http://localhost:11434/v1
LLM_GENERATE_MODEL=qwen2.5-coder:7b
LLM_CRITIQUE_MODEL=qwen2.5-coder:7b
LLM_TIMEOUT=300
```

Если `LLM_API_BASE` не задан, использовать
`http://localhost:11434/v1`. Модели Generate и Critique остаются
обязательными, API-ключ для локальной Ollama не проверяется.

### Настройка RubyLLM

В ветке `provider == 'ollama'` использовать нативное поле RubyLLM:

```ruby
config.ollama_api_base =
  @config.llm_api_base || 'http://localhost:11434/v1'
```

Текущие `openai_api_key`, `openai_api_base` и
`openai_use_system_role` для Ollama после этого не нужны.

При создании чата явно передавать провайдер:

```ruby
RubyLLM.chat(
  model: model,
  provider: :ollama
)
```

RubyLLM уже поддерживает Ollama и локальные модели, поэтому отдельный HTTP-клиент
для Ollama писать не требуется.

### Ошибки

Расширить [существующую обработку ошибок LLM](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/reviewer.rb#L49-L98)
понятными подсказками:

- при отказе соединения предложить проверить `ollama serve`;
- при отсутствии модели предложить проверить `ollama list`;
- при timeout предложить увеличить `LLM_TIMEOUT`;
- при неправильном адресе предложить проверить `LLM_API_BASE`.

### Документация

Добавить пример конфигурации в:

- [`.env.example`](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/.env.example#L1-L14);
- [`README.md`, раздел Configuration](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/README.md#L29-L59).

Минимальная инструкция:

```bash
ollama serve
ollama pull qwen2.5-coder:7b
```

Если `aireview` запускается в Docker Desktop, отдельно описать адрес
`http://host.docker.internal:11434/v1`, поскольку `localhost` внутри контейнера
указывает на сам контейнер.

## Тестирование

Обновить [существующий тест Ollama](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/spec/reviewer_spec.rb#L219-L233)
и проверить:

- настройку `ollama_api_base`;
- работу без API-ключа;
- вызов `RubyLLM.chat` с `provider: :ollama`;
- передачу локального имени модели без изменений;
- пользовательский и стандартный адреса Ollama;
- отсутствие изменений в поведении остальных провайдеров.

Настоящую Ollama в CI поднимать не требуется. Достаточно unit-тестов с
подменённым RubyLLM и отдельной ручной проверки локального подключения.

## Критерии готовности

- `LLM_PROVIDER=ollama` включает локальный провайдер.
- API-ключ не требуется.
- Generate и Critique работают с указанными локальными моделями.
- Адрес Ollama можно изменить через `LLM_API_BASE`.
- Ошибки подключения объясняют, что проверить пользователю.
- Облачные провайдеры продолжают работать как раньше.
- README и `.env.example` содержат инструкцию.
- Unit-тесты и линтер проходят.

## Вопросы для обсуждения

1. Оставить общую переменную `LLM_API_BASE` или добавить `OLLAMA_API_BASE`?
2. Включать ли Docker-сценарий в первую реализацию?
3. Рекомендовать ли конкретную модель или оставить выбор пользователю?

## Ссылки

- [Ollama: OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
- [Ollama CLI](https://docs.ollama.com/cli)
- [RubyLLM: Provider Setup and Custom Endpoints](https://rubyllm.com/next/configuration-providers/)
