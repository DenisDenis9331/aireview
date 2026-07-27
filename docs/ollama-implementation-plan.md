# План подключения локальной Ollama

1. Для локальной Ollama нужен рабочий адрес по умолчанию. Из руководства Ollama следует использовать `http://localhost:11434/v1`, сохранив возможность подключаться по другому адресу через `LLM_API_BASE`. Для этого в [`lib/aireview/config.rb`, строки 239–240](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/config.rb#L239-L240) нужно добавить метод `ollama_api_base`, который возвращает пользовательский или стандартный адрес.

2. Так как RubyLLM уже имеет отдельный провайдер Ollama, использование настроек OpenAI создаёт ненужную зависимость от фиктивного API-ключа и обходит встроенную поддержку. Поэтому в [`lib/aireview/reviewer.rb`, строки 180–204](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/reviewer.rb#L180-L204) нужно заменить `openai_api_key` и `openai_api_base` на `ollama_api_base`.

3. Лучше явно указать провайдера, чтобы запрос гарантированно уходил в Ollama, а RubyLLM не пытался определить провайдера только по названию модели. Для этого в [`lib/aireview/reviewer.rb`, строки 41–54](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/reviewer.rb#L41-L54) при создании чата нужно передавать `provider: :ollama`.

4. Локальная Ollama не требует API-ключа, поэтому для неё необходимо отдельное исключение при проверке конфигурации. Такое исключение уже находится в [`lib/aireview/config.rb`, строки 287–300](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/lib/aireview/config.rb#L287-L300), и его нужно сохранить при изменении способа подключения.

5. В [`.env.example`, строки 1–14](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/.env.example#L1-L14) нужно добавить конфигурацию Ollama. Таймаут можно менять в зависимости от скорости по факту:

```env
LLM_PROVIDER=ollama
LLM_API_BASE=http://localhost:11434/v1
LLM_GENERATE_MODEL=qwen2.5-coder:7b
LLM_CRITIQUE_MODEL=qwen2.5-coder:7b
LLM_TIMEOUT=300
```

6. Чтобы тест проверял новое поведение, его нужно изменить под встроенный провайдер Ollama и работу без API-ключа. В [`spec/reviewer_spec.rb`, строки 219–233](https://github.com/DenisDenis9331/aireview/blob/0e21dd0d1d0b2508a8b39b344f85e932b5606a4d/spec/reviewer_spec.rb#L219-L233) необходимо проверить `ollama_api_base`, отсутствие обязательного ключа и вызов `RubyLLM.chat` с `provider: :ollama`.
