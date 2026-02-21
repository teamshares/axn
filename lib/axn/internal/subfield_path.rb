# frozen_string_literal: true

module Axn
  module Internal
    # Pure utility functions for working with subfield paths (e.g., "user.profile.name").
    # These are stateless functions that operate only on their arguments.
    module SubfieldPath
      module_function

      # Checks if a subfield path contains nested access (e.g., "user.profile.name")
      def nested?(subfield)
        subfield.to_s.include?(".")
      end

      # Parses a subfield path into an array of parts
      def parse(subfield)
        subfield.to_s.split(".")
      end

      # Navigates to the parent of the target field, creating intermediate hashes as needed
      def navigate_to_parent(parent_value, path_parts)
        path_parts[0..-2].reduce(parent_value) do |current, part|
          current[part.to_sym] || current[part] || (current[part.to_sym] = {})
        end
      end

      # Updates an object subfield using method assignment
      def update_object(parent_value, subfield, new_value)
        parent_value.public_send("#{subfield}=", new_value)
      end
    end
  end
end
