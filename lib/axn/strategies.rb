# frozen_string_literal: true

require "axn/internal/registry"

module Axn
  class StrategyNotFound < Axn::Internal::Registry::NotFound; end
  class DuplicateStrategyError < Axn::Internal::Registry::DuplicateError; end

  class Strategies < Axn::Internal::Registry
    class << self
      def built_in
        @built_in ||= begin
          strategy_files = Dir[File.join(__dir__, "strategies", "*.rb")]
          strategy_files.each { |file| require file }

          constants = Axn::Strategies.constants.map { |const| Axn::Strategies.const_get(const) }
          mods = constants.select { |const| const.is_a?(Module) }

          mods.to_h { |mod| [mod.name.split("::").last.downcase.to_sym, mod] }
        end
      end

      private

      def item_type
        "Strategy"
      end

      def not_found_error_class
        StrategyNotFound
      end

      def duplicate_error_class
        DuplicateStrategyError
      end
    end
  end
end
