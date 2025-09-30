# frozen_string_literal: true

module Axn
  module Attachable
    class AttachmentTypes
      # Base class for all attachment types
      class Base
        # Common functionality can be added here in the future
        # This class serves as a marker for the registry system

        # Placeholder method to avoid empty class warning
        def self.attachment_type_name
          name.split("::").last.underscore.to_sym
        end

        # Default preprocessing - subclasses can override and call super
        def self.preprocess_kwargs(**kwargs)
          kwargs
        end
      end
    end
  end
end
