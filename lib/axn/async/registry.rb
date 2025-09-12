# frozen_string_literal: true

require "axn/internal/registry"
require "active_support/core_ext/string/inflections"

module Axn
  module Async
    class AdapterNotFound < Axn::Internal::Registry::NotFound; end
    class DuplicateAdapterError < Axn::Internal::Registry::DuplicateError; end

    class Registry < Axn::Internal::Registry
      class << self
        def built_in
          @built_in ||= begin
            adapter_files = Dir[File.join(__dir__, "adapters", "*.rb")]
            adapter_files.each { |file| require file }

            constants = Axn::Async::Adapters.constants.map { |const| Axn::Async::Adapters.const_get(const) }
            mods = constants.select { |const| const.is_a?(Module) }

            mods.to_h do |mod|
              name = mod.name.split("::").last
              # Convert CamelCase to snake_case using ActiveSupport
              key = name.underscore.to_sym
              [key, mod]
            end
          end
        end

        private

        def item_type
          "Adapter"
        end

        def not_found_error_class
          AdapterNotFound
        end

        def duplicate_error_class
          DuplicateAdapterError
        end
      end
    end
  end
end
