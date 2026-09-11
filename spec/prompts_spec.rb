RSpec.describe 'Aireview prompts' do
  let(:prompts_dir) { File.expand_path('../lib/aireview/prompts', __dir__) }
  let(:generate_prompt) { File.read(File.join(prompts_dir, 'generate.txt')) }
  let(:critique_prompt) { File.read(File.join(prompts_dir, 'critique.txt')) }

  it 'keeps generate rules without a duplicated JSON example' do
    expect(generate_prompt).not_to include('Schema:', '"summary":', '"candidates":')
    expect(generate_prompt).to include(
      'The answer must be a valid JSON object only',
      'candidates: at most 3 of the most important findings',
      'id: C1, C2, C3 in order',
      'otherwise null',
      'All free-text fields must be written in the language'
    )
  end

  it 'keeps critique rules without a duplicated JSON example' do
    expect(critique_prompt).not_to include('Schema:', '"verdicts":', '"decision":')
    expect(critique_prompt).to include(
      'The answer must be a valid JSON object only',
      'verdicts: a verdict for every id from the input list',
      'decision: keep or reject',
      'refinement: optional, only for keep',
      'Do not change file, line, quoted_code',
      'All free-text fields must be written in the language'
    )
  end
end
