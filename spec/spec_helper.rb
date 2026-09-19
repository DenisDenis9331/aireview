$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'logger'
# The real RubyLLM: the error classes, the context and the model registry are
# the production ones; specs never touch the network, RubyLLM.context and chat
# are stubbed explicitly.
require 'ruby_llm'

Dir[File.expand_path('support/**/*.rb', __dir__)].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
