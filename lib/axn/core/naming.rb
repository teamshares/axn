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

        # `description` is generic enough that an adapter base class (e.g. ::MCP::Tool) is likely to
        # already define its own, differently-scoped one. Only layer axn's on when the name is free —
        # otherwise `extend` would sit above that base class and silently shadow it (PRO-2875).
        if Axn::Core::MethodShadowing.externally_defined?(base, :description)
          Axn.config.logger.debug do
            "[Axn] #{base.name || 'Action'}: skipping axn's class-level `description` DSL (already defined by a non-Axn ancestor)"
          end
        else
          base.extend(DescriptionMethod)
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze

        def axn_name(value = NOT_SET)
          return _axn_name if value.equal?(NOT_SET)

          raise ArgumentError, "axn_name must be a non-blank String (got #{value.inspect})" unless value.is_a?(String) && !value.strip.empty?

          self._axn_name = value
        end

        # The single canonical display name: explicit override, else Ruby's class name,
        # else a stable fallback (replaces the old literal "Anonymous Class").
        def resolved_axn_name
          axn_name.presence || name.presence || ANONYMOUS
        end
      end

      # Split out of ClassMethods so `included` can extend it conditionally (see above): a shared
      # module can't be selectively un-extended per including class.
      module DescriptionMethod
        def description(value = ClassMethods::NOT_SET)
          return _axn_description if value.equal?(ClassMethods::NOT_SET)

          self._axn_description = value
        end
      end
    end
  end
end
