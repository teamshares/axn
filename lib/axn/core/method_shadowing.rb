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
      # Truncated at ::Object, because everything from there outward is Ruby's — `Kernel` owns `warn`, `inspect`,
      # `hash`, `then` and `tap`, and `::Object` merely stands in front of it, which is what makes cutting the walk
      # there exclude them. Untruncated, axn would permanently decline to define `warn` and silently redirect every
      # `warn("msg")` inside an action to stderr instead of the logger. `base` is an action class, so `::Object` is
      # always in its ancestry for the truncation to find.
      #
      # `base` itself is excluded (along with anything prepended to it, which already outranks whatever axn
      # installs). A `def log` in the class body is the user's own method and wins on its own terms, with `super`
      # reaching axn's — treating it as a deferral target would point the deferral at the very method it defers.
      def inherited_definer(base, name)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(base)
        above_base = ancestry.drop_while { |mod| !Axn::Internal::Identity.same?(mod, base) }.drop(1)
        _external_definer(above_base.take_while { |mod| !Axn::Internal::Identity.same?(mod, ::Object) }, name)
      end

      # Whether AXN's own definition of `name` is the one a dispatch on `base` would reach. The effective owner
      # rather than a re-walk of own tables: `Module#instance_method` resolves over the whole ancestry the way a
      # call does, so a prepended module counts and an `undef_method`'d name is absent.
      #
      # The complement of `inherited_definer`, and needed alongside it wherever the question is whether axn is
      # STANDING IN THE WAY rather than who it would step aside for. A definition of the user's own anywhere
      # ahead of axn's modules — in the class body, in a module included after `include Axn`, in a prepend —
      # answers instead, and reaches axn's with `super`.
      def core_definition_answers?(base, name)
        owner = Axn::Internal::NativeMethods.declared_instance_method(base, name)&.owner
        !owner.nil? && _axn_core_owned?(owner)
      end

      # The first module in `ancestry` that declares `name` in its OWN table, skipping axn core's. Own table
      # rather than effective lookup: the question is who would be shadowed, and a prepend elsewhere in the
      # chain does not make a declaration disappear.
      #
      # A CLASS that neither declares the name nor can REACH it ends the walk with no definer, because an
      # `undef_method` is exactly that shape: it writes an entry no own-table read reports while a lookup
      # arriving from below stops dead on it. Walking past one finds a definition further out that no dispatch
      # could ever arrive at, and both callers then act on a method that is not there — a wrapper `bind_call`ing
      # the implementation the undef removed, or a refusal naming a `call` the class cannot reach anyway.
      #
      # Effective lookup is the reader that sees the barrier, and on a CLASS its nil is unambiguous: a class's
      # lookup covers the whole remainder of this walk and more, so nothing left to visit can be reachable. On
      # a MODULE nil says only that the module itself does not declare the name — which every module the walk
      # passes through on its way to the answer would also say.
      def _external_definer(ancestry, name)
        ancestry.each do |mod|
          next if _axn_core_owned?(mod)
          return mod if Axn::Internal::NativeMethods.declares_own_instance_method?(mod, name)
          return nil if Axn::Internal::Identity.kind?(mod, ::Class) &&
                        Axn::Internal::NativeMethods.declared_instance_method(mod, name).nil?
        end
        nil
      end
      private_class_method :_external_definer

      # Only axn CORE is excluded — `Axn::Core` itself, which declares axn's instance-side entry point and its
      # flow-control helpers, and everything under it — deliberately NOT the whole `Axn::` namespace.
      # Satellite adapters live under sibling namespaces like `Axn::MCP` (see Axn::Configurable), and
      # their DSL is exactly what we must defer to: an adapter base that picks up
      # `description`/`input_schema`/`output_schema` from an `Axn::MCP::*` module counts as external, so
      # axn won't re-extend and shadow it.
      #
      # That narrowness is load-bearing at both receivers this walk serves, and the trap it sets is for axn's own
      # maintainers: an instance name declared in an axn module OUTSIDE `Axn::Core` is external by this
      # predicate, exactly as a user's `ApplicationService` is. A plain action's ancestry holds five such modules
      # — `Axn::Async::BatchEnqueue`, `Axn::Async`, `Axn::Mountable` and the anonymous module
      # `Axn::Configuration.overrides` builds, all four ahead of the `Axn::Core` modules that declare the three
      # names below, plus `Axn` itself behind them. None of the five declares a deferrable name, or one of those
      # three, today.
      #
      # For one of the seventeen DEFERRABLE names, all five behave alike and the loss is total: `_collect` finds
      # the module as a foreign definer, so every action in every app records a deferral to it, hands the name
      # over, and warns its author at first run to declare `prefer_inherited :log` about a module they never
      # wrote.
      #
      # For `call`, `_run` or `initialize`, which side of `Axn::Core` the module sits on decides which way it
      # fails. Ahead of it (the first four), `core_definition_answers?` answers false for that name: the
      # unsurrenderable guard skips it and axn quietly defers to the hijacking module rather than raising, which
      # no spec catches, because nothing fails at the guard — only whatever the hijacked method was doing fails,
      # if anything. Behind it (`Axn`), the name is found as a foreign owner instead: every action that does not
      # define that name in its own body raises, and for `_run`/`initialize`, which no ordinary action defines,
      # every action raises full stop.
      #
      # A fixture with its own `def call` cannot show either of those, so verify by hand before adding any of
      # the three — or any name a `SURRENDERABLE_OWNERS` module already declares — to an axn module outside
      # `Axn::Core`. The name either belongs under `Axn::Core` or belongs in this predicate.
      def _axn_core_owned?(mod)
        name = Axn::Internal::NativeMethods.declared_module_name(mod)
        return false unless name

        name == "Axn::Core" || name.start_with?("Axn::Core::")
      end
      # `module_function` already made the instance copy private; this makes the module-level one match.
      private_class_method :_axn_core_owned?

      # The instance-side names axn will hand to a user's own hierarchy: the public helpers its surrenderable
      # modules own, minus the internals a leading underscore marks. Which modules and which underscores are
      # NameOwnership's answers rather than a second opinion, so the set of sugar axn is willing to lose cannot
      # drift from the set a declaration is allowed to take.
      #
      # PUBLIC only, which is where this set is narrower than `conflict_for`: that guard counts a private helper,
      # because a reader defined on the action shadows one as completely as a public one, but a private helper is
      # not a surface a user's superclass could be standing in for, so there is nothing here to defer to.
      #
      # Computed on first use, not at load: this file is required before the modules it asks about.
      #
      # Defined with an explicit `self.` receiver rather than inside the `module_function` block above, which
      # would also stamp a private instance copy onto every action and land the memo on the action instead of here.
      def self.deferrable_names
        @deferrable_names ||= Axn::Internal::NameOwnership::SURRENDERABLE_OWNERS.flat_map do |mod|
          Axn::Internal::NativeMethods.own_public_instance_methods(mod)
        end.reject { |name| Axn::Internal::NameOwnership.internal_name?(name) }.uniq.freeze
      end
    end
  end
end
