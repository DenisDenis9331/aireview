require 'aireview/output_schemas'

RSpec.describe 'Aireview output schemas' do
  def schema_for(schema_class)
    schema_class.new.to_json_schema.fetch(:schema)
  end

  it 'defines generate fields, enums, nullable line, and candidate limit' do
    schema = schema_for(Aireview::GenerateOutputSchema)
    candidates = schema.dig(:properties, :candidates)
    candidate = candidates.fetch(:items)
    properties = candidate.fetch(:properties)

    expect(schema.fetch(:required)).to contain_exactly(:summary, :candidates)
    expect(schema.fetch(:additionalProperties)).to be(false)
    expect(schema.dig(:properties, :summary, :type)).to eq('string')
    expect(candidates.fetch(:type)).to eq('array')
    expect(candidates.fetch(:maxItems)).to eq(3)
    expect(candidate.fetch(:required)).to contain_exactly(
      :id, :file, :line, :quoted_code, :problem, :why, :suggestion, :category, :severity
    )
    expect(candidate.fetch(:additionalProperties)).to be(false)
    expect(properties.values_at(:id, :file, :quoted_code, :problem, :why, :suggestion).map { |field| field[:type] })
      .to all(eq('string'))
    expect(properties.dig(:line, :anyOf).map { |type| type.fetch(:type) }).to contain_exactly('integer', 'null')
    expect(properties.dig(:category, :enum)).to eq(Aireview::OutputSchemaValues::CATEGORIES)
    expect(properties.dig(:severity, :enum)).to eq(Aireview::OutputSchemaValues::SEVERITIES)
  end

  it 'defines critique decision and optional refinement constraints' do
    schema = schema_for(Aireview::CritiqueOutputSchema)
    verdict = schema.dig(:properties, :verdicts, :items)
    properties = verdict.fetch(:properties)
    refinement = properties.fetch(:refinement)

    expect(schema.fetch(:required)).to contain_exactly(:verdicts)
    expect(schema.fetch(:additionalProperties)).to be(false)
    expect(schema.dig(:properties, :verdicts, :type)).to eq('array')
    expect(verdict.fetch(:required)).to contain_exactly(:id, :decision, :reason)
    expect(verdict.fetch(:additionalProperties)).to be(false)
    expect(properties.values_at(:id, :decision, :reason).map { |field| field[:type] }).to all(eq('string'))
    expect(properties.dig(:decision, :enum)).to eq(Aireview::OutputSchemaValues::DECISIONS)
    expect(refinement.fetch(:additionalProperties)).to be(false)
    expect(refinement.fetch(:required)).to contain_exactly(:problem, :why, :suggestion, :category, :severity)
    expect(refinement.dig(:properties, :category, :enum)).to eq(Aireview::OutputSchemaValues::CATEGORIES)
    expect(refinement.dig(:properties, :severity, :enum)).to eq(Aireview::OutputSchemaValues::SEVERITIES)
  end
end
