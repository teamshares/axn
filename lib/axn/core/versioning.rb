# frozen_string_literal: true

module Axn
  module Core
    # First-class tool contract version — a sibling of `tool_name`, never part of it.
    # `_tool_version` nil means "undeclared" (effective version 1, and the group default).
    # Advisory/metadata like SemanticHints; the registry groups by (tool_name, tool_version).
    module Versioning
      def self.included(base)
        base.class_eval do
          # instance_accessor: false — class-level DSL, not per-instance state.
          # _tool_version nil = undeclared (effective 1 & default); separate calls so each
          # carries its own default.
          class_attribute :_tool_version, instance_accessor: false, default: nil
          class_attribute :_tool_version_default, instance_accessor: false, default: false
          extend ClassMethods
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze
        private_constant :NOT_SET

        # Matches a constant's final segment when it is exactly the vN convention (`V1`, `v2`).
        VERSION_SEGMENT = /\Av(\d+)\z/i

        # `tool_version 2, default: true` sets; zero-arg reads the effective version (1 when
        # undeclared). `default: true` blesses this version as the movable stable pin adapters
        # that pin (e.g. an HTTP bare path) honor; it is a no-op on an only/earliest version.
        def tool_version(value = NOT_SET, default: false)
          return _tool_version || 1 if value.equal?(NOT_SET)

          raise ArgumentError, "tool_version must be an Integer >= 1 (got #{value.inspect})" unless value.is_a?(Integer) && value >= 1

          _assert_version_segment_matches!(value)
          self._tool_version = value
          self._tool_version_default = default
          value
        end

        private

        # When the constant follows the ::Vn convention, the segment number and the declared
        # version must agree — the segment is what `tool_name` derivation drops, so a mismatch
        # (`::V2` declaring `tool_version 3`) would ship a name/number that disagree. Skipped for
        # an anonymous class (no constant name) — the factory / `Class.new` path is unaffected.
        def _assert_version_segment_matches!(value)
          segment = name.to_s.split("::").last
          return unless segment&.match(VERSION_SEGMENT)

          declared_in_name = Regexp.last_match(1).to_i
          return if declared_in_name == value

          raise ArgumentError,
                "#{name}: constant ends in ::#{segment} but `tool_version #{value}` was declared. " \
                "Align the constant name and the version (rename to ::V#{value}) or drop the ::vN suffix."
        end
      end
    end
  end
end
