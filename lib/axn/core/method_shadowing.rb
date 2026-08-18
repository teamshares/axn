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
      KERNEL_SINGLETON_CLASS = ::Kernel.instance_method(:singleton_class)
      private_constant :KERNEL_SINGLETON_CLASS

      module_function

      # True when `base` already provides class method `name` from somewhere other than an axn-CORE
      # module — its superclass chain (the shadowing case) or an explicit `def self.#{name}` on the
      # class itself. Call before `extend`ing axn's own version; a false means the name is free.
      def externally_defined?(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(KERNEL_SINGLETON_CLASS.bind_call(base))
        !_external_definer(ancestry, name).nil?
      end

      # The instance-side counterpart, and the module that stands in the way rather than a boolean, because the
      # caller both defers to it and names it in an error. Two things differ from the class-side walk above, and
      # both are about what counts as "the user's own":
      #
      # Truncated at ::Object, because everything from there outward is Ruby's. `Kernel` owns `warn` and `Object`
      # owns `inspect`/`hash`/`then`/`tap`, so an untruncated walk would make axn permanently decline to define
      # `warn` and silently redirect every `warn("msg")` inside an action to stderr instead of the logger.
      #
      # `base` itself is excluded (along with anything prepended to it, which already outranks whatever axn
      # installs). A `def log` in the class body is the user's own method and wins on its own terms, with `super`
      # reaching axn's — treating it as a deferral target would point the deferral at the very method it defers.
      def inherited_definer(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(base)
        above_base = ancestry.drop_while { |mod| !Axn::Internal::Identity.same?(mod, base) }.drop(1)
        _external_definer(above_base.take_while { |mod| !Axn::Internal::Identity.same?(mod, ::Object) }, name)
      end

      # The first module in `ancestry` that declares `name` in its OWN table, skipping axn core's. Own table
      # rather than effective lookup: the question is who would be shadowed, and a prepend elsewhere in the
      # chain does not make a declaration disappear.
      def _external_definer(ancestry, name)
        ancestry.find do |mod|
          next false if _axn_core_owned?(mod)

          Axn::Internal::NativeMethods.declares_own_instance_method?(mod, name)
        end
      end
      private_class_method :_external_definer

      # Only axn CORE is excluded — `Axn::Core` itself, which carries the instance-side `fail!`/`done!`/
      # `forward!`/`_run`, and everything under it — deliberately NOT the whole `Axn::` namespace.
      # Satellite adapters live under sibling namespaces like `Axn::MCP` (see Axn::Configurable), and
      # their DSL is exactly what we must defer to: an adapter base that picks up
      # `description`/`input_schema`/`output_schema` from an `Axn::MCP::*` module counts as external, so
      # axn won't re-extend and shadow it.
      def _axn_core_owned?(mod)
        name = Axn::Internal::NativeMethods.declared_module_name(mod)
        return false unless name

        name == "Axn::Core" || name.start_with?("Axn::Core::")
      end
      # `module_function` already made the instance copy private; this makes the module-level one match.
      private_class_method :_axn_core_owned?
    end
  end
end
