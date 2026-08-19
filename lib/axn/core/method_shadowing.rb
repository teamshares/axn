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
      # Bound for the same reason, and carrying axn's own bookkeeping on a class whose method table the user
      # owns: an ivar has no dispatchable name for that class to answer under.
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_SINGLETON_CLASS, :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      BARRIERED_IVAR = :@__axn_barriered_names
      private_constant :BARRIERED_IVAR

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
      #
      # And a declaration an `undef_method` took away is not a definer either, whatever the own-table walk finds
      # — see `capture_barriered_names!` and `_reachable_slice`.
      def inherited_definer(base, name)
        return nil if _barriered?(base, name)

        _external_definer(_reachable_slice(_walked_ancestry(base), name), name)
      end

      # The prefix of the walked slice a dispatch arriving from below can actually traverse for `name`.
      #
      # This and the barrier record below answer on DIFFERENT axes, and neither subsumes the other:
      #
      # WHEN. The record is taken once, ahead of every include, so it answers for barriers that were in place
      # when `include Axn` ran and says nothing about one added afterwards. A CLASS ancestor's own lookup is
      # never masked by the modules axn includes into the action class beneath it — measured: post-include,
      # `instance_method_reachable?(parent, :call)` still answers for the parent's own chain alone — so this one
      # can be read live, at any time, and sees a barrier an ancestor was reopened to add.
      #
      # WHERE. This one reads only CLASS ancestors, because on a Class a nil lookup is unambiguous: a class's
      # lookup covers the whole remainder of this walk, so nothing left to visit can be reachable. On a MODULE
      # nil says only that the module itself declares nothing, which every module the walk passes through on
      # its way to the answer also says. The record, asked of the chain as a whole, has no such restriction and
      # is the only reader that sees a barrier hosted in a module included into `base` ITSELF.
      #
      # What neither covers, therefore: a MODULE reopened to `undef_method` AFTER the include, with no Class
      # ancestor beneath it in this slice — one included into `base` itself, or into another module. The record
      # was taken before the undef existed, and a module cannot be read live. Reopened after the include but
      # included into an ancestor CLASS, the undef takes the name from that class too, and this read catches it.
      #
      # At the unsurrenderable guard the surviving case is narrower again: that module must have been behind
      # axn's own modules already, because anything included into `base` after `include Axn` — or an undef in
      # its own body — sits AHEAD of them, and `core_definition_answers?` then answers no without ever asking
      # this walk. Measured on both halves.
      #
      # Checked before the own-table read rather than after, so a class whose own declaration a PREPENDED module
      # undefs ends the walk too: a dispatch from below reaches neither.
      def _reachable_slice(ancestry, name)
        ancestry.take_while do |mod|
          !Axn::Internal::Identity.kind?(mod, ::Class) ||
            Axn::Internal::NativeMethods.instance_method_reachable?(mod, name)
        end
      end
      private_class_method :_reachable_slice

      def _walked_ancestry(base)
        ancestry = Axn::Internal::NativeMethods.module_ancestors(base)
        above_base = ancestry.drop_while { |mod| !Axn::Internal::Identity.same?(mod, base) }.drop(1)
        above_base.take_while { |mod| !Axn::Internal::Identity.same?(mod, ::Object) }
      end
      private_class_method :_walked_ancestry

      # Which of the names this area asks about the class's own chain DECLARES but cannot reach — recorded once,
      # from `Axn.included`, before the includes below it put anything of axn's in front of that chain.
      #
      # `undef_method` writes an entry that no own-table read reports and that stops a lookup arriving from
      # below, so effective lookup is the only reader that sees a barrier, and it sees one wherever the barrier
      # is hosted — in a class or in a module, at any depth. That reader stops working the moment axn installs
      # its helpers: `declared_instance_method(action, :log)` then answers `Axn::Core::Logging::InstanceMethods`
      # whether or not the class's own chain could reach `log` at all. Hence a record rather than a live read,
      # and hence its position ahead of every include.
      #
      # A barrier hosted in a module included into `base` ITSELF is why this cannot be folded into the walk.
      # `base` is excluded there as a definer — a `def log` in the class body is the user's own method, not
      # something to defer to — and that exclusion drops everything the class includes for itself along with it,
      # so the walk never visits the module carrying the barrier.
      #
      # And it is why `_reachable_slice` cannot replace this either, nor this it: that one reads live and so
      # sees a barrier added after the include, but only where a CLASS hosts the consequence. The two cover
      # different axes — WHEN and WHERE — and dropping either reopens a measured hole (see `_reachable_slice`).
      #
      # DECLARES and cannot reach, rather than simply cannot reach: an unreachable name that nothing in the
      # walked slice declares has no definer for the walk to find anyway, so recording it would buy nothing —
      # and it would cost the one case where the two answers differ. A superclass reopened to add `#call` AFTER
      # the subclass included Axn declares the name where the record cannot see it, and there the live walk is
      # the honest reader: the unsurrenderable refusal still fires rather than letting axn silently answer for
      # an inherited `#call` the author put there.
      #
      # Twenty names against a slice that holds only the user's own ancestors, once per `include Axn`: measured
      # at ~5us and ~40 objects, against ~1100us and ~2100 objects for the include as a whole.
      def capture_barriered_names!(base)
        slice = _walked_ancestry(base)
        barriered = _shadowable_names.select do |name|
          !Axn::Internal::NativeMethods.instance_method_reachable?(base, name) &&
            !_external_definer(slice, name).nil?
        end
        KERNEL_IVAR_SET.bind_call(base, BARRIERED_IVAR, barriered.freeze)
        nil
      end

      # Read from the NEAREST record in the ancestry, because the two callers ask at different times about
      # different classes: the deferral collection asks about the class that just included Axn, and the
      # unsurrenderable-name refusal asks about the class being RUN, which may be a subclass that never ran
      # `include Axn` of its own (`Axn.included` returns early for one) and inherits the chain the record was
      # taken against.
      #
      # No record anywhere means no `include Axn` anywhere, and a class axn has installed nothing into still
      # reads live what the record would have held — which is what lets this be asked of an arbitrary class, as
      # the mounting layer asks it of a target. Unreachability alone is the whole test there: where nothing in
      # the slice declares the name, the walk that follows answers nil on its own.
      def _barriered?(base, name)
        recorded = _barriered_names(base)
        return recorded.include?(name) unless recorded.nil?

        !Axn::Internal::NativeMethods.instance_method_reachable?(base, name)
      end
      private_class_method :_barriered?

      def _barriered_names(base)
        own = KERNEL_IVAR_GET.bind_call(base, BARRIERED_IVAR)
        return own unless own.nil?

        Axn::Internal::NativeMethods.module_ancestors(base).each do |mod|
          recorded = KERNEL_IVAR_GET.bind_call(mod, BARRIERED_IVAR)
          return recorded unless recorded.nil?
        end
        nil
      end
      private_class_method :_barriered_names

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
      # Reachability is not this walk's question: `externally_defined?` settles it up front against the
      # singleton, and `inherited_definer` truncates the slice it hands over (`_reachable_slice`), so what
      # arrives here is a chain a dispatch can traverse and the first own-table declaration in it is the one
      # that dispatch arrives at.
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

      # The names the instance-side questions are asked about: what axn will hand over, plus what it refuses to
      # hand over. One set rather than two because one record answers both callers, and a name missing from it
      # would silently fall back to the masked live read at whichever caller needed it.
      #
      # Same `self.` and same reason as above.
      def self._shadowable_names
        @_shadowable_names ||= (deferrable_names | Axn::Internal::NameOwnership::UNSURRENDERABLE.to_a).freeze
      end
      private_class_method :_shadowable_names
    end
  end
end
