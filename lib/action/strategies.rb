# frozen_string_literal: true

module Action
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

        @built_in = constants.select { |const| const.is_a?(Module) }
      end

      def register(strategy)
        @@strategies ||= built_in
        @@strategies << strategy unless @@strategies.include?(strategy)
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
      # TODO: support registering via name
      def use(strategy_name)
        strategy = all.find { |strategy| strategy.name&.split("::")&.last&.downcase == strategy_name.to_s }
        raise "Strategy #{strategy_name} not found" unless strategy

        include strategy
      end
    end
  end
end
