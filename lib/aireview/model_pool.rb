# frozen_string_literal: true
require_relative 'errors'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'stage_chains'

module Aireview
  # План маршрутизации из общего пула: модели в порядке приоритета (первая —
  # предпочтительная для критики). Generate обходит пул от стартовой модели
  # вниз и по кругу; критика берёт первую живую модель не ниже той, что
  # ответила в generate (rank: not_below_generate), самокритика той же
  # моделью — последний допустимый вариант, ниже — только при allow_weaker.
  # Стадия со своей model пулом не пользуется: у неё независимая цепочка, и
  # правило ранга тогда не действует, как при rank: any.
  class ModelPool
    CRITIQUE_RANKS = %w[not_below_generate any].freeze
    DEFAULT_CRITIQUE_RANK = 'not_below_generate'

    attr_reader :warnings

    # Есть ли модель в сыром списке llm.models — без построения плана: так
    # CLI-переопределение не спотыкается о невалидный старт старого плана.
    def self.member?(items, provider, model)
      return false if Aireview::Utils.blank?(model)

      Array(items).each_with_index.any? do |item, index|
        parsed = parse_item(item, index, provider)
        parsed[:model] == model.to_s || "#{parsed[:provider]}/#{parsed[:model]}" == model.to_s
      end
    end

    def self.parse_item(item, index, provider)
      item = ModelCandidate.parse_item(item)
      name = "llm.models[#{index}]"
      raise ConfigError, "#{name} must be a model name or a hash with model" unless item.is_a?(Hash)
      raise ConfigError, "#{name}.model is required" if Aireview::Utils.blank?(item['model'])

      limit = item['max_prompt_chars']
      {
        provider: (item['provider'] || provider).to_s,
        model: item['model'].to_s,
        max_prompt_chars: limit.nil? ? nil : StageChains.positive_limit(limit, name)
      }
    end

    # items — сырой llm.models; starts — старт по стадиям (имя модели или
    # nil); inherited_starts — стадии, чей старт пришёл из слоя ниже пула
    # (дефолты образа против LLM_MODELS проекта): такой старт, которого нет
    # в пуле, заменяется первой моделью с предупреждением, явный старт не из
    # пула — ошибка конфигурации; own_chains — стадии со своей цепочкой.
    # Девять именованных настроек читаются лучше, чем структура ради структуры.
    def initialize(items:, provider:, limits:, starts: {}, inherited_starts: [], rank: nil, allow_weaker: false, # rubocop:disable Metrics/ParameterLists
                   own_chains: nil, only_primary: false)
      @items = parse_items(items, provider)
      @limits = limits.transform_keys(&:to_s)
      @rank = validate_rank(rank)
      @allow_weaker = allow_weaker == true
      @own_chains = own_chains || StageChains.new({})
      @only_primary = only_primary
      @warnings = []
      @starts = resolve_starts(starts.transform_keys(&:to_s), inherited_starts.map(&:to_s))
    end

    def pool(stage = 'generate')
      limit = @limits.fetch(stage.to_s)
      @items.map do |item|
        ModelCandidate.new(provider: item[:provider], model: item[:model],
                           max_prompt_chars: item[:max_prompt_chars] || limit)
      end
    end

    def chain(stage)
      stage = stage.to_s
      return @own_chains.chain(stage) unless pool_stage?(stage)

      trim(pool(stage).rotate(index_of(@starts[stage] || @items.first[:model])))
    end

    # Модели не ниже ответившей generate по порядку пула (включая её саму),
    # при allow_weaker — потом остальные. Явный старт критики идёт первым,
    # только если сам допустим: generate идёт по кругу и может ответить
    # моделью выше своего старта, статически это не проверить; недопустимый
    # старт не обходит запрет слабой критики, а пропускается.
    def critique_chain(after:)
      return chain('critique') unless rank_applies?(after)

      models = pool('critique')
      limit = index_of(after)
      allowed = models.first(limit + 1)
      allowed += models.drop(limit + 1) if @allow_weaker
      trim(with_start_first(allowed, @starts['critique']))
    end

    def primary(stage)
      chain(stage).first
    end

    def weaker?(critique_candidate, generate_candidate)
      return false unless pool_member?(critique_candidate) && pool_member?(generate_candidate)

      index_of(critique_candidate) > index_of(generate_candidate)
    end

    # Порядок и политика пула — в ключ ревью: от них зависит, какая модель
    # проверяет замечания. nil, когда хотя бы одна стадия вне пула.
    def signature
      return nil unless both_stages_in_pool?

      {
        'models' => pool.map(&:to_s),
        'generate_start' => @starts['generate'],
        'critique_start' => @starts['critique'],
        'rank' => @rank,
        'allow_weaker' => @allow_weaker
      }
    end

    # Правило выбора критики словами — для --dry-run.
    def rule
      return nil unless both_stages_in_pool?
      return @rank if @rank == 'any' || !@allow_weaker

      "#{@rank}, weaker allowed"
    end

    def pool?
      true
    end

    def pool_stage?(stage)
      !@own_chains.stage?(stage)
    end

    def pool_member?(model)
      return false if model.nil?

      @items.any? { |item| match?(item, model) }
    end

    def start_used?(stage)
      !@starts[stage.to_s].nil?
    end

    private

    def both_stages_in_pool?
      STAGES.all? { |stage| pool_stage?(stage) }
    end

    def rank_applies?(after)
      both_stages_in_pool? && @rank != 'any' && pool_member?(after)
    end

    def trim(chain)
      @only_primary ? chain.first(1) : chain
    end

    def with_start_first(chain, start)
      return chain unless start

      head = chain.find { |candidate| match_candidate?(candidate, start) }
      unless head
        @warnings << "llm.critique.start #{start} is below the model that answered in generate and allow_weaker " \
                     'is off, ignoring it'
        return chain
      end

      [head, *chain.reject { |candidate| candidate.equal?(head) }]
    end

    # Старт стадии со своей цепочкой не проверяется: стадия вне пула.
    def resolve_starts(starts, inherited)
      STAGES.to_h do |stage|
        start = starts[stage]
        next [stage, nil] if Aireview::Utils.blank?(start) || !pool_stage?(stage)
        next [stage, start] if pool_member?(start)
        raise ConfigError, "#{start} is not in llm.models: #{pool.join(', ')}" unless inherited.include?(stage)

        @warnings << "llm.#{stage}.start #{start} is not in the overriding llm.models, starting from #{pool.first}"
        [stage, nil]
      end
    end

    def index_of(model)
      index = @items.index { |item| match?(item, model) }
      return index if index

      raise ConfigError, "#{model} is not in llm.models: #{pool.join(', ')}"
    end

    # Модель задаётся именем или «провайдер/имя»; кандидат — по провайдеру и имени.
    def match?(item, model)
      return "#{item[:provider]}/#{item[:model]}" == model.to_s if model.is_a?(ModelCandidate)

      item[:model] == model.to_s || "#{item[:provider]}/#{item[:model]}" == model.to_s
    end

    def match_candidate?(candidate, model)
      candidate.model == model.to_s || candidate.to_s == model.to_s
    end

    def validate_rank(rank)
      rank = (rank || DEFAULT_CRITIQUE_RANK).to_s
      return rank if CRITIQUE_RANKS.include?(rank)

      raise ConfigError, "llm.critique.rank must be one of #{CRITIQUE_RANKS.join(', ')}, got #{rank.inspect}"
    end

    def parse_items(items, provider)
      parsed = Array(items).each_with_index.map { |item, index| self.class.parse_item(item, index, provider) }
      raise ConfigError, 'llm.models must not be empty' if parsed.empty?

      names = parsed.map { |item| "#{item[:provider]}/#{item[:model]}" }
      duplicates = names.tally.select { |_, count| count > 1 }.keys
      raise ConfigError, "llm.models has duplicates: #{duplicates.join(', ')}" unless duplicates.empty?

      parsed
    end
  end
end
