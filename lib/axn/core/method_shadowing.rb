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
      # Bound rather than dispatched: this walks EVERY ancestor of the including class's singleton, which
      # includes any module patched onto Object, and one of those defining its own `self.name` would get
      # that code run during `include Axn` — a raise there takes the include down.
      MODULE_NAME = ::Module.instance_method(:name)
      KERNEL_SINGLETON_CLASS = ::Kernel.instance_method(:singleton_class)
      MODULE_INSTANCE_METHODS = ::Module.instance_method(:instance_methods)
      MODULE_PRIVATE_INSTANCE_METHODS = ::Module.instance_method(:private_instance_methods)
      private_constant :MODULE_NAME, :KERNEL_SINGLETON_CLASS, :MODULE_INSTANCE_METHODS,
                       :MODULE_PRIVATE_INSTANCE_METHODS

      module_function

      # True when `base` already provides class method `name` from somewhere other than an axn-CORE
      # module — its superclass chain (the shadowing case) or an explicit `def self.#{name}` on the
      # class itself. Call before `extend`ing axn's own version; a false means the name is free.
      def externally_defined?(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(KERNEL_SINGLETON_CLASS.bind_call(base))
        ancestry.any? do |mod|
          next false if _axn_core_owned?(mod)

          MODULE_INSTANCE_METHODS.bind_call(mod, false).include?(name) ||
            MODULE_PRIVATE_INSTANCE_METHODS.bind_call(mod, false).include?(name)
        end
      end

      # Only axn CORE's own DSL modules (all namespaced `Axn::Core::*`) are excluded — deliberately NOT
      # the whole `Axn::` namespace. Satellite adapters live under sibling namespaces like `Axn::MCP`
      # (see Axn::Configurable), and their DSL is exactly what we must defer to: an adapter base that
      # picks up `description`/`input_schema`/`output_schema` from an `Axn::MCP::*` module counts as
      # external, so axn won't re-extend and shadow it.
      def _axn_core_owned?(mod)
        !!MODULE_NAME.bind_call(mod)&.start_with?("Axn::Core::")
      end
      # `module_function` already made the instance copy private; this makes the module-level one match.
      private_class_method :_axn_core_owned?
    end
  end
end
