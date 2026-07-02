# frozen_string_literal: true

module Axn
  module Core
    module Naming
      ANONYMOUS = "Anonymous Axn"

      def self.included(base)
        base.class_eval do
          # instance_accessor: false — this is a class-level DSL, not per-instance state.
          class_attribute :_axn_name, :_axn_description, instance_accessor: false, default: nil
          extend ClassMethods
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze

        def axn_name(value = NOT_SET)
          return _axn_name if value.equal?(NOT_SET)

          self._axn_name = value
        end

        def description(value = NOT_SET)
          return _axn_description if value.equal?(NOT_SET)

          self._axn_description = value
        end

        # The single canonical display name: explicit override, else Ruby's class name,
        # else a stable fallback (replaces the old literal "Anonymous Class").
        def resolved_axn_name
          axn_name.presence || name.presence || ANONYMOUS
        end
      end
    end
  end
end
