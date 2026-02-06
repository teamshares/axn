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

      # Checks if a subfield exists in the parent value, handling both hash and object types
      def exists?(parent_value, subfield)
        if parent_value.is_a?(Hash)
          hash_exists?(parent_value, subfield)
        elsif parent_value.respond_to?(subfield)
          object_exists?(parent_value, subfield)
        else
          false
        end
      end

      # Checks if a subfield exists in a hash, handling both simple and nested paths
      def hash_exists?(parent_value, subfield)
        if nested?(subfield)
          nested_hash_exists?(parent_value, subfield)
        else
          simple_hash_exists?(parent_value, subfield)
        end
      end

      # Checks if a simple (non-nested) hash subfield exists
      def simple_hash_exists?(parent_value, subfield)
        parent_value.key?(subfield.to_sym) || parent_value.key?(subfield)
      end

      # Checks if a nested hash subfield exists by navigating the path
      def nested_hash_exists?(parent_value, subfield)
        path_parts = parse(subfield)
        current = parent_value

        path_parts.each do |part|
          return false unless current.is_a?(Hash)
          return false unless current.key?(part.to_sym) || current.key?(part)

          current = current[part.to_sym] || current[part]
        end

        true
      end

      # Checks if an object subfield exists (not nil)
      # This ensures we apply defaults for nil values on objects
      def object_exists?(parent_value, subfield)
        !parent_value.public_send(subfield).nil?
      end
    end
  end
end
