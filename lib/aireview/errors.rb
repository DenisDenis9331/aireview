# frozen_string_literal: true
module Aireview
  class Error < StandardError; end
  class ConfigError < Error; end
  class ParseError < Error; end
  # Починка негодного JSON невозможна: у ответившей модели кончились попытки
  # или она в карантине без бюджета на ожидание. Для пайплайна это тот же
  # негодный результат — стадия перезапускается на другой модели.
  class RepairImpossibleError < ParseError; end
  class ApiError < Error; end
  # Закреплённый маршрут (починка JSON той же моделью) не смог ответить:
  # попытки кончились, модель исключена или в карантине без бюджета на
  # ожидание. Не фатально для прогона — стадия перезапускается на другой модели.
  class RouteExhaustedError < ApiError; end
  class ContextBudgetError < Error; end
  class HelpRequested < Error; end
end
