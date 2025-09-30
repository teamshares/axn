# frozen_string_literal: true

require "axn/internal/registry"

module Axn
  module Attachable
    class AttachmentTypeNotFound < Axn::Internal::Registry::NotFound; end
    class DuplicateAttachmentTypeError < Axn::Internal::Registry::DuplicateError; end

    class AttachmentTypes < Axn::Internal::Registry
      class << self
        def registry_directory = __dir__

        private

        def item_type = "Attachment Type"
        def not_found_error_class = AttachmentTypeNotFound
        def duplicate_error_class = DuplicateAttachmentTypeError
      end
    end

    # Trigger registry loading to ensure attachment types are available
    AttachmentTypes.all
  end
end
