# frozen_string_literal: true

module Aireview
  # Две стадии ревью: generate ищет замечания, critique их проверяет.
  # Единственное определение; внутри кода стадия — строка.
  STAGES = %w[generate critique].freeze
end
