require 'yaml'

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
      'Do not verify that the specified versions',
      'All free-text fields must be written in the language'
    )
  end

  # The Jev questions ask the critique rules one by one; a rule dropped from
  # one side and not the other makes the two critics decide differently.
  it 'keeps the critique rules in the Jev questions' do
    questions = YAML.safe_load_file(File.join(prompts_dir, 'jev_questions.yml'))
    real_issue = questions.dig('real_issue', 'criteria').values.join(' ')
    shared = [
      'directly confirmed by the diff', 'binding.pry, byebug, console.log', 'commented-out blocks',
      'temporary TODO/HACK/FIXME/DEBUG markers', 'disabled tests', 'assumption about code outside the diff',
      'contradicts the diff', 'not actionable', '"may be redundant", "may conflict"',
      'details (config flags, deploy settings, new fields, helper methods)',
      'accompanying refactoring', 'does not mean a missing'
    ]

    shared.each do |rule|
      expect(critique_prompt.gsub(/\s+/, ' ')).to include(rule)
      expect(real_issue).to include(rule)
    end
    expect(critique_prompt).to include('duplicates another candidate', 'claiming that a version does not exist')
    expect(questions.keys).to include('duplicate_of', 'version_claim', 'enough_context')
  end

  it 'keeps critique rules without a duplicated JSON example' do
    expect(critique_prompt).not_to include('Schema:', '"verdicts":', '"decision":')
    expect(critique_prompt).to include(
      'The answer must be a valid JSON object only',
      'verdicts: a verdict for every id from the input list',
      'decision: keep or reject',
      'refinement: optional, only for keep',
      'Do not change file, line, quoted_code',
      'Do not verify that the specified versions',
      'Reject candidates claiming that a version does not exist',
      'All free-text fields must be written in the language'
    )
  end
end
