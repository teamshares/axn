# frozen_string_literal: true

module Axn
  module Core
    # `include Axn` puts axn's user-facing helpers in modules included into the user's class, and Ruby places
    # those above the superclass — so an `ApplicationService#log` would lose to axn's with nothing said. Where
    # the user's own hierarchy already owns one of the surrenderable names, axn steps aside instead.
    #
    # Stepping aside cannot be a non-definition: the sugar modules are shared by every action class, so there is
    # no per-class version of them to leave a name out of. It is instead one anonymous module per class, included
    # last so it outranks axn's, holding a wrapper that `bind_call`s the chosen implementation's own
    # UnboundMethod, and a record of whose implementation each wrapper calls. A class with no collision and no
    # declaration gets no module and no extra frame.
    #
    # The wrappers are how `prefer_inherited`/`prefer_axn` work too, and why they can: a declaration puts one
    # into the DECLARING class's own module, so a subclass may choose differently from the base class it
    # inherited the deferral from without changing the answer for that base class or for its other subclasses.
    #
    # The names axn CANNOT step aside for live here too (`assert_dispatchable_names_free!`), so which names axn
    # yields and which it refuses outright are one subject in one place rather than two.
    module InstanceDeferral
      DEFERRALS_IVAR = :@__axn_instance_deferrals
      ACKNOWLEDGED_IVAR = :@__axn_acknowledged_deferrals
      ANNOUNCED_IVAR = :@__axn_deferrals_announced
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      NO_DEFERRALS = {}.freeze

      CHECKED_IVAR = :@__axn_dispatchable_names_checked

      # The two declarations an author writes in the class body to say which implementation is live for a name
      # both axn and their own hierarchy define. Neither widens what axn permits — a `def` in the class body
      # already surrenders any of these names — but they put the decision where the reader of the class body
      # will look for it, and `prefer_axn` is the only route back to axn's implementation once a parent owns
      # the name: `super` from the class body reaches the wrapper standing in for the inherited method, not
      # past it.
      #
      # Each raises when the outcome it names cannot be delivered, which is one rule rather than two.
      # `prefer_inherited` raises when nothing axn stepped aside for is there to prefer; `prefer_axn` cannot
      # fail that way, because axn's own implementation is always in the ancestry, so on a class that never
      # deferred it is an assertion that already holds and stays silent.
      module ClassMethods
        def prefer_inherited(*names)
          names.each { |name| InstanceDeferral.send(:_prefer_inherited!, self, name) }
        end

        def prefer_axn(*names)
          names.each { |name| InstanceDeferral.send(:_prefer_axn!, self, name) }
        end
      end

      # `Axn::Internal::NameOwnership::UNSURRENDERABLE` names what is dispatched on the action BY NAME from
      # outside the module that defines it, so axn cannot step aside for an inherited version the way it does
      # for the helpers — and taking one silently is worse than refusing it: an action whose inherited `call` is
      # shadowed reports success for code that never ran.
      #
      # Asked at execution rather than at include time because only the finished class answers it. A class may
      # legitimately define one of these itself AFTER `include Axn` — `Axn::Factory` builds exactly that shape —
      # and its own definition outranks both the inherited one and axn's, so an include-time check would refuse a
      # legal build. `Core::ClassMethods#call` is the only funnel there is; nothing reaches `_run` around it.
      #
      # Two questions, because either answer alone permits the wrong verdict: axn must be the definition that
      # ANSWERS (a `def call` of the author's own takes the name over on its own terms, whether it appears in the
      # class body or in a module included after `include Axn`), and there must be an inherited declaration for it
      # to be standing in front of.
      #
      # The memo is a class-level ivar, which a subclass does not inherit, so a subclass re-checks itself. That
      # is what it needs: it may have introduced a definition of its own, or a new superclass in between.
      def self.assert_dispatchable_names_free!(klass)
        return if KERNEL_IVAR_GET.bind_call(klass, CHECKED_IVAR)

        Axn::Internal::NameOwnership::UNSURRENDERABLE.each do |name|
          next unless MethodShadowing.core_definition_answers?(klass, name)

          owner = MethodShadowing.inherited_definer(klass, name)
          next if owner.nil?

          raise Axn::ContractViolation::UnsurrenderableInheritedMethod.new(klass:, name:, owner:)
        end

        KERNEL_IVAR_SET.bind_call(klass, CHECKED_IVAR, true)
      end

      # What `include Axn` contributes: a wrapper for every name the class's own hierarchy already owned.
      def self.install(base)
        deferrals = _collect(base)
        return NO_DEFERRALS if deferrals.empty?

        record = _own_record(base)
        deferrals.each { |name, capture| _stand_in(record, name, *capture) }
        # Kept whole and never rewritten, because it is what `prefer_inherited` reaches for: a later declaration
        # may put axn's implementation back in front, and the capture is the only remaining record of the
        # implementation, and the visibility, the include surrendered to.
        record[:captured].update(deferrals)
        record[:definers]
      end

      # One record, and one module of wrappers, per class: `include Axn` opens it and a declaration in the class
      # body adds to it. The module is included LAST both times, so it outranks axn's own helpers and any shim an
      # ancestor installed — which is what lets a subclass state a preference without editing a record that
      # belongs to its parent, and so to the parent's other subclasses.
      #
      # Held in an ivar rather than in a class method, for the same reason the rest of this area is bound rather
      # than dispatched: whatever axn reads back has to be axn's own, on a class whose method table the user
      # owns. An ivar carries no dispatchable name.
      def self._own_record(klass)
        state = _state(klass)
        return state unless state.nil?

        state = { shim: ::Module.new, definers: {}, captured: {} }
        KERNEL_IVAR_SET.bind_call(klass, DEFERRALS_IVAR, state)
        Axn::Internal::NativeMethods.include_module(klass, state[:shim])
        state
      end
      private_class_method :_own_record

      # A wrapper that `bind_call`s the chosen implementation, plus the record entry naming whose it is. The two
      # move together deliberately: the record is what every question about the shim is answered from, so a
      # wrapper installed without one would leave the shim answering under a name nothing can attribute.
      def self._stand_in(record, name, definer, impl, visibility)
        Axn::Internal::NativeMethods.define_own_instance_method(record[:shim], name) do |*args, **kwargs, &blk|
          impl.bind_call(self, *args, **kwargs, &blk)
        end
        # `define_method` defines public, so without this a definer's `private def log` would come back out of
        # the deferral as part of the action's public surface — the opposite of stepping aside.
        Axn::Internal::NativeMethods.set_declared_visibility(record[:shim], name, visibility)
        record[:definers][name] = definer
      end
      private_class_method :_stand_in

      # Announced at the execution funnel rather than from `install`, for the same reason the unsurrenderable
      # guard above is asked there: only the FINISHED class answers the question. `prefer_inherited` and
      # `prefer_axn` are written in the class body, which runs after `include Axn`, so a warning written during
      # the include is one no declaration can ever answer — it would name two remedies and then ignore both.
      #
      # Asked of the class being RUN, so the deferral a base class recorded is announced against the subclass
      # that actually uses it, and a preference declared on that subclass is taken into account.
      #
      # Nearest record first, and each name settled by the first record that answers it, because that is the
      # order a dispatch resolves in: a subclass that put axn's implementation back in front of an inherited
      # one has nothing left to be warned about.
      def self.announce_deferrals!(klass)
        return if KERNEL_IVAR_GET.bind_call(klass, ANNOUNCED_IVAR)

        KERNEL_IVAR_SET.bind_call(klass, ANNOUNCED_IVAR, true)
        acknowledged = []
        settled = {}
        Axn::Internal::NativeMethods.module_ancestors(klass).each do |mod|
          acknowledged.concat(KERNEL_IVAR_GET.bind_call(mod, ACKNOWLEDGED_IVAR) || [])
          state = _state(mod)
          next if state.nil?

          state[:definers].each do |name, definer|
            next if settled.key?(name)

            settled[name] = true
            next if acknowledged.include?(name)
            # A record entry naming one of axn's own modules is a `prefer_axn`: axn's helper is what answers, so
            # there is no deferral left to announce.
            next if Axn::Internal::NameOwnership.surrenderable?(definer)

            _warn_once(klass, name, definer)
          end
        end
      end

      # Keyed to the DEFINER's method rather than to the class that inherited it: one `ApplicationService#log`
      # under fifty actions is one line, not fifty. A definer that lies about `hash`/`eql?` gets warned
      # about more than once, which is the right way for a courtesy to degrade.
      #
      # Never cleared by any public reset. This is the record of a side effect already committed — the process
      # has announced the deferral — so a configuration reset in a test suite must not make it announce it again.
      #
      # A class-reloading host is where the "one line per definer" premise thins out: each generation of
      # `ApplicationService` is a distinct class object, so a reload re-announces and leaves the previous
      # generation held here. Both follow from the definer genuinely having been redefined, but a long dev
      # session accumulates one entry (and one line) per reload per name.
      WARNED = {} # rubocop:disable Style/MutableConstant (grown as actions run; a frozen one could record nothing)
      private_constant :WARNED

      # Announced rather than logged at debug: a deferral the author did not intend changes which code runs, and
      # a debug line is invisible to the developer who needs to know.
      def self._warn_once(base, name, definer)
        key = [definer, name]
        return if WARNED.key?(key)

        WARNED[key] = true
        owner = Axn::Internal::Rendering.module_name(definer)
        klass = Axn::Internal::Rendering.module_name(base)
        Axn.config.logger.warn(
          "[#{klass}] axn left ##{name} to #{owner}: it already defines the name, so calls reach #{owner}'s " \
          "version. Declare `prefer_inherited :#{name}` to confirm that, or `prefer_axn :#{name}` to use " \
          "axn's instead.",
        )
      end
      private_class_method :_warn_once

      # Specs assert the once-per-definer property, which needs the record cleared between examples. Deliberately
      # not part of any public reset: see WARNED.
      def self._reset_warned_for_specs! = WARNED.clear
      private_class_method :_reset_warned_for_specs!

      # Whose implementation this class's OWN shim calls, per name: the module axn stepped aside for, or one of
      # axn's own where `prefer_axn` put its helper back in front. The recorded answer rather than a fresh walk:
      # once the shim is installed it is itself the nearest declaration of the name, so a re-walk would report
      # the shim.
      def self.definers(klass) = _state(klass)&.fetch(:definers) || NO_DEFERRALS

      def self.shim(klass) = _state(klass)&.fetch(:shim)

      # Whose implementation a shim's wrapper calls for `name`, or nil when `owner` is not one of axn's shims at
      # all — the honest answer for a caller that only ASKS who a name belongs to and has landed on axn's
      # bookkeeping instead of on a module anyone wrote.
      #
      # Found by matching the SHIM rather than by taking the nearest record, because a class may own a record
      # while the name in question is answered by an ancestor's: a subclass that declares `prefer_axn :fail!`
      # owns a shim holding that one wrapper, and every other helper it inherits still resolves through the shim
      # its base class installed.
      #
      # Kept apart from `shim`/`definers` rather than folded into them, because those two are what a caller that
      # MUTATES a record must use: removing a wrapper from an ancestor's shim, or dropping a name from its map,
      # would take the helper away from that ancestor and from every other class beneath it. Own record to
      # change, the whole ancestry to read.
      def self.definer_behind(klass, owner, name)
        Axn::Internal::NativeMethods.module_ancestors(klass).each do |mod|
          state = _state(mod)
          next if state.nil? || !Axn::Internal::Identity.same?(state[:shim], owner)

          return state[:definers][name]
        end
        nil
      end

      def self._state(klass) = KERNEL_IVAR_GET.bind_call(klass, DEFERRALS_IVAR)
      private_class_method :_state

      # Reached through `send` from `ClassMethods`, as `_prefer_axn!` below is, because both are axn's own
      # bookkeeping: made public here they would become class methods on every action, which is a surface the two
      # declarations deliberately do not have.
      def self._prefer_inherited!(klass, name)
        name = _assert_deferrable!(klass, name, :prefer_inherited)
        definer, impl, visibility = _captured_deferral(klass, name)
        if definer.nil?
          raise Axn::ContractViolation,
                "`prefer_inherited :#{Axn::Internal::RenderedText.of(name)}` has nothing to prefer: axn " \
                "surrendered no ##{Axn::Internal::RenderedText.of(name)} on this class, because nothing above " \
                "it declared the name when `include Axn` ran. Remove the declaration, or check the name — a " \
                "definition made after the include, in this class's own body or in a module included later, " \
                "already wins on its own terms."
        end

        _acknowledge(klass, name)
        _prefer!(klass, name, definer, impl, visibility)
      end
      private_class_method :_prefer_inherited!

      def self._prefer_axn!(klass, name)
        name = _assert_deferrable!(klass, name, :prefer_axn)
        # Never nil: `_assert_deferrable!` has established that one of the surrenderable modules declares the
        # name publicly, and `include Axn` puts every one of them in the class's ancestry.
        definer = _axn_definer(klass, name)
        _prefer!(klass, name, definer,
                 Axn::Internal::NativeMethods.declared_instance_method(definer, name),
                 Axn::Internal::NativeMethods.declared_visibility(definer, name))
      end
      private_class_method :_prefer_axn!

      # A no-op when the implementation the declaration asks for is the one a dispatch already reaches, so a
      # class that states what is already true gains no module and no extra frame. Otherwise the wrapper goes
      # into the DECLARING class's own record, which is what keeps the declaration local: an ancestor's shim,
      # edited, would change the answer for the ancestor and every other class beneath it.
      def self._prefer!(klass, name, definer, impl, visibility)
        return if Axn::Internal::Identity.same?(_live_definer(klass, name), definer)

        _stand_in(_own_record(klass), name, definer, impl, visibility)
      end
      private_class_method :_prefer!

      # Whose implementation a dispatch on `klass` reaches for `name` today, with axn's bookkeeping resolved to
      # the module it stands in for — the same answer `NameOwnership` reports, and the one a declaration
      # compares its own target against.
      def self._live_definer(klass, name)
        owner = Axn::Internal::NativeMethods.declared_instance_method(klass, name)&.owner
        return nil if owner.nil?

        definer_behind(klass, owner, name) || owner
      end
      private_class_method :_live_definer

      # What `include Axn` surrendered under this name, from the nearest record in the ancestry that holds it.
      # The recorded capture rather than a fresh walk for the reason the record exists: once the shim is
      # installed it is itself the nearest declarer of the name, so a walk would answer with the shim.
      def self._captured_deferral(klass, name)
        Axn::Internal::NativeMethods.module_ancestors(klass).each do |mod|
          state = _state(mod)
          next if state.nil?

          capture = state[:captured][name]
          return capture unless capture.nil?
        end
        nil
      end
      private_class_method :_captured_deferral

      # Which of axn's own modules would answer the name if nothing stood in front of it. Read off the class's
      # ancestry rather than off the list of surrenderable owners, so that where two of axn's modules declared
      # one name the answer would be the one Ruby itself would resolve to.
      def self._axn_definer(klass, name)
        Axn::Internal::NativeMethods.module_ancestors(klass).find do |mod|
          Axn::Internal::NameOwnership.surrenderable?(mod) &&
            Axn::Internal::NativeMethods.declares_own_instance_method?(mod, name)
        end
      end
      private_class_method :_axn_definer

      # Per name and per class, so acknowledging one deferral says nothing about the others, and a sibling that
      # said nothing still hears about its own.
      def self._acknowledge(klass, name)
        acknowledged = KERNEL_IVAR_GET.bind_call(klass, ACKNOWLEDGED_IVAR)
        if acknowledged.nil?
          acknowledged = []
          KERNEL_IVAR_SET.bind_call(klass, ACKNOWLEDGED_IVAR, acknowledged)
        end
        acknowledged << name unless acknowledged.include?(name)
      end
      private_class_method :_acknowledge

      # The same question a declaration asks, so the two cannot drift: a name axn defines and may hand over.
      # Anything else is refused with the message `NameOwnership` already writes for it — `call` and its
      # siblings, an axn internal, the ambient sentinel, Ruby's own — and a name no owner at all reports is
      # refused on the one fact that covers both an unknown name and a private helper of axn's: it is not part
      # of the surface axn hands to anyone.
      def self._assert_deferrable!(klass, name, declaration)
        name = name.to_sym
        return name if MethodShadowing.deferrable_names.include?(name)

        label = Axn::Internal::RenderedText.of(name)
        conflict = Axn::Internal::NameOwnership.conflict_for(klass, name)
        belongs = if conflict.nil?
                    "is not part of axn's public instance surface, so axn has no implementation of it to prefer"
                  else
                    "belongs to #{Axn::Internal::NameOwnership.describe(conflict, name:)}"
                  end

        raise Axn::ContractViolation,
              "`#{declaration} :#{label}` names something axn cannot choose for you: ##{label} #{belongs}. " \
              "Remove the declaration, or check the name."
      end
      private_class_method :_assert_deferrable!

      # Captured — implementation and visibility both — at include time, which cuts two ways and deliberately
      # so. A definer reopened afterwards cannot silently retarget a deferral the class already committed to;
      # by the same token, a body redefined on that definer, or a module `prepend`ed to it, AFTER the action
      # class was defined is not picked up, because the wrapper keeps calling the implementation that was there
      # at include time where a plain dispatch would reach the new one. A Zeitwerk reload re-creates the action
      # class and so re-captures, which covers the common Rails path; a post-boot monkeypatch or an
      # instrumentation `prepend` does not.
      def self._collect(base)
        MethodShadowing.deferrable_names.each_with_object({}) do |name, acc|
          definer = MethodShadowing.inherited_definer(base, name)
          next if definer.nil?

          impl = Axn::Internal::NativeMethods.declared_instance_method(definer, name)
          next if impl.nil?

          acc[name] = [definer, impl, Axn::Internal::NativeMethods.declared_visibility(definer, name)]
        end
      end
      private_class_method :_collect
    end
  end
end
