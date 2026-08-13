RSpec.describe 'Aireview prompts' do
  let(:prompts_dir) { File.expand_path('../lib/aireview/prompts', __dir__) }
  let(:generate_prompt) { File.read(File.join(prompts_dir, 'generate.txt')) }
  let(:critique_prompt) { File.read(File.join(prompts_dir, 'critique.txt')) }

  it 'keeps generate rules without a duplicated JSON example' do
    expect(generate_prompt).not_to include('Схема:', '"summary":', '"candidates":')
    expect(generate_prompt).to include(
      'Ответ должен быть только валидным JSON-объектом',
      'candidates: не более 3 самых важных замечаний',
      'id: C1, C2, C3 по порядку',
      'иначе null',
      'Все свободные текстовые поля должны быть на языке'
    )
  end

  it 'keeps critique rules without a duplicated JSON example' do
    expect(critique_prompt).not_to include('Схема:', '"verdicts":', '"decision":')
    expect(critique_prompt).to include(
      'Ответ должен быть только валидным JSON-объектом',
      'verdicts: вердикт по каждому id из входного списка',
      'decision: keep или reject',
      'refinement: необязателен, только для keep',
      'Не меняй file, line, quoted_code',
      'Все свободные текстовые поля должны быть на языке'
    )
  end
end
