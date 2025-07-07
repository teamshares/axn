# frozen_string_literal: true

module Action
  class StrategyNotFound < StandardError; end
  class DuplicateStrategyError < StandardError; end

  # rubocop:disable Style/ClassVars
  class Strategies
    class << self
      def built_in
        return @@built_in if defined?(@@built_in)

        strategy_files = Dir[File.join(__dir__, "strategies", "*.rb")]
        strategy_files.each { |file| require file }

        constants = Action::Strategies.constants.map { |const| Action::Strategies.const_get(const) }
        mods = constants.select { |const| const.is_a?(Module) }

        @@built_in = mods.to_h { |mod| [mod.name.split("::").last.downcase.to_sym, mod] }
      end

      def register(name, strategy)
        all # ensure built_in is initialized
        key = name.to_sym
        raise DuplicateStrategyError, "Strategy #{name} already registered" if @@strategies.key?(key)

        @@strategies[key] = strategy
        @@strategies
      end

      def all
        @@strategies ||= built_in.dup
      end

      def clear!
        @@strategies = built_in.dup
      end
    end
  end
  # rubocop:enable Style/ClassVars
end
