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

        # A class's adapter declaration in the one form `_async_adapter` stores and every reader compares, so
        # nothing downstream branches on how it was written: `async false`, `async :disabled` and
        # `async "disabled"` all declare the Disabled adapter, so all three are `false`. Otherwise as `key`.
        def canonical(adapter)
          key = key(adapter)
          key == :disabled ? false : key
        end

        # An adapter selection with its spelling normalized and NOTHING else: a String or Symbol becomes its
        # registry key Symbol (`"disabled"` is `:disabled`), while `false` and nil are returned as they are, and so is
        # anything else, for `find` to reject as before. The config setters store this form, because there `false`
        # and `:disabled` differ. `false` means no adapter at that level (an enqueue-all override of `false` defers
        # to the default), while `:disabled` names the Disabled adapter, which is applied to the orchestrator.
        def key(adapter)
          return adapter unless adapter.is_a?(::String) || adapter.is_a?(::Symbol)

          adapter.to_sym
        end

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
