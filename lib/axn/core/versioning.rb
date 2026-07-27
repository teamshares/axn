# frozen_string_literal: true

module Axn
  module Core
    # First-class tool contract version — a sibling of `tool_name`, never part of it.
    # `_tool_version` nil means "undeclared" (effective version 1).
    # Advisory/metadata like SemanticHints; the registry groups by (tool_name, tool_version).
    module Versioning
      def self.included(base)
        base.class_eval do
          # instance_accessor: false — class-level DSL, not per-instance state.
          # _tool_version nil = undeclared (effective 1).
          class_attribute :_tool_version, instance_accessor: false, default: nil
          extend ClassMethods
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze
        private_constant :NOT_SET

        # Matches a constant's final segment when it is exactly the vN convention (`V1`, `v2`).
        VERSION_SEGMENT = /\Av(\d+)\z/i

        # `tool_version 2` sets; zero-arg reads the effective version (1 when undeclared).
        # `**nil` — takes no keywords at all. Without it, a lone keyword (`tool_version default: true`,
        # the removed pin option) would bind to `value` as a positional Hash and surface the bespoke
        # "must be an Integer >= 1", implying the option exists and was merely mistyped. Refusing
        # keywords outright yields the plain `no keywords accepted` a removed option should raise.
        def tool_version(value = NOT_SET, **nil)
          return _tool_version || 1 if value.equal?(NOT_SET)

          raise ArgumentError, "tool_version must be an Integer >= 1 (got #{value.inspect})" unless value.is_a?(Integer) && value >= 1

          _assert_version_segment_matches!(value)
          self._tool_version = value
          # Non-inherited marker: `_tool_version` is a class_attribute (subclasses inherit its value),
          # so it can't answer "did THIS class declare a version?". A plain ivar on the class object
          # isn't inherited, so a `::V2` subclass that only inherits a parent's `tool_version 1` is
          # correctly seen as not-declared-here (see `_tool_version_declared_here?`).
          @_tool_version_declared = true
          value
        end

        # True only when THIS class called `tool_version` itself — an inherited value does not count.
        # Consumed by the registry's orphan guard and by `tool_name`'s `::Vn`-drop, so both treat a
        # `::Vn` class that merely inherits a version as unversioned (raise / no-drop) rather than
        # silently publishing it under the inherited number.
        def _tool_version_declared_here?
          instance_variable_defined?(:@_tool_version_declared)
        end

        # The version number a trailing `::Vn` constant segment encodes (`AgentTools::Approve::V2` →
        # 2), or nil when the constant isn't vN-suffixed or the class is anonymous. The single place
        # the vN suffix is parsed — consumed by the declaration-time guard below and by the registry's
        # enumeration guard, so the two can't drift.
        def _tool_version_suffix
          match = name.to_s.split("::").last&.match(VERSION_SEGMENT)
          match && match[1].to_i
        end

        private

        # When the constant follows the ::Vn convention, the segment number and the declared version
        # must agree — the segment is what `tool_name` derivation drops, so a mismatch (`::V2`
        # declaring `tool_version 3`) would ship a name/number that disagree. Skipped for an anonymous
        # class (no constant name yet) — the factory / `Const = Class.new` path can't see the eventual
        # name here, so the registry's enumeration guard is the backstop that re-checks it once named.
        def _assert_version_segment_matches!(value)
          suffix = _tool_version_suffix
          return if suffix.nil? || suffix == value

          raise ArgumentError,
                "#{name}: constant ends in ::V#{suffix} but `tool_version #{value}` was declared. " \
                "Align the constant name and the version (rename to ::V#{value}) or drop the ::vN suffix."
        end
      end
    end
  end
end
