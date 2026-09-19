# frozen_string_literal: true
require_relative 'stages'
require_relative 'utils'

module Aireview
  # Слои настроек в порядке возрастания приоритета: встроенные значения,
  # дефолты образа (AIREVIEW_DEFAULTS), .aireview.yml проекта, env, CLI.
  # Имя слоя показывает --dry-run, чтобы было видно, откуда пришла модель.
  module ConfigLayers
    Layer = Struct.new(:name, :path, :data, keyword_init: true)

    BUILT_IN_LAYER = 'built-in'
    DATA_LAYER = 'config'
    IMAGE_LAYER = 'image defaults'
    FILE_LAYER = '.aireview.yml'
    ENV_LAYER = 'env'
    CLI_LAYER = 'cli'

    # Имя слоя, из которого пришло значение; nil — не задано нигде.
    def source_of(*keys)
      layer_of(*keys)&.name
    end

    # Настройка стадии с учётом слоёв: в каждом слое сверху вниз сначала
    # стадийное значение (llm.<stage>.<key>), потом общее (llm.<key>).
    # Стадийное значение из дефолтов образа не должно перекрывать общее
    # из проекта или env: LLM_PROVIDER=ollama обязан переключить обе стадии.
    def stage_setting(stage, key)
      layer = stage_setting_layer(stage, key)
      layer && (Utils.dig(layer.data, 'llm', stage.to_s, key) || Utils.dig(layer.data, 'llm', key))
    end

    def stage_setting_layer(stage, key)
      stage = stage.to_s
      @layers.reverse.find do |layer|
        !Utils.dig(layer.data, 'llm', stage, key).nil? || !Utils.dig(layer.data, 'llm', key).nil?
      end
    end

    def stage_provider_source(stage)
      stage_setting_layer(stage, 'provider')&.name
    end

    # В режиме пула модель стадии задаёт start или сам пул, запасные — пул.
    def stage_model_source(stage)
      stage = stage.to_s
      return source_of('llm', stage, 'model') unless routing.pool_stage?(stage)
      return source_of('llm', stage, 'start') if routing.start_used?(stage)

      source_of('llm', 'models')
    end

    def stage_fallbacks_source(stage)
      stage = stage.to_s
      routing.pool_stage?(stage) ? source_of('llm', 'models') : source_of('llm', stage, 'fallbacks')
    end

    # Старт стадии пришёл из слоя ниже того, где задан пул: дефолты образа
    # против LLM_MODELS проекта.
    def start_inherited?(stage)
      start_layer = layer_of('llm', stage.to_s, 'start')
      models_layer = layer_of('llm', 'models')
      !!(start_layer && models_layer && @layers.index(start_layer) < @layers.index(models_layer))
    end

    # Предупреждения конфигурации и плана — печатает CLI и --dry-run.
    def warnings
      STAGES.flat_map { |stage| stage_provider_warnings(stage) } + routing.warnings
    end

    # Пути слоёв-файлов для --dry-run.
    def layer_paths
      @layers.select(&:path).to_h { |layer| [layer.name, layer.path] }
    end

    # Запасная модель без provider наследует провайдера стадии. Если проект
    # переопределил провайдера выше слоя, где заданы фолбеки, унаследованные
    # запасные молча становятся «моделями» нового провайдера.
    def stage_provider_warnings(stage)
      stage = stage.to_s
      inherited = inherited_fallback_names(stage)
      return [] if inherited.empty?

      provider_layer = stage_setting_layer(stage, 'provider')
      fallbacks_layer = layer_of('llm', stage, 'fallbacks')
      return [] unless provider_layer && fallbacks_layer
      return [] if @layers.index(provider_layer) <= @layers.index(fallbacks_layer)

      provider = public_send("#{stage}_provider")
      ["#{stage}: provider #{provider.inspect} comes from #{provider_layer.name}, " \
       "but fallbacks without an explicit provider come from #{fallbacks_layer.name} " \
       "and now inherit it: #{inherited.join(', ')}"]
    end

    private

    def layer_of(*keys)
      @layers.reverse.find { |layer| !Utils.dig(layer.data, *keys).nil? }
    end

    def inherited_fallback_names(stage)
      Array(dig('llm', stage, 'fallbacks')).filter_map do |item|
        next item.to_s if item.is_a?(String)
        next unless item.is_a?(Hash) && Aireview::Utils.blank?(item['provider'])

        item['model'].to_s
      end
    end
  end
end
