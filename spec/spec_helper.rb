$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'logger'
# Настоящий RubyLLM: классы ошибок, контекст и реестр моделей — те же, что
# в бою; в сеть спеки не ходят, RubyLLM.context и chat подменяются явно.
require 'ruby_llm'

Dir[File.expand_path('support/**/*.rb', __dir__)].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
