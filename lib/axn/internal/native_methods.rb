# frozen_string_literal: true

# Membership in an ancestry is decided by identity (`includes_module?`), so a process that loaded this file
# alone must have the comparison: `Identity` requires only `Internal::Text`, the gem's zero-require layer, so
# naming it here adds no cycle.
require "axn/internal/identity"

module Axn
  module Internal
    # Which of a caller's object's answers are RUBY'S OWN — read from the method table, without running a line
    # the object's class wrote.
    #
    # Three layers need this, for one reason. Cooperating with a caller's object means running its code: storing a
    # declared `inclusion:` container copies it, renaming a contract failure runs the exception's `#exception`, and
    # deciding what JSON property a declared name means renders it. Verifying that the code BEHAVED produced a new
    # counterexample every round, because the body is arbitrary — a duplication hook that drops only a derived
    # lookup index leaves every element it holds answering `include?` correctly and the aliases it no longer
    # indexes answering wrongly, an `#exception` that succeeds on its first call and raises on its second is not
    # excluded by the object having been raised once, and a `to_s` agreeing with a name's bytes when the rules ask
    # says nothing about what it answers the encoder. No behavioural probe terminates against an arbitrary body,
    # so each fix was defeated by the next case.
    #
    # OWNERSHIP terminates. It is a fact about the method table rather than a prediction about behaviour: where
    # Ruby's own implementation is what answers, the operation is bounded; where it is not, axn does not perform
    # the operation at all and takes an honest fallback instead (see `Internal::ShapeGraph.detached_option_array` and
    # `Axn::Tools._named_invalid_contract`). This deliberately over-rejects — a faithful `include?` is
    # indistinguishable from a lying one without running it — and bounded-and-slightly-strict is the trade every
    # unbounded verification here lost.
    #
    # But ownership of WHICH methods, and looked up WHERE, is where a bounded rule can still be wrong, and both
    # halves were. A copy is faithful only when the state `dup` copies faithfully determines every answer, so
    # owning the duplication hooks was too narrow: `dup` shares the instance variables and drops the singleton
    # class, and a container answering membership from either diverges from its copy with entirely native
    # duplication. Hence `own_array_methods`, which asks for the whole of what a container answers with rather
    # than for a set of names, and asks the OBJECT (through its singleton class) rather than only its class.
    # The exception pair keeps a named set and an object lookup for its own reason: neither is copying anything,
    # each is deciding what raising will dispatch — `clone` copies the singleton class, and `raise` asks the object
    # it is handed. They are two predicates rather than one because they gate two different operations: RENAMING an
    # exception clones it and hands the clone to `raise`, while re-raising it hands `raise` the object itself, so
    # the set of methods reached differs and the narrower question must not inherit the wider one's refusals.
    # `native_name_rendering?` asks about one method for a third reason again: the
    # question is not whether axn can copy or dispatch the name safely but whether the name HAS a single property
    # to be, since a String carries bytes as well as a rendering and three separate readers pick between them.
    module NativeMethods
      # `#class`, `#frozen?`, `#singleton_class`, `#ancestors` and the method-table readers are all
      # overridable, so each is BOUND: one that raised would replace the verdict being decided with the object's
      # own exception — and outside StandardError it escapes every rescue above. `Kernel#frozen?` reads the
      # object's frozen flag in C.
      #
      # Every one of them is a question put to a MODULE — a class, a singleton class, an included module — and
      # never to the value itself, which is what keeps a lookup here from dispatching. `Object#method` is
      # deliberately absent from this list: it is a question put to the VALUE, and Ruby consults the value's
      # `respond_to_missing?` when the name is absent, so it cannot answer an ownership question without
      # possibly running the very code the answer decides whether to run.
      KERNEL_CLASS = ::Kernel.instance_method(:class)
      KERNEL_FROZEN = ::Kernel.instance_method(:frozen?)
      KERNEL_SINGLETON_CLASS = ::Kernel.instance_method(:singleton_class)
      KERNEL_IVAR_GET = ::Kernel.instance_method(:instance_variable_get)
      KERNEL_IVAR_SET = ::Kernel.instance_method(:instance_variable_set)
      KERNEL_IVAR_DEFINED = ::Kernel.instance_method(:instance_variable_defined?)
      KERNEL_IVAR_REMOVE = ::Kernel.instance_method(:remove_instance_variable)
      MODULE_ANCESTORS = ::Module.instance_method(:ancestors)
      MODULE_DEFINE_METHOD = ::Module.instance_method(:define_method)
      MODULE_INCLUDE = ::Module.instance_method(:include)
      MODULE_INSTANCE_METHOD = ::Module.instance_method(:instance_method)
      MODULE_INSTANCE_METHODS = ::Module.instance_method(:instance_methods)
      MODULE_METHOD_DEFINED = ::Module.instance_method(:method_defined?)
      MODULE_NAME = ::Module.instance_method(:name)
      MODULE_PREPEND = ::Module.instance_method(:prepend)
      MODULE_PUBLIC_INSTANCE_METHODS = ::Module.instance_method(:public_instance_methods)
      MODULE_PUBLIC_METHOD_DEFINED = ::Module.instance_method(:public_method_defined?)
      MODULE_PRIVATE_INSTANCE_METHODS = ::Module.instance_method(:private_instance_methods)
      MODULE_PRIVATE_METHOD_DEFINED = ::Module.instance_method(:private_method_defined?)
      MODULE_PROTECTED_INSTANCE_METHODS = ::Module.instance_method(:protected_instance_methods)
      STRING_EMPTY = ::String.instance_method(:empty?)
      ARRAY_EMPTY = ::Array.instance_method(:empty?)
      HASH_EMPTY = ::Hash.instance_method(:empty?)
      SET_EMPTY = (::Set.instance_method(:empty?) if defined?(::Set))
      STRING_ENCODING = ::String.instance_method(:encoding)
      SYMBOL_ENCODING = ::Symbol.instance_method(:encoding)
      UNBOUND_METHOD_SUPER_METHOD = ::UnboundMethod.instance_method(:super_method)
      private_constant :SYMBOL_ENCODING, :UNBOUND_METHOD_SUPER_METHOD
      private_constant :ARRAY_EMPTY, :HASH_EMPTY, :SET_EMPTY
      private_constant :KERNEL_IVAR_GET, :KERNEL_IVAR_SET, :KERNEL_IVAR_DEFINED, :KERNEL_IVAR_REMOVE
      private_constant :KERNEL_CLASS, :KERNEL_FROZEN, :KERNEL_SINGLETON_CLASS, :STRING_EMPTY, :STRING_ENCODING,
                       :MODULE_ANCESTORS, :MODULE_DEFINE_METHOD, :MODULE_INCLUDE,
                       :MODULE_INSTANCE_METHOD, :MODULE_INSTANCE_METHODS, :MODULE_METHOD_DEFINED,
                       :MODULE_NAME, :MODULE_PREPEND,
                       :MODULE_PRIVATE_INSTANCE_METHODS, :MODULE_PRIVATE_METHOD_DEFINED,
                       :MODULE_PROTECTED_INSTANCE_METHODS,
                       :MODULE_PUBLIC_INSTANCE_METHODS, :MODULE_PUBLIC_METHOD_DEFINED

      # Keyed by the visibility they declare, so a caller reproducing a declaration passes the answer
      # `declared_visibility` gave it straight through instead of branching on it, and `fetch` refuses anything
      # that is not one of the three. `:public` is a no-op against a method `define_method` just defined; it is
      # here to keep the setter total over the reader's range rather than because it changes anything today.
      VISIBILITY_SETTERS = {
        public: ::Module.instance_method(:public),
        protected: ::Module.instance_method(:protected),
        private: ::Module.instance_method(:private),
      }.freeze
      private_constant :VISIBILITY_SETTERS

      # ActiveSupport's own definition of a blank String, matched against the value's BYTES rather than asked
      # of the value (`Regexp#match?` reads a String operand's bytes in C — no `to_str`, no `=~`, and the
      # receiver here is axn's own frozen Regexp), so a name cannot answer this one way and a later reader
      # another.
      BLANK_STRING = /\A[[:space:]]*\z/
      private_constant :BLANK_STRING

      # Ruby's own owners, read from the implementations rather than named, so an implementation that moves
      # cannot silently disagree with a constant here.
      STRING_TO_S = ::String.instance_method(:to_s).owner
      private_constant :STRING_TO_S
      #
      # `raise` dispatches the 0-arg `#exception` on whatever object it is handed — the whole of what handing an
      # exception BACK to `raise` runs, since `Exception#exception` with no arguments returns the receiver
      # without copying it.
      EXCEPTION_DISPATCH = { exception: ::Exception.instance_method(:exception).owner }.freeze
      private_constant :EXCEPTION_DISPATCH

      # RENAMING one reaches further: `Exception#exception(message)` clones the receiver, so the three hooks
      # `Kernel#clone` runs are dispatched too, and then the clone is handed to `raise`.
      EXCEPTION_REPORTING = EXCEPTION_DISPATCH.merge(
        initialize_clone: ::Exception.instance_method(:initialize_clone).owner,
        initialize_dup: ::Exception.instance_method(:initialize_dup).owner,
        initialize_copy: ::Exception.instance_method(:initialize_copy).owner,
      ).freeze
      private_constant :EXCEPTION_REPORTING

      # Every method name this Array answers with CODE OF ITS OWN, read from the method table. Empty means every
      # answer anything can get out of it is Ruby's own Array code — which is the whole condition for
      # `Kernel#dup` of it being FAITHFUL, and it is a stronger condition than owning no duplication hook.
      #
      # `dup` copies the elements, SHARES the instance variables and drops the singleton class. So a native
      # duplication only guarantees a faithful copy when the copied state determines the answers — and the state
      # `dup` copies faithfully is the elements alone. A container whose own `include?` reads `self` (identity is
      # not copied), or an ivar (shared, and still the caller's to mutate), or that lives on the singleton class
      # (not carried at all) answers one way as the caller declared it and another way in the copy axn stores.
      # Each of those was a counterexample to "the hooks are native, so the copy is faithful"; the condition that
      # holds is that the container contributes no code at all.
      #
      # Which is why this is not a list of the predicates one consumer dispatches. `inclusion:`/`exclusion:` are
      # answered by ActiveModel with `include?` (or `cover?` for a numeric/time Range) after routing through the
      # container's `respond_to?`/`is_a?`/`call`/`to_sym`, while the SAME copy path stores a `type:`/`of:` list
      # that axn reads with `Array(…)`/`any?`/`join` — so an enumerated predicate list is a prediction about
      # consumers, wrong the moment a consumer or an ActiveModel version dispatches something else. "Owns
      # nothing" needs no such prediction.
      #
      # ONE walk covers the three places own code can live, because they are one method table: the object's
      # singleton methods, a module EXTENDED onto it, and its class's own methods (with any module mixed in).
      # Private ones count — Ruby dispatches `initialize_dup`, `method_missing` and `respond_to_missing?` itself,
      # and a private singleton `respond_to_missing?` answering to `:call` is enough to route ActiveModel's
      # membership check through the container's own code on the original and not on the copy.
      #
      # Reading the singleton class materializes an empty one for a plain Array. That is deliberate and is the
      # cost of asking the complete question: Ruby creates singleton classes lazily and nothing observes the
      # difference (`class`, `dup`, `clone`, `Marshal.dump` and `singleton_methods` all answer identically), and
      # the alternative is per-name owner lookups over a list of names a consumer might dispatch.
      #
      # What ::Array itself answers with is the BASELINE, read from `::Array.ancestors` rather than assumed to be
      # `Array` alone, so a module PREPENDED to Array (which sits ahead of it in every Array's ancestry) is
      # Ruby's own here rather than every declared container's undoing. The bound: a monkeypatch on ::Array's own
      # table is indistinguishable from Ruby's implementation by any question about owners, so this says "nothing
      # below ::Array adds code", and an app that redefines `Array#include?` globally has changed what every
      # Array means, copy and original alike.
      def self.own_array_methods(value) = own_container_methods(value, ::Array)

      # The same question at any core container class, because it is one question: the clusivity
      # canonicalization asks it of a `Hash` and a `Set` before reading their members out (PRO-3319), where the
      # option copy asks it of an `Array`. Taking the baseline class as an argument is what keeps that one walk
      # one method rather than three copies of it drifting apart.
      #
      # `klass` is the caller's ESTABLISHED exact class — read through `Identity.class_of`, never asked of the
      # value — so this never decides what the value is, only what code it adds below that.
      def self.own_container_methods(value, klass)
        native = MODULE_ANCESTORS.bind_call(klass)
        names = []
        MODULE_ANCESTORS.bind_call(KERNEL_SINGLETON_CLASS.bind_call(value)).each do |mod|
          break if klass.equal?(mod)
          next if native.include?(mod)

          names.concat(MODULE_INSTANCE_METHODS.bind_call(mod, false))
          names.concat(MODULE_PRIVATE_INSTANCE_METHODS.bind_call(mod, false))
        end
        names
      end

      # Whether reporting this exception AS ITSELF can run none of the exception's own code. Renaming it
      # clones it (`Exception#exception(message)`) and then hands the clone to `raise`, which dispatches
      # the 0-arg `#exception` on it — so the reachable code is the three duplication hooks plus
      # `#exception`, looked up on the OBJECT because `clone` copies the singleton class onto the copy.
      #
      # A frozen exception fails the same test for a different reason: `Exception#exception(message)`
      # stores the new message on the clone, `clone` preserves frozen state, and the store then raises
      # FrozenError from inside the reporting path.
      def self.native_exception_reporting?(error)
        !frozen?(error) && _object_owns_none?(error, EXCEPTION_REPORTING)
      end

      # Whether handing this exception BACK to `raise` unchanged re-raises that same object. `raise error`
      # dispatches the 0-arg `#exception` on it, and Ruby has no re-raise that skips that dispatch (a bare
      # `raise` re-raising `$!` included), so a class owning `#exception` can answer with a different object
      # or raise something else entirely — which is how a guard that re-raises what it caught came to emit a
      # third exception. Looked up on the OBJECT, because `raise` asks the object it is handed.
      #
      # Deliberately NARROWER than `native_exception_reporting?`, which additionally refuses a frozen
      # exception and the duplication hooks. Both of those are about the CLONE that renaming makes; a bare
      # re-raise makes no clone, so `raise` hands back a frozen exception, and one owning only
      # `initialize_copy`, exactly as it received them (verified). Refusing them here would substitute axn's
      # own error for an original that could have been re-raised faithfully.
      def self.native_exception_reraise?(error) = _object_owns_none?(error, EXCEPTION_DISPATCH)

      def self.frozen?(value) = KERNEL_FROZEN.bind_call(value)

      # Instance-variable access, bound — for reaching into a CALLER-SUPPLIED object (an action instance is
      # always the caller's own class) rather than the caller sabotaging only itself. `instance_variable_get`/
      # `_set`/`_defined?`/`remove_instance_variable` are ordinary overridable `Kernel` methods — unlike
      # `frozen?`/`class`/`singleton_class` they carry no special status, so a class that redefines one (or
      # answers it via `method_missing`) would otherwise get to decide what axn's own framework state reads
      # back as, or silently keep axn from storing it at all. The exact precedent for binding this specific
      # pair already lives in `Core::InstanceDeferral::KERNEL_IVAR_GET`/`KERNEL_IVAR_SET` — this module is
      # where every other bound Kernel/Module operation already lives, so both are collapsed into one place
      # here and `InstanceDeferral` reaches these instead of keeping its own copy.
      #
      # The WRITE side is bound for the same reason as the read: a no-op `instance_variable_set` would make a
      # seam built on this (the `axn.call` span reference, PRO-3278) silently return nil for that one action's
      # own calls, which is a framework-state failure hiding behind what would look like an ordinary absence.
      def self.ivar_get(value, name) = KERNEL_IVAR_GET.bind_call(value, name)
      def self.ivar_set(value, name, val) = KERNEL_IVAR_SET.bind_call(value, name, val)
      def self.ivar_defined?(value, name) = KERNEL_IVAR_DEFINED.bind_call(value, name)
      def self.ivar_remove(value, name) = KERNEL_IVAR_REMOVE.bind_call(value, name)

      # Whether a MODULE defines a public instance method — read out of its method table, not asked of it. A
      # declared type is a caller's class or module, and `public_method_defined?` is as overridable as anything
      # else: one that answers wrongly inverts the verdict a declaration guard reaches, turning a declaration
      # error into a runtime failure or refusing a type that is perfectly capable.
      #
      # The caller must have established that `mod` IS a Module first, through a `case`/`when` (`Module#===` is
      # a C-level check that runs none of the object's code): binding this to anything else is a TypeError, which
      # would be exactly the replaced-verdict failure the bound read exists to prevent.
      def self.public_instance_method?(mod, name) = MODULE_PUBLIC_METHOD_DEFINED.bind_call(mod, name)

      # `mod`'s ancestry, read natively. A class that defines its own `ancestors` — or its own `<` — would
      # otherwise get to answer a membership question axn decides guards on, and a declaration guard a
      # caller can invert is not a guard. Same precondition as the readers above: the caller must have
      # established that `mod` IS a Module undispatched.
      def self.module_ancestors(mod) = MODULE_ANCESTORS.bind_call(mod)

      # Whether `mod` counts `other` among its ancestors — the undispatched form of `mod < other` (which is
      # also true for `mod == other`, matching `ancestors`' own inclusion of the receiver).
      #
      # Membership is decided by IDENTITY, not by `Array#include?`: that compares with `element == other`, and
      # the FIRST element of any class's ancestry is the class itself — so a caller's class carrying its own
      # `==` answered this membership question about itself, which is the one thing reading the ancestry
      # natively was meant to take away from it. Module identity is the only comparison this question has: two
      # distinct Modules are two distinct types however they compare.
      def self.includes_module?(mod, other)
        module_ancestors(mod).any? { |ancestor| Identity.same?(ancestor, other) }
      end

      # Whether `mod`'s OWN method table declares `name`, at any visibility — read natively, and
      # deliberately NOT the same question as `declared_instance_method(mod, name)&.owner == mod`.
      #
      # Effective lookup answers what a call would REACH, which a PREPENDED module changes: a class that
      # defines `#call` and also prepends a module defining `#call` resolves the name to the prepend, so an
      # owner comparison reports the class's own definition absent while it sits in the class's own table,
      # ready to be overwritten by a generator that concluded the name was free. A declaration guard
      # deciding whether it may DEFINE a name wants the table; a caller asking what a dispatch will reach
      # wants the lookup.
      #
      # Both visibilities, because `instance_methods(false)` omits a `private def` — which shadows just as
      # completely as a public one. Same Module precondition as the readers above.
      def self.declares_own_instance_method?(mod, name)
        MODULE_INSTANCE_METHODS.bind_call(mod, false).include?(name) ||
          MODULE_PRIVATE_INSTANCE_METHODS.bind_call(mod, false).include?(name)
      end

      # WHICH visibility a MODULE declares `name` at in its OWN table — :public, :protected or :private — or nil
      # when it declares none. For a caller that has to REPRODUCE a declaration elsewhere, where the
      # public/not-public boolean `public_instance_method?` answers is not enough: protected collapses into
      # neither of the others. Made private, a protected helper stops answering `other.helper` between two
      # instances of the same family; made public, it joins the class's outside surface, which is exactly where
      # its author declined to put it.
      #
      # Three disjoint own-table reads rather than a subtraction, because `instance_methods` counts protected
      # methods among the public ones. Own table rather than effective lookup, and the same Module precondition,
      # for the same reasons as `declares_own_instance_method?` above.
      def self.declared_visibility(mod, name)
        return :public if MODULE_PUBLIC_INSTANCE_METHODS.bind_call(mod, false).include?(name)
        return :protected if MODULE_PROTECTED_INSTANCE_METHODS.bind_call(mod, false).include?(name)
        return :private if MODULE_PRIVATE_INSTANCE_METHODS.bind_call(mod, false).include?(name)

        nil
      end

      # A module's OWN public instance methods, read natively. Same Module precondition as the readers above.
      # Public only: a private helper is not a surface a caller dispatches, so it is not a surface axn hands to
      # anyone else either.
      def self.own_public_instance_methods(mod) = MODULE_PUBLIC_INSTANCE_METHODS.bind_call(mod, false)

      # A module's CONSTANT PATH, or nil when it is anonymous — read natively, because `Module#name` is
      # overridable like the rest and one that raises replaces the message being composed. Distinct from
      # `Rendering.module_name`, which binds `to_s` and so always answers with something: this preserves
      # the nil that tells a caller to reach for its own fallback ("Action" reads better than
      # `#<Class:0x…>`, and an anonymous action class is the common case in tests).
      def self.declared_module_name(mod) = MODULE_NAME.bind_call(mod)

      # `prepend`, bound — for INSTALLING a module rather than asking a question. Ordinarily dispatching
      # this would be the caller sabotaging only itself, which is not axn's to defend; the exception is
      # installing a GUARD, where a `prepend` that quietly declines leaves the guard uninstalled and the
      # thing it was watching for silently permitted. Absent functionality is loud; an absent guard is not.
      def self.prepend_module(mod, other) = MODULE_PREPEND.bind_call(mod, other)

      # `include`, bound — for INSTALLING onto a CALLER'S class rather than asking a question. Same reasoning as
      # `prepend_module`: a class that defines its own `include` and quietly declines would leave the module
      # absent, and an absent deferral silently restores the shadowing it was there to remove.
      def self.include_module(mod, other) = MODULE_INCLUDE.bind_call(mod, other)

      # The method-table WRITERS, bound. Unlike the two above, these only ever target a module axn built itself,
      # where there is no user definition to decline: binding them buys no defence, and is here so that one
      # install path reads consistently rather than half through Ruby's own implementations and half through
      # whatever the receiver happens to answer.
      #
      # `set_declared_visibility` exists because `define_method` always defines PUBLIC. A wrapper standing in for
      # another module's method has to be declared at THAT module's visibility, or the installation publishes a
      # method its author deliberately kept off the class's surface.
      def self.define_own_instance_method(mod, name, &) = MODULE_DEFINE_METHOD.bind_call(mod, name, &)
      def self.set_declared_visibility(mod, name, visibility) = VISIBILITY_SETTERS.fetch(visibility).bind_call(mod, name)

      # A MODULE's own singleton class, read natively — for a caller that has to INSTALL something on it
      # rather than ask a question about it. A class that answers with someone else's singleton class
      # redirects the installation rather than merely inverting a verdict: a `method_added` hook meant for
      # one class, prepended to `::Object`'s singleton class, fires for every class in the process.
      #
      # Same precondition as the readers above — the caller must have established that `mod` IS a Module
      # undispatched — though this one binds `Kernel#singleton_class`, so it is a Module's singleton class
      # only because the caller already knows `mod` is one.
      def self.module_singleton_class(mod) = KERNEL_SINGLETON_CLASS.bind_call(mod)

      # The UnboundMethod a MODULE declares for `name` at ANY visibility, or nil when it declares none — the
      # module-level twin of `method_owner`, for a caller that needs the method itself (its `owner`, its
      # `source_location`) rather than just its owner.
      #
      # One lookup with one absence policy, on the same terms as `method_owner`: nil rather than a raise, so a
      # caller compares against what it expects and an absent name simply fails that comparison.
      #
      # Any visibility, deliberately, and the distinction is not academic. A caller here is asking whether the
      # module DECLARES something of its own — which is what decides whether an inherited implementation still
      # governs — and a non-public definition SHADOWS the inherited one just as completely as a public one
      # does: a `protected`/`private` `to_h` on a Struct makes `value.to_h` unreachable, so neither the
      # override nor `Struct#to_h` serializes it and the value degrades to `to_s`. A public-only reader calls
      # that "no override" and a `method_defined?` reader misses the private case, so both judge such a class
      # as provably member-keyed while its runtime rendering is a String.
      #
      # A caller asking the DIFFERENT question — "would a consumer be able to dispatch this?" — wants
      # `public_instance_method?` above, which is the right reader for a segment that has to be readable.
      #
      # Same precondition as that one, for the same reason: the caller must have established that `mod` IS a
      # Module undispatched, since binding this to anything else is a TypeError — exactly the replaced-verdict
      # failure a bound read exists to prevent.
      def self.declared_instance_method(mod, name)
        MODULE_INSTANCE_METHOD.bind_call(mod, name)
      rescue ::NameError
        nil
      end

      # The declaration `method` STANDS IN FRONT OF — the one a `super` from it would reach — or nil when it
      # stands in front of nothing. Taking it repeatedly enumerates every declaration of the name that the
      # ancestry holds, in the order a dispatch would meet them, starting from `declared_instance_method`.
      #
      # Ruby's own resolver rather than a walk over `module_ancestors` comparing own tables, and the difference
      # is not cosmetic: this reports a PREPENDED module in the position a call reaches it, and it STOPS at an
      # `undef_method` entry — which no own-table read reports at all, and which effective lookup can only
      # report for the class as a whole, so a module included behind another module's definition of the name
      # cannot be asked about any other way.
      #
      # Bound like the readers above. `super_method` is `Method`'s and `UnboundMethod`'s, and the receiver here
      # is always one this module's own `declared_instance_method` produced.
      def self.shadowed_instance_method(method) = UNBOUND_METHOD_SUPER_METHOD.bind_call(method)

      # Whether a dispatch for `name` on an instance of `mod` would land ANYWHERE — the boolean twin of
      # `declared_instance_method`, for a caller that needs only reachability and not the implementation. Both
      # readers resolve over the whole ancestry the way a call does, so both see a PREPENDED module's position
      # and treat a name `undef_method` removed as absent; own-table readers report neither.
      #
      # Two reads because Ruby splits the range: `method_defined?` answers for public and protected,
      # `private_method_defined?` for the rest, and a non-public definition is reached by a dispatch from
      # inside just as a public one is from outside. Predicates rather than `declared_instance_method(...).nil?`
      # because absence is the ordinary answer here — every name in a fixed set, asked of every class — and
      # that reader pays a NameError for each one.
      #
      # Same Module precondition as the readers above.
      def self.instance_method_reachable?(mod, name)
        MODULE_METHOD_DEFINED.bind_call(mod, name) || MODULE_PRIVATE_METHOD_DEFINED.bind_call(mod, name)
      end

      # The UnboundMethod the value's METHOD TABLE declares for `name`, at any visibility, or nil when it declares
      # none. The value-level twin of `declared_instance_method`, and the one lookup every question in this module
      # about a VALUE's methods resolves through: `method_owner` reads its owner, and a caller that must CALL what
      # the table declares (`ShapeGraph.fetch`) binds it back to the value.
      #
      # Resolved through the value's SINGLETON CLASS, on the same terms and for the same reason as
      # `own_array_methods`: that one module's ancestry is the whole of what the value would dispatch — its
      # singleton methods, a module EXTENDED onto it, and its class's own methods with anything mixed in or
      # prepended — so one lookup against it is the complete question. `Module#instance_method` resolves it,
      # rather than a hand-rolled walk over `MODULE_ANCESTORS`, because it is the same C-level resolver
      # `Object#method` uses over that same ancestry: it finds private and protected definitions, honours a
      # PREPENDED module's position, and treats a name `undef_method` removed as absent — three things a walk
      # comparing name lists gets wrong in the unsafe direction, since an UNDEF'd `to_s` would otherwise resolve
      # to the superclass implementation that no longer answers.
      #
      # Asking the singleton class rather than the value is the whole point: `Object#method` is a question put to
      # the VALUE, and Ruby consults the value's `respond_to_missing?` whenever the name is ABSENT — so on a
      # value that defines that hook, the lookup ran the caller's code, and one that raised outside `NameError`
      # left through it as the verdict. Absence is not a corner (`facade_inspector` asks for a `to_fs` that exists
      # in no process without ActiveSupport's conversions, and `ShapeGraph` asks every shape member for the
      # optional attributes a minimal member simply does not carry), and the exception path is the one place a
      # predicate must not become the failure: an exception that removes its own `#exception` while answering is
      # asked about a method that is by then gone.
      #
      # A `method_missing`-backed method is therefore reported ABSENT, where `Object#method` reports the class that
      # would dispatch it. For an ownership question that is the wanted answer (see `method_owner`); for a caller
      # that needs the VALUE, absence here is precisely what routes it to a dispatch of its own.
      #
      # The cost of asking the complete question is that reading the singleton class materializes an empty one,
      # exactly as in `own_array_methods`, and nothing observes the difference.
      def self.declared_method(value, name)
        MODULE_INSTANCE_METHOD.bind_call(method_table(value), name)
      rescue ::NameError
        nil
      end

      # Which class or module OWNS the method a value would dispatch for `name`, or nil when the value has no such
      # method at all — the owner of `declared_method`'s result, so the lookup and this reader carry ONE absence
      # policy between them rather than resolving the method table twice. `UnboundMethod#owner` is Ruby's own on an
      # object Ruby constructed, so reading it dispatches nothing the caller wrote.
      #
      # This is what decides whether CALLING that method runs Ruby's own code or the caller's, which a walk needs
      # before it may run one at all: a container subclass that INHERITS `empty?` answers with the built-in's
      # implementation, while one that overrides it — or carries a singleton, which sits ahead of its class — is
      # arbitrary code that a verdict must not enter.
      #
      # A `method_missing`-backed method reports nil rather than the class that would dispatch it, and every
      # caller compares the owner against a specific built-in — so nil and "the value's own class" take the
      # identical branch.
      def self.method_owner(value, name) = declared_method(value, name)&.owner

      # The module whose ancestry holds everything `value` would dispatch.
      #
      # Normally the singleton class. A few values REFUSE one (`TypeError: can't define singleton`) — the
      # immediates, and an interned frozen String literal — and for those the class is the same complete answer,
      # because a value that cannot be given a singleton class cannot be carrying a singleton method either:
      # defining one raises, extending it raises, and the refusal is what makes both true. Reaching for the
      # class only on the refusal keeps that narrower answer off every other value, where a singleton is exactly
      # what the lookup must see.
      #
      # Frozen is NOT one of those cases — an ordinary frozen object hands back a frozen singleton class — which
      # matters because re-raising a frozen exception is supported and asks this question first.
      def self.method_table(value)
        KERNEL_SINGLETON_CLASS.bind_call(value)
      rescue ::TypeError
        KERNEL_CLASS.bind_call(value)
      end

      private_class_method :method_table

      # Whether this NAME renders through Ruby's own code, which is the condition for "the property a rule judged
      # is the property every consumer reads".
      #
      # One property name is read by three separate readers: the property-name rules canonicalize it, the emitter
      # writes it into `required` through its `to_s`, and `JSON.generate` renders a Hash key through that same
      # `to_s`. Where the rendering is Ruby's own, those three are one fact. Where it is not, there is no single
      # fact to be had — and the failure is the one the rules exist to prevent. A String SUBCLASS that defines
      # `to_s` has BOTH bytes and a rendering, and only its author knows which one names the property (a subclass
      # holding `"other"` and rendering `"dup"` passed the collision rules beside a `:dup` field and then emitted
      # the property `"dup"` twice). Anything that is neither a String nor a Symbol has one rendering but produces
      # it per call, so a `to_s` that answers differently answers the verdict one property and the encoder another.
      # Both are refused rather than verified, for the reason this module exists.
      #
      # A Symbol needs no lookup and cannot be a false negative: it can carry no override at all — `Symbol` takes
      # no instance of a subclass (`new` is undefined, `allocate` raises TypeError) and `:x.singleton_class` raises
      # TypeError — so `:x.to_s` is always Symbol's own. A String subclass that does NOT define `to_s` inherits
      # String's, which renders the receiver's own bytes, so it is as native here as a plain String.
      #
      # The lookup asks the OBJECT rather than its class, because what will be dispatched is the whole question and a
      # singleton `to_s` is as much a name's rendering as its class's. That answer is complete rather than reachable
      # from every caller: a PLAIN String carrying one is never handed to this by the property-name rules, since the
      # emitted property they read is the frozen copy Ruby makes of a plain String Hash key — which is why the
      # emitter reads one name once as well (`Reflection::Schema.required_key`), the two together being what keeps
      # every artifact naming one property.
      # The lookup goes through `method_owner`, the one place this module resolves an owner and the one place it
      # decides what ABSENCE means. A String that has UNDEF'd `to_s` resolves to no method at all, so it renders
      # through whatever `method_missing` serves — emphatically not String's own — and a nil owner is never
      # `equal?` to `STRING_TO_S`, so that is the answer without a rescue wrapping the whole method body.
      def self.native_name_rendering?(name)
        case name
        when ::Symbol then true
        when ::String then STRING_TO_S.equal?(method_owner(name, :to_s))
        else false
        end
      end

      # The ENCODING a name's bytes are in, read from the bound base implementation rather than asked of the
      # name — a String subclass can override `encoding` as readily as `to_s`, and this decides a guard. Nil
      # for anything that is neither, which has no bytes to judge and is refused by the type rule instead.
      def self.name_encoding(value)
        case value
        when ::Symbol then SYMBOL_ENCODING.bind_call(value)
        when ::String then STRING_ENCODING.bind_call(value)
        end
      end

      # Whether a name is written in an encoding whose ASCII range is ASCII — which every declared name must
      # be, because a name that is not can neither be ASKED the questions a declaration asks of it nor SERVE
      # as a wire key afterwards.
      #
      # Not a stand-in for "is UTF-8": a Latin-N name is ASCII-compatible, compares against axn's own ASCII
      # patterns, and works end to end (it canonicalizes to its UTF-8 rendering for every property it names).
      # What is excluded is the wide encodings — UTF-16, UTF-32 — where `"a.b".include?(".")` raises
      # `Encoding::CompatibilityError` rather than answering, and where the Symbol the name interns to is a
      # DISTINCT object from its UTF-8 twin (`"ab".encode("UTF-16LE").to_sym != :ab`), so the property the
      # schema advertises can never be the key a caller supplies.
      def self.ascii_compatible_name?(value)
        encoding = name_encoding(value)
        return true if encoding.nil?

        encoding.ascii_compatible?
      end

      # Does this caller-supplied value mean "nothing was supplied" — `nil`, `false`, an all-whitespace (or
      # empty) String, or the empty Symbol?
      #
      # Two questions of that shape, both about a value axn was handed and neither able to ask the value: what a
      # declared name means (`on:`, `as:`, `expose_return_as:`) and whether a `fail!` reason was given at all
      # (`Axn::Failure#supplied_reason`).
      #
      # `present?`/`blank?` cannot answer it: they are ActiveSupport methods on Object, so a String subclass
      # overrides them, and a value that answered "blank" here and "present" to a later reader skipped
      # canonicalization and was stored raw — the exact guard/consumer split canonicalizing exists to close.
      # The reason case fails harder still, because it is read while a failure is already being reported: an
      # override that raises replaces the failure with its own exception rather than merely disagreeing.
      #
      # But the SET has to stay what `blank?` meant, because this decides whether an option was supplied at all
      # and every spelling of "not supplied" a caller could reasonably write was one: `expose_return_as: false`
      # and `on: false` are "no exposure"/"no route", and a whitespace-only String names nothing. Answering
      # only nil/empty here handed `false` to `to_sym` (NoMethodError) and declared an exposure named `:"   "`.
      # Whitespace is read off the value's BYTES with axn's own frozen Regexp — `Regexp#match?` takes a String
      # operand as-is in C (no `to_str`, no `=~`) — which is a bound read, not a question put to the value.
      #
      # `String#empty?`/`#encoding` are bound for the same reason they would be overridden. `Symbol#empty?` is
      # NOT bound and does not need to be: a Symbol subclass can be DECLARED but never instantiated (`new` is
      # undefined and `allocate` raises TypeError), so no value is ever an instance of one.
      #
      # Anything that is neither nil/false nor a String nor a Symbol is "present" here, which leaves it to the
      # caller's `to_sym` exactly as before — `on: 123` still raises NoMethodError rather than being silently
      # treated as no route. That is deliberately narrower than `blank?`, which called every empty container
      # blank (it dispatches `empty?` on anything that answers it): `[]` names nothing and is not a spelling of
      # "no option", so it earns the same NoMethodError as `123` rather than being silently ignored. A reason
      # gets the same treatment from the other direction — `fail!([])` carries `[]` as its reason rather than
      # falling back to the default message, which is the honest reading of a caller passing a container.
      def self.absent_value?(value)
        case value
        when nil, false then true
        when ::Symbol then value.empty?
        when ::String then STRING_EMPTY.bind_call(value) || _blank_string?(value)
        else false
        end
      end

      # Whether a value is one ActiveModel's `allow_blank:` would SKIP — `value.blank?`, as its
      # `EachValidator` asks it (activemodel 7.2.2.2). Deliberately WIDER than `absent_value?` above, which
      # answers a different question: that one refuses to read `[]` as a spelling of "no option", while this
      # one must agree with ActiveSupport, because a blank value really is one the validator never sees.
      #
      # Every read is bound, so nothing the value defines decides it — the point of asking here rather than
      # calling `blank?`, which dispatches. Where the two could still disagree, this answers NOT BLANK,
      # because a caller acts on the verdict by DISCOUNTING the value: a false "blank" drops a value
      # ActiveModel really would compare, and only a missed one is safe.
      #
      # EXACT class throughout, which is what makes that guarantee hold without reasoning about
      # ActiveSupport's per-class spelling. A subclass may override `blank?` itself, or the `empty?` some of
      # ActiveSupport's definitions dispatch — measured, an `Array` subclass with `def blank? = false` is not
      # blank though the root's `empty?` says it is, and a whitespace `String` subclass does the same. An
      # exact class has no such override anywhere in its lookup path, so ActiveSupport's implementation and
      # the bound read here are the same code. Every subclass, and every object of the caller's own, is left
      # NOT blank.
      #
      # `Symbol#empty?` is dispatched, for the reason `absent_value?` gives: a Symbol subclass can be declared
      # but never instantiated, so no value is ever an instance of one.
      def self.blank_literal?(value)
        klass = KERNEL_CLASS.bind_call(value)

        return true if klass.equal?(::NilClass) || klass.equal?(::FalseClass)
        return value.empty? if klass.equal?(::Symbol)
        return STRING_EMPTY.bind_call(value) || _blank_string?(value) if klass.equal?(::String)
        return ARRAY_EMPTY.bind_call(value) if klass.equal?(::Array)
        return HASH_EMPTY.bind_call(value) if klass.equal?(::Hash)
        return SET_EMPTY.bind_call(value) if SET_EMPTY && klass.equal?(::Set)

        false
      end

      # Whitespace-only, for any encoding, without letting the check itself become the failure. A String whose
      # bytes are invalid for its encoding raises from the match — it is not blank, and reporting it is the
      # name rules' job (they name it in axn's own error, having rendered it) rather than a blankness test's.
      def self._blank_string?(value)
        BLANK_STRING.match?(value)
      rescue ::Encoding::CompatibilityError
        _blank_in_own_encoding?(value)
      rescue ::StandardError
        false
      end

      # A non-ASCII-compatible String (UTF-16, …) cannot be matched against a US-ASCII pattern at all, so ask
      # the same question in the value's own encoding — mirroring ActiveSupport, so "blank" means one thing
      # whatever the name is written in. The pattern is rebuilt per call rather than cached: reaching this
      # requires declaring a name in such an encoding, and it runs once, at declaration.
      def self._blank_in_own_encoding?(value)
        source = BLANK_STRING.source.encode(STRING_ENCODING.bind_call(value))
        ::Regexp.new(source, BLANK_STRING.options | ::Regexp::FIXEDENCODING).match?(value)
      rescue ::StandardError
        false
      end

      private_class_method :_blank_string?, :_blank_in_own_encoding?

      # Through `method_owner`, which is the ONE lookup in this module and carries the one absence policy: a
      # method that does not exist has no owner, so it answers nil rather than raising.
      #
      # That matters because ABSENCE is reachable here, not hypothetical. `raise <instance>` dispatches the
      # 0-arg `#exception` on the object, and an `#exception` that undefines itself while answering leaves the
      # exception with no such method by the time this is asked — so absence is the state of the very object the
      # guard whose whole promise is that it emits no third exception is asking about. Which is also why the
      # lookup may not be a question put to the value: on an absent name Ruby consults the value's
      # `respond_to_missing?`, and that same exception would have been the one thing running inside the guard.
      #
      # nil is the SAFE answer in the direction that matters: `owner.equal?(nil)` is false for every expected
      # owner, so this answers false, both predicates above read "not native", and each takes its degraded
      # branch — `native_exception_reraise?` re-raises through `Axn::ReraiseFailed` carrying the
      # original as `cause`, and `native_exception_reporting?` returns axn's own `InvalidContract` rather than
      # renaming the original. Both are the outcomes those branches exist for; neither runs the missing method.
      def self._object_owns_none?(value, expected)
        expected.all? { |name, owner| owner.equal?(method_owner(value, name)) }
      end

      private_class_method :_object_owns_none?
    end
  end
end
