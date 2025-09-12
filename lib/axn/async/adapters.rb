# frozen_string_literal: true

require "axn/internal/registry"
require "active_support/core_ext/string/inflections"

module Axn
  module Async
    class AdapterNotFound < Axn::Internal::Registry::NotFound; end
    class DuplicateAdapterError < Axn::Internal::Registry::DuplicateError; end

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
