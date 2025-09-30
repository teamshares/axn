# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentTypes
      module Step
        def self.mount(attachment_name, axn_klass, on:, **options)
          # Set up error handling
          error_prefix = options[:error_prefix] || "#{attachment_name}: "
          on.error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end
        end
      end
    end
  end
end
