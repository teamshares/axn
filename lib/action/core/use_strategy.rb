# frozen_string_literal: true

module Action
  module UseStrategy
    extend ActiveSupport::Concern

    class_methods do
      # TODO: support configs
      def use(strategy_name)
        strategy = Action::Strategies.all[strategy_name.to_sym]
        raise StrategyNotFound, "Strategy #{strategy_name} not found" if strategy.blank?

        include strategy
      end
    end
  end
end
