# frozen_string_literal: true
require_relative 'errors'
require_relative 'stages'
require_relative 'utils'
require_relative 'model_candidate'
require_relative 'stage_chains'

module Aireview
  # A routing plan from a shared pool: models in order of priority (the
  # first is the preferred one for Critique). Generate walks the pool from
  # its start model downwards and round again; Critique takes the first
  # live model not below the one that answered in Generate
  # (rank: not_below_generate), self-critique by the same model is the last
  # permitted option, lower only with allow_weaker. A stage with a model of
  # its own does not use the pool: its chain is independent and the rank
  # rule does not apply, as with rank: any.
  class ModelPool
    CRITIQUE_RANKS = %w[not_below_generate any].freeze
    DEFAULT_CRITIQUE_RANK = 'not_below_generate'

    attr_reader :warnings

    # Whether a model is in the raw llm.models list — without building the
    # plan, so that a CLI override does not trip over an invalid start of
    # the old plan.
    def self.member?(items, provider, model)
      return false if Aireview::Utils.blank?(model)

      Array(items).each_with_index.any? do |item, index|
        names(parse_item(item, index, provider)).include?(model.to_s)
      end
    end

    def self.item_candidate(item)
      ModelCandidate.new(provider: item[:provider], model: item[:model], api_base: item[:api_base])
    end

    # The full name of a pool item, with the address of a server of your own.
    def self.item_name(item)
      item_candidate(item).to_s
    end

    # How a model may be named in a start or a CLI override (ModelCandidate#names).
    def self.names(item)
      item_candidate(item).names
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
        max_prompt_chars: limit.nil? ? nil : StageChains.positive_limit(limit, name),
        api_base: ModelCandidate.api_base(item['api_base'], "#{name}.api_base")
      }
    end

    # items — the raw llm.models; starts — the start per stage (a model name
    # or nil); inherited_starts — stages whose start came from a layer below
    # the pool (image defaults versus the project's LLM_MODELS): such a start
    # missing from the pool is replaced by the first model with a warning,
    # an explicit start outside the pool is a configuration error;
    # own_chains — stages with a chain of their own; stages — the stages
    # that go to an LLM in this run: without Critique (Jev decides with no
    # fallback, --no-critique) the plan has no critique chain and no critique
    # policy to validate or to sign.
    # Ten named settings read better than a struct for its own sake.
    def initialize(items:, provider:, limits:, starts: {}, inherited_starts: [], rank: nil, allow_weaker: false, # rubocop:disable Metrics/ParameterLists
                   own_chains: nil, only_primary: false, stages: STAGES)
      @stages = stages.map(&:to_s)
      @items = parse_items(items, provider)
      @limits = limits.transform_keys(&:to_s)
      @rank, @allow_weaker = critique_policy(rank, allow_weaker)
      @own_chains = own_chains || StageChains.new({})
      @only_primary = only_primary
      @warnings = []
      @starts = resolve_starts(starts.transform_keys(&:to_s), inherited_starts.map(&:to_s))
    end

    def stage?(stage)
      @stages.include?(stage.to_s)
    end

    def pool(stage = 'generate')
      limit = @limits.fetch(stage.to_s)
      @items.map do |item|
        ModelCandidate.new(provider: item[:provider], model: item[:model],
                           max_prompt_chars: item[:max_prompt_chars] || limit, api_base: item[:api_base])
      end
    end

    def chain(stage)
      stage = stage.to_s
      raise ArgumentError, "unknown LLM stage #{stage.inspect}" unless stage?(stage)
      return @own_chains.chain(stage) unless pool_stage?(stage)

      trim(pool(stage).rotate(index_of(@starts[stage] || @items.first[:model])))
    end

    # The models not below the one that answered in Generate, in pool order
    # (including that one), then — only with allow_weaker — the rest. An
    # explicit critique start goes first only when it is permitted itself:
    # Generate walks round the pool and may answer with a model above its
    # own start, so this cannot be checked statically; a start that is not
    # permitted does not bypass the ban on a weaker critique, it is skipped.
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

    # The order and policy of the pool go into the review key: they decide
    # which model checks the findings. nil when a stage is outside the pool.
    # Without Critique only the generate part: a critique setting nobody
    # uses must not change the key, and the pool must stay in it.
    def signature
      return nil unless all_stages_in_pool?

      signature = {'models' => pool.map(&:to_s), 'generate_start' => @starts['generate']}
      return signature unless stage?('critique')

      signature.merge('critique_start' => @starts['critique'], 'rank' => @rank, 'allow_weaker' => @allow_weaker)
    end

    # The critique selection rule in words, for --dry-run.
    def rule
      return nil unless stage?('critique') && all_stages_in_pool?
      return @rank if @rank == 'any' || !@allow_weaker

      "#{@rank}, weaker allowed"
    end

    def pool?
      true
    end

    def pool_stage?(stage)
      stage?(stage) && !@own_chains.stage?(stage)
    end

    def pool_member?(model)
      return false if model.nil?

      @items.any? { |item| match?(item, model) }
    end

    def start_used?(stage)
      !@starts[stage.to_s].nil?
    end

    private

    def all_stages_in_pool?
      @stages.all? { |stage| pool_stage?(stage) }
    end

    def rank_applies?(after)
      all_stages_in_pool? && @rank != 'any' && pool_member?(after)
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

    # The start of a stage with its own chain is not checked: it is outside the pool.
    def resolve_starts(starts, inherited)
      @stages.to_h do |stage|
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

    # A model is given by name, as "provider/name" or by its full name; a
    # candidate matches by provider, name and server address.
    def match?(item, model)
      return self.class.item_name(item) == model.to_s if model.is_a?(ModelCandidate)

      self.class.names(item).include?(model.to_s)
    end

    def match_candidate?(candidate, model)
      candidate.names.include?(model.to_s)
    end

    def critique_policy(rank, allow_weaker)
      return [nil, false] unless stage?('critique')

      [validate_rank(rank), allow_weaker == true]
    end

    def validate_rank(rank)
      rank = (rank || DEFAULT_CRITIQUE_RANK).to_s
      return rank if CRITIQUE_RANKS.include?(rank)

      raise ConfigError, "llm.critique.rank must be one of #{CRITIQUE_RANKS.join(', ')}, got #{rank.inspect}"
    end

    def parse_items(items, provider)
      parsed = Array(items).each_with_index.map { |item, index| self.class.parse_item(item, index, provider) }
      raise ConfigError, 'llm.models must not be empty' if parsed.empty?

      names = parsed.map { |item| self.class.item_name(item) }
      duplicates = names.tally.select { |_, count| count > 1 }.keys
      raise ConfigError, "llm.models has duplicates: #{duplicates.join(', ')}" unless duplicates.empty?

      parsed
    end
  end
end
