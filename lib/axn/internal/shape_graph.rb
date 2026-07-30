# frozen_string_literal: true

module Axn
  module Internal
    # Non-dispatching reads of a caller-supplied shape graph.
    #
    # A `shape:` kwarg may be handed in raw — an arbitrary object as the shape Hash, and arbitrary
    # objects as its members — while the declaration guards over that graph and the schema reflection
    # that consumes it are two separate walks. An object that lies about its type, or about which
    # methods it has, can therefore make a guard skip a member reflection still emits: the guard's
    # verdict and the rendered output disagree, which is precisely what the guard exists to prevent.
    # So every question asked here is answered from the real class and the real method table, never
    # from a method the graph's own objects can define.
    #
    # What a walk genuinely REQUIRES stays the graph's own: reading `:members` off a Hash calls its
    # `[]`, and reading a member's `field` invokes that reader. Those are the same calls reflection
    # makes, so a CONSISTENT lie there changes what both decide rather than splitting them apart — a
    # `[]` that hides members hides them from the guard and from the schema alike. Every read of a shape's
    # members in axn therefore goes through `members` below, and nothing reads them another way; a second
    # route (an `each`-copy of the shape's real entries) would see members `[]` had hidden and hand the
    # schema a list no guard had walked.
    #
    # An INCONSISTENT lie — a `[]` or a reader answering differently on successive reads — still splits
    # them, because guard and consumer are separate reads however each is written. Nothing here closes
    # that, and nothing here claims to: it is a caller giving two answers, not a guard missing one.
    module ShapeGraph
      # `#method` is itself overridable, so the lookup below goes through Object's implementation: an
      # object whose own `#method` raises would otherwise replace a declaration verdict with its
      # exception — and escape every rescue when that exception is outside StandardError.
      OBJECT_METHOD = ::Object.instance_method(:method)
      OBJECT_PUBLIC_SEND = ::Object.instance_method(:public_send)

      # The missing name a NameError carries, read through the implementation that STORES it. `NoMethodError`
      # inherits `name` from `NameError`, so binding NameError's reaches the stored symbol whatever a
      # subclass defines on top — and a subclass whose `name` raises cannot then replace a declaration
      # verdict from inside the line that decides it.
      NAME_ERROR_NAME = ::NameError.instance_method(:name)
      private_constant :OBJECT_METHOD, :OBJECT_PUBLIC_SEND, :NAME_ERROR_NAME

      # `value` when it is genuinely a Hash, else nil. `case`/`when` consults the real class through
      # `Module#===` (a C-level check), while `is_a?` is overridable — and a Hash subclass answering
      # `is_a?(Hash)` with false would skip a guard over a shape reflection still consumes.
      def self.hash_or_nil(value)
        case value
        when ::Hash then value
        end
      end

      # Copying a caller's container: `Hash#each` and `Kernel#dup` BOUND rather than dispatched, so a subclass
      # overriding either cannot decide what the stored contract holds — one whose `dup` returned `self`, or
      # whose `each` hid entries, otherwise left the caller's object aliased into a declared contract. Unlike a
      # members LIST — an arbitrary object whose `each` axn has no choice but to run (see `capture`) — a Hash's
      # own traversal is reachable without asking the subclass anything.
      HASH_EACH = ::Hash.instance_method(:each)
      KERNEL_DUP = ::Kernel.instance_method(:dup)
      ARRAY_SIZE = ::Array.instance_method(:size)
      ARRAY_AT = ::Array.instance_method(:[])
      BASIC_EQUAL = ::BasicObject.instance_method(:equal?)
      private_constant :HASH_EACH, :KERNEL_DUP, :ARRAY_SIZE, :ARRAY_AT, :BASIC_EQUAL

      # A caller Hash's entries, in a plain Hash this module owns.
      def self.copy_entries(hash)
        copy = {}
        HASH_EACH.bind_call(hash) { |key, value| copy[key] = value }
        copy
      end

      # A same-CLASS shallow copy. The class is preserved deliberately: a container's own behavior is part of
      # what a declaration MEANS — an `inclusion:` set answers membership with its own `include?` — so replacing
      # a subclass with a plain Array would change the contract rather than protect it, and would also publish
      # an enum reflection deliberately withholds for anything but an exact Array.
      #
      # `Kernel#dup` still runs the duplication CALLBACK (`initialize_dup`), which is the caller's code and can
      # alter the copy — one that cleared it left a contract rejecting the very values it declared. Bypassing the
      # callback is not the answer (a class that establishes its invariants there would get a broken copy), nor
      # is refusing containers that define one (a subclass rebuilding a derived index from it is legitimate and
      # works). So the copy is CHECKED instead: see `same_elements?`, and the declaration error its caller
      # raises. Predicting which containers are safe is what checking replaces.
      def self.detached_dup(value) = KERNEL_DUP.bind_call(value)

      # Whether a copy holds the elements the original held. Nothing either object defines is dispatched: `==`,
      # `size` and `each` are all overridable, and the copy is the caller's class too, so it can lie exactly as
      # readily as the original — both are read through `Array`'s own `size`/`[]`. Element IDENTITY is the right
      # question for a shallow copy (the elements are the same objects, not copies of them), asked through
      # `BasicObject#equal?` so an element's own override cannot answer it either.
      def self.same_elements?(original, copy)
        size = ARRAY_SIZE.bind_call(original)
        return false unless size == ARRAY_SIZE.bind_call(copy)

        index = 0
        while index < size
          return false unless BASIC_EQUAL.bind_call(ARRAY_AT.bind_call(original, index), ARRAY_AT.bind_call(copy, index))

          index += 1
        end

        true
      end

      # A shape's members, captured into an Array this module owns. Captured via `each` — the one
      # method walking a container inherently requires, and the one reflection's own member walk uses
      # — so `select`/`map`/`any?`/`to_a` are never taken from a caller's Array subclass. Each of
      # those is separately overridable, so reaching for one hands the caller a second say in what a
      # guard sees that the walk never needed, and a shorter list than reflection gets.
      #
      # A non-Hash shape has no members at all, which is what makes this the type test every shape
      # walk shares: a lie about being a Hash cannot skip a walk, because the walk asks for members
      # rather than asking the shape what it is.
      # `nil.equal?` rather than `list.nil?`: this is a type test on a caller value, and `nil?` is
      # overridable — a members list answering true would hide itself from every guard.
      def self.members(shape)
        hash = hash_or_nil(shape)
        capture(hash && hash[:members])
      end

      # A caller-supplied list, captured into an Array this module owns. THE seam every layer reads a member
      # list through — the declaration guard, schema reflection, and runtime validation all consume this, so
      # they cannot see different members. A list that answers `filter_map`/`map`/`select` differently from
      # `each` would otherwise give them two answers: reflection emitted nothing while the guard and the
      # validator saw two members.
      def self.capture(list)
        return [] if nil.equal?(list)

        captured = []
        list.each { |element| captured << element } # rubocop:disable Style/MapIntoArray -- `map` is overridable; `each` only
        captured
      end

      # ONE node of a caller-supplied shape graph, copied into a Hash this module owns, with `members` — the
      # copies the declaration walk built for this node — put in place of whatever it carried.
      #
      # Copied at DECLARATION because a contract must not change after the class is declared, and storing the
      # caller's object aliases it: a builder Hash reused across two declarations gave the FIRST class members
      # appended after it was declared, and mutating a nested shape changed an already-declared contract from
      # the outside. Copying is what makes "the contract is what you declared" true, and it makes the
      # validation memo sound for free — what it keys on can no longer change underneath it.
      #
      # A copy rather than `freeze`: freezing an object the caller owns raises FrozenError on the ordinary
      # builder-loop pattern (append a member, declare, append another, declare again), which copying instead
      # makes behave the way its author obviously meant. Sharing one shape Hash across two axns keeps working
      # for the same reason — each takes its own copy.
      #
      # Copying a node is deliberately NOT recursive, and takes no members of its own: the walk that recurses is
      # the declaration walk (`Contract#_validate_and_snapshot_shape!`), which is also what checks the graph and
      # what bounds its size, and those cannot be separate passes — a members list that answers two walks
      # differently would otherwise leave the class holding members no check ever saw.
      #
      # `:container` is re-read through `[]` — the read every consumer makes — rather than taken from the `each`
      # copy: a shape whose `[]` answers differently from its entries is deciding what the contract IS, and the
      # container check downstream has to see the same answer reflection would.
      def self.snapshot_node(hash, members)
        copy = copy_entries(hash)
        copy[:members] = members
        copy[:container] = hash[:container]
        copy
      end

      # The same node with its members carried forward untouched — the caller's own list, which the declaration
      # walk captures (exactly once) when it reaches this node. For the one WRITE the declaration path makes
      # into a shape, deriving an absent `:container`: writing that into the caller's Hash would change a shape
      # they still hold, and a shape shared between two declarations would carry the first one's container into
      # the second.
      def self.detach_node(hash) = snapshot_node(hash, hash[:members])

      # Only a member that can be REBUILT is copied. Rebuildable means a `Data` — `ShapeConfig` is one — tested
      # with `case`/`when`, which consults the real class, and rebuilt through `Data#with`, so the copy is held
      # to the same name grammar and normalization as the original. Probing for a `with` METHOD is not the same
      # question and gets a false positive: ActiveSupport defines `Object#with`, which takes the same keywords
      # but yields a block, so every member would look rebuildable and none would be. `Data#with` is bound
      # rather than dispatched, so a subclass redefining it cannot decide what the stored contract becomes.
      #
      # A duck-typed member is the caller's own object and cannot be rebuilt — so it, and the nested shape it
      # carries, stay aliased. That residue is bounded and documented rather than papered over.
      DATA_WITH = ::Data.instance_method(:with)
      private_constant :DATA_WITH

      # `validations` is passed in ALREADY READ, and `nested` is the copy the walk made of the shape inside it:
      # both are things the walk needed anyway, and reading them here a second time would ask the caller's
      # object questions it has already answered — which is the same divergence the single walk exists to close.
      # `nested` is omitted when this member carries no nested shape, so a member without one never gains a
      # `:shape` key it did not declare.
      def self.snapshot_member(member, validations, nested: NOT_DEFINED)
        case member
        when ::Data then nil
        else return member
        end

        return member if nil.equal?(validations)

        copied = copy_entries(validations)
        copied[:shape] = nested unless missing?(nested)
        # `nil.equal?` rather than `metadata.nil?`: a Hash subclass answering `nil?` with true would leave the
        # caller's own metadata aliased into the stored contract.
        metadata = hash_or_nil(read(member, :metadata))
        attributes = { validations: copied }
        attributes[:metadata] = copy_entries(metadata) unless nil.equal?(metadata)
        DATA_WITH.bind_call(member, **attributes)
      end

      # The shape carried by an already-read validations Hash. For axn's OWN configs, whose `validations`
      # is the framework's own Hash and so cannot lie — only the shape it holds came from a caller, and
      # that is what gets type-tested here. Skips the method-table lookup `nested_shape` needs, which
      # matters because the redaction walk reads every config's shape on every logged call.
      def self.shape_in(validations)
        hash = hash_or_nil(validations)
        hash_or_nil(hash && hash[:shape])
      end

      # The nested shape a config or member carries (`validations[:shape]`), or nil when it carries
      # none — so a member too minimal to declare `validations` is skipped rather than raising. For a
      # caller-supplied member, whose `validations` reader is itself something to read without trusting.
      def self.nested_shape(owner) = shape_in(read(owner, :validations))

      # Sentinel for "nothing on this object answers to that name", distinguishing it from a reader
      # that genuinely returned nil. A private frozen object of this module's own, and always the
      # RECEIVER of `equal?` (see `missing?`), so no caller's `equal?` is ever dispatched and nothing a
      # caller can construct is mistaken for it.
      NOT_DEFINED = ::Object.new.freeze
      private_constant :NOT_DEFINED

      def self.missing?(value) = NOT_DEFINED.equal?(value)

      # The value of `name` on `object`, or NOT_DEFINED when nothing answers to it.
      #
      # Two lookups, because the standard of correctness is agreement with what reflection reads. The
      # first is `Object#method`, which finds a DEFINED method whatever `respond_to?` claims — so an
      # object defining a reader cannot opt out of a guard by denying it. The second is the plain
      # dispatch reflection itself makes, reached only when nothing defines the name: `Object#method`
      # falls back to `respond_to_missing?`, so a member served entirely by `method_missing` WITHOUT a
      # matching `respond_to_missing?` looks absent to the first lookup while `member.field` answers
      # reflection perfectly well — and a guard that skipped it would leave reflection emitting a name
      # nothing checked. Both are bound rather than dispatched (`#method`, `#public_send` and
      # `#respond_to?` are all overridable), so an object whose own version raises cannot replace a
      # declaration verdict with its exception.
      #
      # Only "nothing answered to THIS name" counts as absence — a NoMethodError naming something else
      # is a bug inside the reader and propagates. So an object that genuinely defines nothing is still
      # skipped rather than raising: the distinction drawn is that a LIE cannot bypass a guard, not that
      # a member must be a full ShapeConfig.
      #
      # Neither half of that comparison dispatches anything the exception's class can define. The stored name
      # is extracted through `NameError`'s own `name` (see NAME_ERROR_NAME), never the subclass's, and axn's
      # own Symbol is the receiver of `equal?` — so a subclass overriding `name` to raise, or returning an
      # object whose `==` raises, changes nothing here. Putting axn's Symbol on the left alone would not be
      # enough: reading `e.name` is itself the dispatch.
      # The Method the real method table defines for `name`, or nil when nothing does. Asked without dispatching
      # `respond_to?`, which an object can override to deny a method it has.
      def self.bound_method(object, name)
        OBJECT_METHOD.bind_call(object, name)
      rescue ::NameError
        nil
      end

      def self.fetch(object, name)
        defined_method = bound_method(object, name)
        return defined_method.call if defined_method

        begin
          OBJECT_PUBLIC_SEND.bind_call(object, name)
        rescue ::NoMethodError => e
          raise unless name.equal?(NAME_ERROR_NAME.bind_call(e))

          NOT_DEFINED
        end
      end

      # The value of `name` on `object`, or nil when nothing answers to it — for a caller that treats an
      # absent reader and a nil one alike (a truthiness test, or a value that gets type-tested anyway).
      # A caller that must tell them apart uses `fetch` with `missing?`.
      def self.read(object, name)
        value = fetch(object, name)
        missing?(value) ? nil : value
      end
    end
  end
end
