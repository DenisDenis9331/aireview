require 'aireview/stages'

# Config doubles that answer the critique engine questions like the default
# engine (model): an LLM for both stages, only Generate without a critique.
module ConfigStages
  def allow_model_engine(config)
    allow(config).to receive(:llm_stages) { |critique: true| critique ? Aireview::STAGES : ['generate'] }
    allow(config).to receive(:jev_critique?).and_return(false)
    config
  end
end

RSpec.configure { |config| config.include ConfigStages }
