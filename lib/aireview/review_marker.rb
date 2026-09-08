# frozen_string_literal: true
require 'digest'
require 'json'

module Aireview
  # Скрытая метка в теле заметки: по ней ревью находит собственный комментарий
  # и понимает, менялось ли с прошлого раза то, что влияет на результат.
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

    # Ключ считается от готовых промптов, а не от одного SHA: так в него сами
    # собой попадают дифф, описание MR, контекст Jira, инструкции ревью и
    # ignore_paths. Модели и провайдеры добавляются рядом — на промпт они не
    # влияют, но на результат влияют.
    def key(prompts:, config:)
      source = {
        'generate' => [
          config.generate_provider,
          prompts[:generate_model],
          prompts[:generate_temperature],
          prompts[:generate_prompt]
        ],
        'critique' => critique_source(prompts, config)
      }

      Digest::SHA256.hexdigest(JSON.generate(source))[0, 16]
    end

    # То, что делает результат ревью устаревшим: новый коммит, смена целевой
    # ветки, перебазирование со сдвигом базы сравнения, а также правка
    # заголовка или описания — из них берутся требования, с которыми ревью
    # сверяет код.
    def state(merge_request)
      {
        'sha' => merge_request['sha'],
        'target_branch' => merge_request['target_branch'],
        'diff_refs' => merge_request['diff_refs'],
        'title' => merge_request['title'],
        'description' => merge_request['description']
      }
    end

    def critique_source(prompts, config)
      return nil unless prompts[:critique_prompt]

      [
        config.critique_provider,
        prompts[:critique_model],
        prompts[:critique_temperature],
        prompts[:critique_prompt]
      ]
    end
  end
end
