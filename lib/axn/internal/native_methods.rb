# frozen_string_literal: true

module Axn
  module Internal
    # Whether the implementation of an operation on a caller's object is RUBY'S OWN — answered from the
    # method table, without running a line the object's class wrote.
    #
    # Two layers need this, for one reason. Cooperating with a caller's object means running its code:
    # copying a declared `inclusion:` container runs its `initialize_dup`, and renaming a contract failure
    # runs the exception's `#exception`. Verifying that the code BEHAVED produced a new counterexample
    # every round, because the body is arbitrary — a duplication hook that drops only a derived lookup
    # index leaves every element it holds answering `include?` correctly and the aliases it no longer
    # indexes answering wrongly, and an `#exception` that succeeds on its first call and raises on its
    # second is not excluded by the object having been raised once. No behavioural probe terminates
    # against an arbitrary body, so each fix was defeated by the next case.
    #
    # OWNERSHIP terminates. It is a fact about the method table rather than a prediction about behaviour:
    # if Ruby's own implementation is what will run, the operation is bounded; if it is not, axn does not
    # run it at all and takes an honest fallback instead (see `ShapeGraph.detachable_container?` and
    # `Axn._named_invalid_tool_contract`). This deliberately over-rejects — a faithful `initialize_dup` is
    # indistinguishable from a lying one without running it — and bounded-and-slightly-strict is the trade
    # every unbounded verification here lost.
    #
    # Two lookups, because the two operations dispatch differently and the difference decides correctness:
    # `dup` looks its hooks up on the COPY's class (a copy carries no singleton), while `clone` copies the
    # singleton class and `raise` dispatches on the object it is handed. Asking the object where `dup`
    # asks the class would reject a container over a singleton method nothing will run; asking the class
    # where `clone` asks the object would miss a singleton override entirely.
    module NativeMethods
      # `#method`, `#instance_method`, `#class` and `#frozen?` are all overridable, so each is BOUND: one
      # that raised would replace the verdict being decided with the object's own exception — and outside
      # StandardError it escapes every rescue above. `Kernel#frozen?` reads the object's frozen flag in C.
      OBJECT_METHOD = ::Object.instance_method(:method)
      MODULE_INSTANCE_METHOD = ::Module.instance_method(:instance_method)
      OBJECT_CLASS = ::Object.instance_method(:class)
      KERNEL_FROZEN = ::Kernel.instance_method(:frozen?)
      private_constant :OBJECT_METHOD, :MODULE_INSTANCE_METHOD, :OBJECT_CLASS, :KERNEL_FROZEN

      # Ruby's own owners, read from the implementations rather than named, so an implementation that moves
      # cannot silently disagree with a constant here. They differ by receiver — `Array` defines
      # `initialize_copy` itself, while an exception inherits both hooks from `Kernel` — which is why each
      # set is read from the class the operation is performed on.
      #
      # `Kernel#dup` reaches exactly two hooks: `initialize_dup`, which calls `initialize_copy`.
      # `Kernel#clone` adds `initialize_clone` on top of those. `raise` dispatches the 0-arg `#exception`
      # on whatever object it is handed, and `Exception#exception(message)` clones the receiver.
      ARRAY_DUP_HOOKS = { initialize_dup: ::Array.instance_method(:initialize_dup).owner,
                          initialize_copy: ::Array.instance_method(:initialize_copy).owner }.freeze
      EXCEPTION_REPORTING = { exception: ::Exception.instance_method(:exception).owner,
                              initialize_clone: ::Exception.instance_method(:initialize_clone).owner,
                              initialize_dup: ::Exception.instance_method(:initialize_dup).owner,
                              initialize_copy: ::Exception.instance_method(:initialize_copy).owner }.freeze
      private_constant :ARRAY_DUP_HOOKS, :EXCEPTION_REPORTING

      # Whether `Kernel#dup` of this Array can run none of the Array's own code — in which case the copy
      # holds what the original held and answers as it did, since `Array#include?` is a pure function of
      # the elements. Looked up on the object's CLASS, which is where `dup` will look: a copy does not
      # carry the original's singleton class, so a singleton hook is not code `dup` can reach.
      def self.native_array_dup?(value) = _class_owns_none?(value, ARRAY_DUP_HOOKS)

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

      def self._class_owns_none?(value, expected)
        klass = OBJECT_CLASS.bind_call(value)
        expected.all? { |name, owner| owner.equal?(MODULE_INSTANCE_METHOD.bind_call(klass, name).owner) }
      end

      def self._object_owns_none?(value, expected)
        expected.all? { |name, owner| owner.equal?(OBJECT_METHOD.bind_call(value, name).owner) }
      end

      private_class_method :_class_owns_none?, :_object_owns_none?
    end
  end
end
