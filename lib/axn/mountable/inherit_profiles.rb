# frozen_string_literal: true

module Axn
  module Mountable
    module InheritProfiles
      # Predefined inheritance profiles for mounting strategies
      PROFILES = {
        # Inherits parent's lifecycle (hooks, callbacks, messages, async) but not fields
        # Use this when the mounted action should participate in the parent's execution lifecycle
        # but have its own independent contract
        # NOTE: Strategies cannot be controlled - they're mixed in via `include` and become part of the ancestry
        lifecycle: {
          fields: false,
          messages: true,
          hooks: true,
          callbacks: true,
          async: true,
        }.freeze,

        # Only inherits async config - for utility methods like enqueue_all
        # Use this when you need async capability but nothing else from the parent
        async_only: {
          fields: false,
          messages: false,
          hooks: false,
          callbacks: false,
          async: true,
        }.freeze,

        # Inherits nothing - completely standalone
        # Use this when the mounted action should be completely independent from the parent
        none: {
          fields: false,
          messages: false,
          hooks: false,
          callbacks: false,
          async: false,
        }.freeze,
      }.freeze

      # Resolve an inherit configuration to a full hash
      # @param inherit [Symbol, Hash] The inherit configuration
      # @return [Hash] A hash with all inheritance options set to true/false
      def self.resolve(inherit)
        case inherit
        when Symbol
          PROFILES.fetch(inherit) do
            raise ArgumentError, "Unknown inherit profile: #{inherit.inspect}. Valid profiles: #{PROFILES.keys.join(", ")}"
          end
        when Hash
          # Validate hash keys
          invalid_keys = inherit.keys - PROFILES[:none].keys
          raise ArgumentError, "Invalid inherit keys: #{invalid_keys.join(", ")}. Valid keys: #{PROFILES[:none].keys.join(", ")}" if invalid_keys.any?

          # Merge with none profile to ensure all keys are present
          PROFILES[:none].merge(inherit)
        else
          raise ArgumentError, "inherit must be a Symbol or Hash. Got: #{inherit.class}"
        end
      end

      # Check if a specific feature should be inherited
      # @param inherit [Symbol, Hash] The inherit configuration
      # @param feature [Symbol] The feature to check (e.g., :hooks, :async)
      # @return [Boolean]
      def self.inherit?(inherit, feature)
        resolved = resolve(inherit)
        resolved.fetch(feature)
      end
    end
  end
end
