# frozen_string_literal: true
require_relative 'lib/aireview/version'

Gem::Specification.new do |spec|
  spec.name = 'aireview'
  spec.version = Aireview::VERSION
  spec.summary = 'Local GitLab merge request review CLI powered by LLMs'
  spec.description = 'Reviews self-hosted GitLab merge requests with a two-pass LLM pipeline: ' \
                     'the first pass finds candidate findings, the second one critiques them and ' \
                     'drops the weak ones. Supports Gemini and local Ollama, optional Jira context ' \
                     'and posting a single updatable review note back to the merge request.'
  spec.authors = ['Denis Levenko']
  spec.homepage = 'https://github.com/DenisDenis9331/aireview'
  spec.license = 'MIT'
  spec.files = Dir.chdir(__dir__) do
    Dir[
      'bin/*',
      'config/.aireview.yml.example',
      'config/defaults.yml',
      'lib/**/*.{rb,txt}',
      'CHANGELOG.md',
      'CONTRIBUTORS.md',
      'README.md',
      'LICENSE'
    ]
  end
  spec.bindir = 'bin'
  spec.executables = ['aireview']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.1.3'

  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'faraday', '~> 2.14', '>= 2.14.4'
  spec.add_dependency 'ruby_llm', '1.16.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['funding_uri'] = 'https://ko-fi.com/denis1011101'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
