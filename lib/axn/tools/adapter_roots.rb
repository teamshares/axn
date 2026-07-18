# frozen_string_literal: true

module Axn
  module Tools
    # Mixed into an adapter's config module (which already `extend Axn::Configurable`) to declare
    # a validated `tool_roots` directory list. Each adapter names the directories it consumes; the
    # registry reads `<adapter>.config.tool_roots` to compute directory-based membership. Validation
    # reuses core's single broad-path guard so no adapter can widen a root to `app/`, `.`, `actions`,
    # or a `..` traversal that would bulk-expose every business action.
    module AdapterRoots
      def self.extended(base)
        base.setting :tool_roots, default: [], validate: ->(value) { AdapterRoots.validate!(value) }
      end

      # Returns true when valid; raises ArgumentError with a specific message otherwise. Raising from
      # a `validate:` lambda propagates through Setting#validate! (Axn::Configurable), so a bad root
      # fails at assignment rather than with the generic "got invalid value".
      def self.validate!(value)
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
          raise ArgumentError, "tool_roots must be an Array of Strings; got #{value.inspect}"
        end

        value.each do |entry|
          next unless Axn::Configuration.broad_tool_path?(entry)

          raise ArgumentError,
                "tool_roots entry #{entry.inspect} is too broad: it resolves to the project root, escapes " \
                "via `..`, or ends in a broad directory (`actions`/`app`) that would auto-expose every " \
                "business action. Use a dedicated narrow subdir such as `agent_tools` or `actions/tools`."
        end

        true
      end
    end
  end
end
