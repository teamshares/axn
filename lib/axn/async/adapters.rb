# frozen_string_literal: true

require "axn/error"
require "axn/internal/registry"
require "active_support/core_ext/string/inflections"

module Axn
  module Async
    # Deliberately NOT descended from the registry's internal base classes: a public class must not put
    # an Axn::Internal constant in its ancestry, and "any registry lookup miss" is `rescue Axn::Error`.
    class AdapterNotFound < StandardError
      include Axn::Error
    end

    class DuplicateAdapterError < StandardError
      include Axn::Error
    end

    class Adapters < Axn::Internal::Registry
      class << self
        def registry_directory = __dir__

        private

        def item_type = "Adapter"
        def not_found_error_class = AdapterNotFound
        def duplicate_error_class = DuplicateAdapterError
      end
    end

    # Trigger registry loading to ensure adapters are available
    Adapters.all
  end
end
