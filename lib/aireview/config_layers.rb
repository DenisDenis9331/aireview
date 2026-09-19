# frozen_string_literal: true
require_relative 'stages'
require_relative 'utils'

module Aireview
  # Configuration layers in ascending priority: built-in values, image
  # defaults (AIREVIEW_DEFAULTS), the project's .aireview.yml, env, CLI. The
  # layer name is shown by --dry-run, so that it is clear where a model came from.
  module ConfigLayers
    Layer = Struct.new(:name, :path, :data, keyword_init: true)

    BUILT_IN_LAYER = 'built-in'
    DATA_LAYER = 'config'
    IMAGE_LAYER = 'image defaults'
    FILE_LAYER = '.aireview.yml'
    ENV_LAYER = 'env'
    CLI_LAYER = 'cli'

    # The name of the layer a value came from; nil — not set anywhere.
    def source_of(*keys)
      layer_of(*keys)&.name
    end

    # A stage setting resolved layer by layer: in every layer, top down, the
    # stage value (llm.<stage>.<key>) first, then the shared one (llm.<key>).
    # A stage value from the image defaults must not beat a shared value from
    # the project or the environment: LLM_PROVIDER=ollama must switch both stages.
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

    # In pool mode the stage model is set by the start or the pool itself, the reserves by the pool.
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

    # The stage start came from a layer below the one that set the pool: the
    # image defaults versus the project's LLM_MODELS.
    def start_inherited?(stage)
      start_layer = layer_of('llm', stage.to_s, 'start')
      models_layer = layer_of('llm', 'models')
      !!(start_layer && models_layer && @layers.index(start_layer) < @layers.index(models_layer))
    end

    # Configuration and plan warnings; the CLI and --dry-run print them.
    def warnings
      STAGES.flat_map { |stage| stage_provider_warnings(stage) } + routing.warnings
    end

    # The paths of the file layers, for --dry-run.
    def layer_paths
      @layers.select(&:path).to_h { |layer| [layer.name, layer.path] }
    end

    # A reserve without a provider inherits the stage provider. When a
    # project overrode the provider above the layer that set the reserves,
    # the inherited reserves silently become "models" of the new provider.
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
