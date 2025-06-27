# frozen_string_literal: true

module Action
  class StrategyNotFound < StandardError; end
  class DuplicateStrategyError < StandardError; end

  # rubocop:disable Style/ClassVars
  module Strategies
    extend ActiveSupport::Concern

    included do
      @@strategies = nil # Will be lazily initialized
    end

    class_methods do
      def built_in
        return @built_in if defined?(@built_in)

        strategy_files = Dir[File.join(__dir__, "strategies", "*.rb")]
        strategy_files.each { |file| require file }

        constants = Action::Strategies.constants.map { |const| Action::Strategies.const_get(const) }
        mods = constants.select { |const| const.is_a?(Module) }

        @built_in = mods.map { |mod| [mod.name&.split("::")&.last&.downcase&.to_sym, mod] }.to_h
      end

      def register(name, strategy)
        @@strategies ||= built_in
        key = name.to_sym
        raise DuplicateStrategyError, "Strategy #{name} already registered" if @@strategies.key?(key)

        @@strategies[key] = strategy
        @@strategies
      end

      def all
        @@strategies ||= built_in
      end

      def clear!
        @@strategies = built_in
      end
    end
  end
  # rubocop:enable Style/ClassVars

  module Strategies::Usable
    extend ActiveSupport::Concern

    class_methods do
      # TODO: support configs
      def use(strategy_name)
        strategy = all[strategy_name.to_sym]
        raise StrategyNotFound, "Strategy #{strategy_name} not found" if strategy.blank?

        include strategy
      end
    end
  end
end
