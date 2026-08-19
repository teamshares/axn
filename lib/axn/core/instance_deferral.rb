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
      SHIM_RECORD_IVAR = :@__axn_deferral_shim_record
      ACKNOWLEDGED_IVAR = :@__axn_acknowledged_deferrals
      ANNOUNCED_IVAR = :@__axn_deferrals_announced
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET

      NO_DEFERRALS = {}.freeze

      AXN_CHOSE_SUPERCLASS_IVAR = :@__axn_chose_superclass

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
      # Asked on EVERY call, and deliberately not memoized. The answer is about the class's HIERARCHY, and a
      # hierarchy stays mutable for as long as the process runs: a superclass reopened to add `#initialize` after
      # the action's first successful call is the shape a per-class memo answered wrongly, since the verdict it
      # froze was taken before the definition existed. That class went on reporting success while a fresh subclass
      # of the same superclass was refused — the silent shadowing this guard exists to prevent, restored by the
      # cache meant to make it cheap.
      #
      # Affordable because the answer is one pass over the declaration chain per name rather than a walk over
      # `ancestors` (see `MethodShadowing.core_shadowed_definer`). Measured end to end, against the same code
      # memoized: +4.3us and +7 objects per `.call` — 5% of a minimal fielded action's 93us, 10% of a do-nothing
      # action's 40us, and proportionally less for any action that does work. There is no cheaper honest option:
      # Ruby offers no hook for "an ancestor was reopened", so a cache here can only be a verdict nothing
      # invalidates.
      #
      # The ivar still consulted here is not a verdict: it records an authored fact about how the class was built,
      # which nothing later re-derives. Same for the announcement's (see `announce_deferrals!`), which records a
      # side effect already committed.
      def self.assert_dispatchable_names_free!(klass)
        return if KERNEL_IVAR_GET.bind_call(klass, AXN_CHOSE_SUPERCLASS_IVAR)

        Axn::Internal::NameOwnership::UNSURRENDERABLE.each do |name|
          owner = MethodShadowing.core_shadowed_definer(klass, name)
          next if owner.nil?

          raise Axn::ContractViolation::UnsurrenderableInheritedMethod.new(klass:, name:, owner:)
        end
      end

      # The exemption the guard above consults, set by the one caller that can honestly claim it: mounting,
      # where `inherit:` picks the superclass to carry the target's hooks, callbacks and async config.
      #
      # Both remedies the refusal offers are addressed to whoever wrote the `class X < Y` — move the behaviour
      # into X's own `#initialize`, or compose Y in rather than inheriting from it. On a mounted action nobody
      # wrote that line: axn generated the class and picked its superclass, so the first remedy would mean
      # reopening a class axn named, and the second names an edge that is not the author's to restructure. The
      # target's `#initialize` was never a candidate for constructing the mounted action either, so axn owning
      # the name is the intended outcome rather than a shadowing to report. A mount that passes its own
      # `superclass:` is NOT marked: there the author did choose the edge, and "compose it in instead" is an
      # answer they can act on.
      #
      # Per class rather than per name, because what it records is the inheritance EDGE, not which of the three
      # names travelled along it: the same absence of an authored decision covers `_run` and `call` too. (`call`
      # is moot in practice — a factory-built class defines its own, so the guard's first question already
      # answers no for that name — and leaving it to that accident would make the exemption depend on a detail
      # of how the mounted class is built.)
      #
      # A class-level ivar, which a subclass does not inherit: a `class Mine < SomeMountedAxn` is a class the
      # user wrote, and it is asked the question like any other.
      def self.axn_chose_superclass!(klass) = KERNEL_IVAR_SET.bind_call(klass, AXN_CHOSE_SUPERCLASS_IVAR, true)

      # What `include Axn` contributes: a wrapper for every name the class's own hierarchy already owned.
      def self.install(base)
        deferrals = _collect(base)
        return if deferrals.empty?

        record = _own_record(base)
        deferrals.each { |name, capture| _stand_in(record, name, *capture) }
        # Kept whole and never rewritten, because it is what `prefer_inherited` reaches for: a later declaration
        # may put axn's implementation back in front, and the capture is the only remaining record of the
        # implementation, and the visibility, the include surrendered to.
        record[:captured].update(deferrals)
        nil
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
        # The same record object, reachable from the shim as well as from the class, so a caller holding only
        # the module a lookup landed on can ask what it stands for without searching for it.
        KERNEL_IVAR_SET.bind_call(state[:shim], SHIM_RECORD_IVAR, state)
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
      #
      # The one ordering this leaves: a declaration must be in place before the class's FIRST run. Reopening a
      # class to add `prefer_inherited` after it has already executed announces nothing new, and silences
      # nothing either — the line for that name is already written.
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
            # The record says what `include Axn` stepped aside for; it does not say what a dispatch reaches now.
            # A `def` in the class's own body, or a module included after `include Axn`, outranks the shim — the
            # shape the docs call "not a conflict" — and announcing that one anyway would assert the opposite of
            # what runs and offer two remedies that change nothing.
            next unless Axn::Internal::Identity.same?(_live_definer(klass, name), definer)

            _warn_once(klass, name, definer)
          end
        end
      end

      # Keyed to the DEFINER's method rather than to the class that inherited it: one `ApplicationService#log`
      # under fifty actions is one line, not fifty. Keying it that way means both reading and writing the record
      # dispatch the definer's own `hash`/`eql?`, which is why both happen inside the guard below rather than in
      # front of it. A definer that lies about either gets warned about more than once, and one whose `hash`
      # raises gets no line at all — both the right way for a courtesy to degrade.
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

      # Two classes deferring the SAME definer method are two different first runs, so the per-class
      # `ANNOUNCED_IVAR` does not coordinate them: concurrently, both could find the record absent and both
      # emit the line the record exists to make singular. This makes the check-and-insert one step.
      WARNED_LOCK = Thread::Mutex.new
      private_constant :WARNED_LOCK

      # Announced rather than logged at debug: a deferral the author did not intend changes which code runs, and
      # a debug line is invisible to the developer who needs to know.
      def self._warn_once(base, name, definer)
        # Guarded like axn's other side-channel diagnostics, and for a reason particular to where this one is
        # emitted: the announcement runs at the execution funnel, before the action is constructed and outside
        # the executor's guards, so anything that raises here would take `.call` down over a courtesy.
        #
        # The WHOLE of the announcement is inside, key and lock included, because reaching the record at all
        # dispatches the definer's `hash` — a definer being an arbitrary class or module the user wrote. (An
        # empty Hash short-circuits `key?` without hashing, so the store is the read that always does.) The
        # lock is in for its own reason: `Thread::Mutex#synchronize` answers a recursive lock with a
        # ThreadError, which is a StandardError this guard swallows like any other side-channel escape.
        Axn::Extensions.best_effort("announcing an inherited-method deferral", action: base) do
          key = [definer, name]
          # Lock-free once the record is in: after the first announcement no thread reaching this name takes
          # the lock at all, so the mutex costs only the runs that might still be the first.
          next if WARNED.key?(key)

          claimed = WARNED_LOCK.synchronize { WARNED.key?(key) ? false : WARNED[key] = true }
          # Emitted outside the lock for two reasons. A logger that blocks — a socket, a full pipe, a lock of
          # its own — would hold this one for as long as it blocks, and every thread whose action is still
          # deciding whether to announce anything would queue behind an unrelated write. And a logger that
          # itself runs an axn action which defers arrives back here from underneath its own announcement:
          # Thread::Mutex is not reentrant, so relocking it on this thread raises ThreadError ("deadlock;
          # recursive locking"), and where the logger hands that inner run to another thread and waits for it,
          # the two block on each other with nothing to detect it.
          #
          # Which also keeps the ordering the record depends on: it is committed BEFORE the line is written,
          # so a logger that raises cannot leave the deferral unrecorded and let a later class announce it a
          # second time.
          next unless claimed

          # The definer is a class or module the user wrote, which axn never renames, so it is read bound. The
          # ACTION is the one axn may have named itself — a factory-built or mounted class carries a `name` axn
          # installed — and reading that one bound answers with an object address instead.
          owner = Axn::Internal::Rendering.module_name(definer)
          klass = Axn::Internal::Rendering.action_name(base)
          Axn.config.logger.warn(
            "[#{klass}] axn left ##{name} to #{owner}: it already defines the name, so calls reach #{owner}'s " \
            "version. Declare `prefer_inherited :#{name}` to confirm that, or `prefer_axn :#{name}` to use " \
            "axn's instead.",
          )
        end
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
      # Answered from the SHIM's own reference to the record, rather than by searching a class's ancestry for a
      # record whose shim matches, for two reasons. It is the shim that is being asked about, so nothing else
      # can answer more directly; and this is on the path of every field declaration, where the owner is
      # ordinarily `Kernel`, one of axn's modules or the user's own class — a search would scan to BasicObject
      # on each of those before reporting the miss it is going to report.
      #
      # Kept apart from `shim`/`definers` rather than folded into them, because those two are what a caller that
      # MUTATES a record must use: removing a wrapper from an ancestor's shim, or dropping a name from its map,
      # would take the helper away from that ancestor and from every other class beneath it. Own record to
      # change, the shim's own record to read — a class may own a record while the name asked about is answered
      # by an ancestor's, which is exactly the shape `prefer_axn` on a subclass produces.
      def self.definer_behind(owner, name)
        record = KERNEL_IVAR_GET.bind_call(owner, SHIM_RECORD_IVAR)
        record && record[:definers][name]
      end

      def self._state(klass) = KERNEL_IVAR_GET.bind_call(klass, DEFERRALS_IVAR)
      private_class_method :_state

      # Reached through `send` from `ClassMethods`, as `_prefer_axn!` below is, because both are axn's own
      # bookkeeping: made public here they would become class methods on every action, which is a surface the two
      # declarations deliberately do not have.
      def self._prefer_inherited!(klass, name)
        name = _assert_deferrable!(klass, name, :prefer_inherited)
        definer, impl, visibility = _captured_deferral(klass, name)
        raise Axn::ContractViolation::NothingToPrefer.new(klass:, name:) if definer.nil?

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

        definer_behind(owner, name) || owner
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
      # Anything else is refused, naming the owner `NameOwnership` reports — `call` and its siblings, an axn
      # internal, the ambient sentinel, Ruby's own. `conflict_for` reports no owner at all for two different
      # names, an unknown one and a private helper of axn's, so the message for that branch asserts only what
      # covers both: the name is not part of the surface axn hands to anyone.
      #
      # The name is canonicalized through the shared rule every name-taking declaration holds
      # (`Contract.canonical_name!`) rather than by a bare `to_sym`, and BEFORE the ownership question below,
      # so a value that is not a name at all never reaches it: `prefer_inherited nil` is DSL misuse in the
      # class body, and left to `to_sym` it is diagnosed as `NoMethodError: undefined method 'to_sym' for nil`,
      # which names neither the declaration nor what was wrong with the value.
      #
      # The same rule holds the name's ENCODING, which matters here for a reason of its own: a wide-encoded
      # `"log"` interns to a Symbol distinct from `:log`, so every question below is answered about a name the
      # author never wrote, and the refusal that follows reports `#log` as no part of axn's surface — a verdict
      # that is false of the name as written.
      def self._assert_deferrable!(klass, name, declaration)
        name = Contract.canonical_name!(
          name,
          option: "a name passed to `#{declaration}`",
          names: "one of the helpers axn defines and may hand over",
          fix: "Name the helper as a String or Symbol (e.g. `#{declaration} :log`).",
          encoding_fix: "Name it in UTF-8 (or any other ASCII-compatible encoding).",
        )
        return name if MethodShadowing.deferrable_names.include?(name)

        conflict = Axn::Internal::NameOwnership.conflict_for(klass, name)
        belongs_to = Axn::Internal::NameOwnership.describe(conflict, name:) unless conflict.nil?

        raise Axn::ContractViolation::UnpreferableName.new(declaration:, name:, belongs_to:)
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
