module Aireview
  class Error < StandardError; end
  class ConfigError < Error; end
  class ParseError < Error; end
  class ApiError < Error; end
  class HelpRequested < Error; end
end
