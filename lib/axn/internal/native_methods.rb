# frozen_string_literal: true

module Axn
  module Internal
    # Which of a caller's object's answers are RUBY'S OWN — read from the method table, without running a line
    # the object's class wrote.
    #
    # Two layers need this, for one reason. Cooperating with a caller's object means running its code: storing a
    # declared `inclusion:` container copies it, and renaming a contract failure runs the exception's
    # `#exception`. Verifying that the code BEHAVED produced a new counterexample every round, because the body
    # is arbitrary — a duplication hook that drops only a derived lookup index leaves every element it holds
    # answering `include?` correctly and the aliases it no longer indexes answering wrongly, and an `#exception`
    # that succeeds on its first call and raises on its second is not excluded by the object having been raised
    # once. No behavioural probe terminates against an arbitrary body, so each fix was defeated by the next case.
    #
    # OWNERSHIP terminates. It is a fact about the method table rather than a prediction about behaviour: where
    # Ruby's own implementation is what answers, the operation is bounded; where it is not, axn does not perform
    # the operation at all and takes an honest fallback instead (see `Internal::ShapeGraph.detached_option_array` and
    # `Axn._named_invalid_tool_contract`). This deliberately over-rejects — a faithful `include?` is
    # indistinguishable from a lying one without running it — and bounded-and-slightly-strict is the trade every
    # unbounded verification here lost.
    #
    # But ownership of WHICH methods, and looked up WHERE, is where a bounded rule can still be wrong, and both
    # halves were. A copy is faithful only when the state `dup` copies faithfully determines every answer, so
    # owning the duplication hooks was too narrow: `dup` shares the instance variables and drops the singleton
    # class, and a container answering membership from either diverges from its copy with entirely native
    # duplication. Hence `own_array_methods`, which asks for the whole of what a container answers with rather
    # than for a set of names, and asks the OBJECT (through its singleton class) rather than only its class.
    # `native_exception_reporting?` keeps a named set and an object lookup for its own reason: it is not copying
    # anything, it is deciding what raising will dispatch — `clone` copies the singleton class, and `raise` asks
    # the object it is handed.
    module NativeMethods
      # `#method`, `#frozen?`, `#singleton_class`, `#ancestors` and the two method-table readers are all
      # overridable, so each is BOUND: one that raised would replace the verdict being decided with the object's
      # own exception — and outside StandardError it escapes every rescue above. `Kernel#frozen?` reads the
      # object's frozen flag in C.
      OBJECT_METHOD = ::Object.instance_method(:method)
      KERNEL_FROZEN = ::Kernel.instance_method(:frozen?)
      KERNEL_SINGLETON_CLASS = ::Kernel.instance_method(:singleton_class)
      MODULE_ANCESTORS = ::Module.instance_method(:ancestors)
      MODULE_INSTANCE_METHODS = ::Module.instance_method(:instance_methods)
      MODULE_PRIVATE_INSTANCE_METHODS = ::Module.instance_method(:private_instance_methods)
      STRING_EMPTY = ::String.instance_method(:empty?)
      private_constant :OBJECT_METHOD, :KERNEL_FROZEN, :KERNEL_SINGLETON_CLASS, :STRING_EMPTY,
                       :MODULE_ANCESTORS, :MODULE_INSTANCE_METHODS, :MODULE_PRIVATE_INSTANCE_METHODS

      # Ruby's own owners, read from the implementations rather than named, so an implementation that moves
      # cannot silently disagree with a constant here.
      #
      # `raise` dispatches the 0-arg `#exception` on whatever object it is handed, and
      # `Exception#exception(message)` clones the receiver — so renaming reaches `#exception` plus the three
      # hooks `Kernel#clone` runs (`initialize_clone`, `initialize_dup`, `initialize_copy`).
      EXCEPTION_REPORTING = { exception: ::Exception.instance_method(:exception).owner,
                              initialize_clone: ::Exception.instance_method(:initialize_clone).owner,
                              initialize_dup: ::Exception.instance_method(:initialize_dup).owner,
                              initialize_copy: ::Exception.instance_method(:initialize_copy).owner }.freeze
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
      def self.own_array_methods(value)
        native = MODULE_ANCESTORS.bind_call(::Array)
        names = []
        MODULE_ANCESTORS.bind_call(KERNEL_SINGLETON_CLASS.bind_call(value)).each do |mod|
          break if ::Array.equal?(mod)
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

      def self.frozen?(value) = KERNEL_FROZEN.bind_call(value)

      # Does this caller-supplied name mean "absent" — nil, or the empty String/Symbol?
      #
      # `present?`/`blank?` cannot answer it: they are ActiveSupport methods on Object, so a String subclass
      # overrides them, and a value that answered "blank" here and "present" to a later reader skipped
      # canonicalization and was stored raw — the exact guard/consumer split canonicalizing exists to close.
      #
      # `String#empty?` is bound for the same reason it would be overridden. `Symbol#empty?` is NOT bound and does
      # not need to be: a Symbol subclass can be DECLARED but never instantiated (`new` is undefined and
      # `allocate` raises TypeError), so no value is ever an instance of one. Anything that is neither nil nor a
      # String nor a Symbol is "present" here, which leaves it to the caller's `to_sym` exactly as before — an
      # `on: 123` still raises NoMethodError rather than being silently treated as no route.
      def self.absent_name?(value)
        case value
        when nil then true
        when ::Symbol then value.empty?
        when ::String then STRING_EMPTY.bind_call(value)
        else false
        end
      end

      def self._object_owns_none?(value, expected)
        expected.all? { |name, owner| owner.equal?(OBJECT_METHOD.bind_call(value, name).owner) }
      end

      private_class_method :_object_owns_none?
    end
  end
end
