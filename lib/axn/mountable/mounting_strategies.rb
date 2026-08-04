# frozen_string_literal: true

require "axn/error"
require "axn/internal/registry"

module Axn
  module Mountable
    # Deliberately NOT descended from the registry's internal base classes: a public class must not put
    # an Axn::Internal constant in its ancestry, and "any registry lookup miss" is `rescue Axn::Error`.
    class MountingTypeNotFound < StandardError
      include Axn::Error
    end

    class DuplicateMountingTypeError < StandardError
      include Axn::Error
    end

    class MountingStrategies < Axn::Internal::Registry
      class << self
        def registry_directory = __dir__

        private

        def item_type = "Mounting Type"
        def not_found_error_class = MountingTypeNotFound
        def duplicate_error_class = DuplicateMountingTypeError

        def select_constants_to_load(constants)
          # Select modules that are not the Base module
          constants.select do |const|
            const.is_a?(Module) && const != Base
          end
        end
      end
    end

    # Trigger registry loading to ensure mounting strategies are available
    MountingStrategies.all
  end
end
