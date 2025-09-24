# frozen_string_literal: true

module Axn
  module Core
    module UseStrategy
      extend ActiveSupport::Concern

      class_methods do
        def use(strategy_name, **config, &block)
          strategy = Axn::Strategies.find(strategy_name)
          raise ArgumentError, "Strategy #{strategy_name} does not support config" if config.any? && !strategy.respond_to?(:configure)

          # Allow dynamic configuration of strategy (i.e. dynamically define module before returning)
          if strategy.respond_to?(:configure)
            configured = strategy.configure(**config, &block)
            raise ArgumentError, "Strategy #{strategy_name} configure method must return a module" unless configured.is_a?(Module)

            strategy = configured
          else
            raise ArgumentError, "Strategy #{strategy_name} does not support config (define #configure method)" if config.any?
            raise ArgumentError, "Strategy #{strategy_name} does not support blocks (define #configure method)" if block_given?
          end

          include strategy
        end
      end
    end
  end
end
