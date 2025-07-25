# frozen_string_literal: true

module Action
  module UseStrategy
    extend ActiveSupport::Concern

    class_methods do
      def use(strategy_name, **config, &block)
        strategy = Action::Strategies.all[strategy_name.to_sym]
        raise StrategyNotFound, "Strategy #{strategy_name} not found" if strategy.blank?
        raise ArgumentError, "Strategy #{strategy_name} does not support config" if config.any? && !strategy.respond_to?(:setup)

        # Allow dynamic setup of strategy (i.e. dynamically define module before returning)
        if strategy.respond_to?(:setup)
          configured = strategy.setup(**config, &block)
          raise ArgumentError, "Strategy #{strategy_name} setup method must return a module" unless configured.is_a?(Module)

          strategy = configured
        else
          raise ArgumentError, "Strategy #{strategy_name} does not support config (define #setup method)" if config.any?
          raise ArgumentError, "Strategy #{strategy_name} does not support blocks (define #setup method)" if block_given?
        end

        include strategy
      end
    end
  end
end
