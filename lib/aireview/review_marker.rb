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
    # ignore_paths. Что кроме промпта влияет на результат — провайдер,
    # модель, температура стадий, общий пул с политикой критики — знает
    # Config#result_signature. Без пула ключ тот же, что раньше.
    def key(prompts:, config:)
      signature = config.result_signature
      source = {
        'generate' => [*signature['generate'], prompts[:generate_prompt]],
        'critique' => prompts[:critique_prompt] ? [*signature['critique'], prompts[:critique_prompt]] : nil
      }
      source['pool'] = signature['pool'] if signature['pool']

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
  end
end
