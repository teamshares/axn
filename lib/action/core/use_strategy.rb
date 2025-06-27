# frozen_string_literal: true

module Action
  module UseStrategy
    extend ActiveSupport::Concern

    class_methods do
      def use(strategy_name, **config)
        strategy = Action::Strategies.all[strategy_name.to_sym]
        raise StrategyNotFound, "Strategy #{strategy_name} not found" if strategy.blank?
        raise ArgumentError, "Strategy #{strategy_name} does not support config" if config.any? && !strategy.respond_to?(:setup)

        include strategy.respond_to?(:setup) ? strategy.setup(**config) : strategy
      end
    end
  end
end
