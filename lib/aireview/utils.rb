module Aireview
  module Utils
    module_function

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def present?(value)
      !blank?(value)
    end

    def presence(value)
      present?(value) ? value.to_s.strip : nil
    end
  end
end
