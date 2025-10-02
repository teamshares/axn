# frozen_string_literal: true

require "axn/internal/registry"

module Axn
  module Attachable
    class AttachmentTypeNotFound < Axn::Internal::Registry::NotFound; end
    class DuplicateAttachmentTypeError < Axn::Internal::Registry::DuplicateError; end

    class AttachmentStrategies < Axn::Internal::Registry
      class << self
        def registry_directory = __dir__

        private

        def item_type = "Attachment Type"
        def not_found_error_class = AttachmentTypeNotFound
        def duplicate_error_class = DuplicateAttachmentTypeError

        def select_constants_to_load(constants)
          # Select modules that are not the Base module
          constants.select do |const|
            const.is_a?(Module) && const != Base
          end
        end
      end
    end

    # Trigger registry loading to ensure attachment strategies are available
    AttachmentStrategies.all
  end
end
