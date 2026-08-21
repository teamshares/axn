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
        singleton = KERNEL_SINGLETON_CLASS.bind_call(base)
        # A name the singleton cannot REACH has no definer to defer to, whatever an own-table walk finds further
        # out: `undef_method` writes an entry no own-table read reports while a lookup arriving from below stops
        # dead on it, so without this the walk answers with a definition `base.description` would never call and
        # axn declines to install its own over a method that is not there. Read live because it is read before
        # axn extends this name — the callers all check first and extend second — so the singleton still answers
        # for the class's own chain alone.
        return false unless Axn::Internal::NativeMethods.instance_method_reachable?(singleton, name)

        !_external_definer(Axn::Internal::NativeMethods.module_ancestors(singleton), name).nil?
      end

      # The instance-side counterpart, and the module that stands in the way rather than a boolean, because the
      # caller both defers to it and names it in an error. Two things it does not count as the user's own, and
      # both are decided below: `base`'s own side (`_own_side`) and Ruby's own (`::Object` and outward).
      #
      # And it is read off the DECLARATION CHAIN rather than by walking `ancestors` comparing own method tables:
      # `declared_instance_method(base, name)`, then each declaration behind it in turn
      # (`shadowed_instance_method`), which is Ruby's own resolver answering in dispatch order. That is what makes
      # every input to this answer readable at the moment it is asked, with nothing recorded and nothing memoized
      # — see `_declaration_chain`.
      def inherited_definer(base, name)
        own_side = nil
        _declaration_chain(base, name) do |owner|
          next if _axn_core_owned?(owner)

          # Read lazily, and shared across the rest of the chain: on the ordinary action, whose hierarchy declares
          # none of the eighteen deferrable names, the chain ends at axn's own declaration and neither ancestry
          # read below is paid at all — eighteen times per `include Axn` being what this one answers for.
          own_side ||= _own_side(base)
          next if _same_module?(own_side, owner)
          # Ruby's own, not the user's hierarchy: `Kernel` owns `warn`, `inspect`, `hash`, `then` and `tap`, and
          # deferring to those would silently redirect every `warn("msg")` inside an action to stderr instead of
          # the logger.
          return nil if Axn::Internal::NativeMethods.includes_module?(::Object, owner)

          return owner
        end
      end

      # Every declaration of `name` the chain holds, nearest first, starting from the one a dispatch on `base`
      # would reach. Ends at the last one, or at an `undef_method` entry — Ruby stops a `super` there, and so
      # does this.
      #
      # That stop is why nothing about a barrier has to be recorded ahead of `include Axn` any more. An undef
      # entry is invisible to every own-table read, and effective lookup reports it only for the chain AS A
      # WHOLE — so once axn's own modules declare the name in front of the user's chain, `base` answers "yes,
      # reachable" whether or not the user's own ancestors could reach it, which is what a record taken before
      # the include was standing in for. Stepping the chain asks the same question from a position BEHIND axn's
      # modules: the walk arrives at the barrier itself and ends there, wherever it is hosted — an ancestor
      # class, a module included into one, a module included into `base` itself, or `base`'s own table — and
      # whenever it was written, before the include or after it.
      #
      # It is also why no per-name state is cached anywhere in this area: every input to `inherited_definer` is
      # readable at the moment the question is asked, so a hierarchy reopened after `include Axn` — to add a
      # `#call`, to add a barrier, to take one away — is answered on the chain as it stands, not as it stood.
      # The one exception left is deliberate and elsewhere: the deferral shim captures the implementation it
      # stands in for at include time (see `InstanceDeferral._collect`), so a definer reopened afterwards does
      # not retarget a wrapper the class already committed to.
      def _declaration_chain(base, name)
        method = Axn::Internal::NativeMethods.declared_instance_method(base, name)
        until method.nil?
          yield method.owner
          method = Axn::Internal::NativeMethods.shadowed_instance_method(method)
        end
        nil
      end
      private_class_method :_declaration_chain

      # `base` itself, and anything PREPENDED to it — the declarations the chain starts among and this walk owes
      # nothing to. A `def log` in the class body is the user's own method and wins on its own terms, with
      # `super` reaching axn's; treating it as a deferral target would point the deferral at the very method it
      # defers. A prepend to `base` already outranks whatever axn installs, so it is in the same position.
      #
      # Everything else in the chain is fair game, INCLUDING a module `base` includes for itself: that one sits
      # behind axn's modules, so axn's helper is what answers and the module is exactly what axn has to step
      # aside for.
      def _own_side(base)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(base)
        ancestry.take_while { |mod| !Axn::Internal::Identity.same?(mod, base) } << base
      end
      private_class_method :_own_side

      def _same_module?(candidates, mod)
        candidates.any? { |candidate| Axn::Internal::Identity.same?(candidate, mod) }
      end
      private_class_method :_same_module?

      # What AXN's OWN definition of `name` is standing in front of on `base`, or nil when it is standing in front
      # of nothing — or when it is not what answers at all. The question `assert_dispatchable_names_free!` asks of
      # every action on every call, for a name axn cannot hand over.
      #
      # It is two questions, because either answer alone permits the wrong verdict: axn's definition must be the
      # one that ANSWERS (a `def call` of the author's own takes the name over on its own terms, whether it appears
      # in the class body, in a module included after `include Axn`, or in a prepend — and reaches axn's with
      # `super`), and there must be a declaration behind it for it to be shadowing. Both are questions about ONE
      # chain, so they are asked in one pass over it rather than resolving it twice per name per call.
      #
      # The first declaration in the chain is the one a dispatch reaches, which settles the first question. That
      # it is axn's own then settles something for the second: `base` and its prepends declare nothing here, since
      # either would have come first — so unlike `inherited_definer`, this needs no reading of `base`'s ancestry
      # to tell its own side from the hierarchy above it.
      def core_shadowed_definer(base, name)
        answering = true
        _declaration_chain(base, name) do |owner|
          core = _axn_core_owned?(owner)
          if answering
            answering = false
            return nil unless core

            next
          end
          next if core
          return nil if Axn::Internal::NativeMethods.includes_module?(::Object, owner)

          return owner
        end
      end

      # The first module in `ancestry` that declares `name` in its OWN table, skipping axn core's. Own table
      # rather than effective lookup: the question is who would be shadowed, and a prepend elsewhere in the
      # chain does not make a declaration disappear.
      #
      # Reachability is not this walk's question: its one caller, `externally_defined?`, settles it up front
      # against the singleton, so what arrives here is a chain a dispatch can traverse and the first own-table
      # declaration in it is the one that dispatch arrives at.
      def _external_definer(ancestry, name)
        ancestry.find do |mod|
          !_axn_core_owned?(mod) && Axn::Internal::NativeMethods.declares_own_instance_method?(mod, name)
        end
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
      # For one of the eighteen DEFERRABLE names, all five behave alike and the loss is total: `_collect` finds
      # the module as a foreign definer, so every action in every app records a deferral to it, hands the name
      # over, and warns its author at first run to declare `prefer_inherited :log` about a module they never
      # wrote.
      #
      # For `call`, `_run` or `initialize`, which side of `Axn::Core` the module sits on decides which way it
      # fails. Ahead of it (the first four), it is the first declaration in the chain and not axn's own, so
      # `core_shadowed_definer` answers nil: the unsurrenderable guard passes and axn quietly defers to the
      # hijacking module rather than raising, which no spec catches, because nothing fails at the guard — only
      # whatever the hijacked method was doing fails, if anything. Behind it (`Axn`), the name is found as a
      # foreign owner instead: every action that does not define that name in its own body raises, and for
      # `_run`/`initialize`, which no ordinary action defines, every action raises full stop.
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

      # The instance-side names axn will hand to a user's own hierarchy: the public helpers its
      # deferral-source modules own, minus the internals a leading underscore marks. Which modules and
      # which underscores are NameOwnership's answers rather than a second opinion, so the set of sugar
      # axn is willing to lose cannot drift from the set a declaration is allowed to take.
      #
      # `DEFERRAL_SOURCES` rather than `SURRENDERABLE_OWNERS`: the two are almost the same list, but not
      # quite — `Axn::Core::AmbientContext` is excluded from the latter (a field declaration may never
      # take `ambient_context`, see that constant's comment) while included in the former (an inherited
      # `ambient_context` may still be silently deferred to, exactly like any other sugar name, since
      # internals reach the ambient reader by binding it rather than dispatching on the action).
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
        @deferrable_names ||= Axn::Internal::NameOwnership::DEFERRAL_SOURCES.flat_map do |mod|
          Axn::Internal::NativeMethods.own_public_instance_methods(mod)
        end.reject { |name| Axn::Internal::NameOwnership.internal_name?(name) }.uniq.freeze
      end
    end
  end
end
