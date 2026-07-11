# frozen_string_literal: true

module Axn
  module Core
    # `include Axn` extends generic class-method DSLs (description, input_schema, output_schema) onto
    # the including class. Ruby places extended modules ABOVE the superclass chain in the singleton
    # method-resolution order, so on a class that subclasses an adapter base which already owns one of
    # those names (e.g. Axn::MCP::Tool < ::MCP::Tool, whose own description/input_schema/output_schema
    # carry transport meaning), axn's generic version would silently win over it. The DSL hooks consult
    # this to defer instead of clobbering (PRO-2875) — the same discipline that gave `axn_name` its
    # prefix, applied to the other generic names a transport base class is likely to already define.
    module MethodShadowing
      module_function

      # True when `base` already provides class method `name` from somewhere other than an Axn-owned
      # module — its superclass chain (the shadowing case) or an explicit `def self.#{name}` on the
      # class itself. Call before `extend`ing axn's own version; a false means the name is free.
      def externally_defined?(base, name)
        base.singleton_class.ancestors.any? do |mod|
          next false if _axn_owned?(mod)

          mod.instance_methods(false).include?(name) || mod.private_instance_methods(false).include?(name)
        end
      end

      def _axn_owned?(mod)
        !!mod.name&.start_with?("Axn::")
      end
    end
  end
end
