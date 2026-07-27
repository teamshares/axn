# frozen_string_literal: true

module Axn
  module Tools
    # The coexisting versions of ONE logical tool (one (adapter, tool_name)), and the single place
    # `latest` resolves — so `tools_for`'s latest-collapse and a per-name lookup consume the same
    # rules instead of each re-deriving them. Validates the group on construction (the relaxed
    # replacement for the old unique-tool_name assertion).
    class VersionGroup
      attr_reader :adapter, :tool_name, :all

      def initialize(adapter:, tool_name:, members:)
        @adapter = adapter
        @tool_name = tool_name
        @all = members.sort_by(&:tool_version)
        _validate!
      end

      # Newest contract. What latest-favoring adapters (MCP, ruby_llm) serve. An adapter that
      # instead addresses each version explicitly (a path-routing HTTP surface) reads `all`.
      def latest
        @all.max_by(&:tool_version)
      end

      private

      def _validate!
        duplicates = @all.group_by(&:tool_version).select { |_version, klasses| klasses.length > 1 }
        return if duplicates.empty?

        details = duplicates.map { |version, klasses| "#{@tool_name.inspect} v#{version} (#{klasses.map(&:name).sort.join(', ')})" }.join("; ")
        raise ArgumentError,
              "Duplicate tool for adapter #{@adapter.inspect}: #{details}. Two tools cannot share a " \
              "(tool_name, tool_version); give one an explicit `tool name: \"...\"` or a distinct `tool_version`."
      end
    end
  end
end
