require_relative 'lib/aireview/version'

Gem::Specification.new do |spec|
  spec.name = 'aireview'
  spec.version = Aireview::VERSION
  spec.summary = 'Local GitLab merge request review CLI powered by LLMs'
  spec.authors = ['Denis Levenko']
  spec.files = Dir.chdir(__dir__) do
    Dir[
      'bin/*',
      'config/**/*',
      'lib/**/*.{rb,txt}',
      'README.md'
    ]
  end
  spec.bindir = 'bin'
  spec.executables = ['aireview']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.1.3', '< 3.2'
end
