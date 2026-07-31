# frozen_string_literal: true

module Axn
  module Internal
    # Non-dispatching reads of a caller-supplied shape graph.
    #
    # A `shape:` kwarg may be handed in raw — an arbitrary object as the shape Hash, and arbitrary
    # objects as its members — and axn has to decide what such a graph DECLARES before it can store
    # anything. An object that lies about its type, or about which methods it has, would otherwise make
    # a guard skip a member the declaration goes on to keep: the guard's verdict and the stored contract
    # disagree, which is precisely what the guard exists to prevent. So every question asked here is
    # answered from the real class and the real method table, never from a method the graph's own
    # objects can define.
    #
    # What a walk genuinely REQUIRES stays the graph's own: reading `:members` off a Hash calls its
    # `[]`, and reading a member's `field` invokes that reader. Those are the reads the declaration is
    # not knowable without, so a lie there changes what axn stores rather than splitting a guard from a
    # consumer — a `[]` that hides members declares a contract without them. Every read of a shape's
    # members in axn therefore goes through `members` below, and nothing reads them another way; a second
    # route (an `each`-copy of the shape's real entries) would see members `[]` had hidden and store a
    # list no guard had walked.
    #
    # An INCONSISTENT lie — a `[]` or a reader answering differently on successive reads — does not split
    # them either, because the declaration walk reads each of them exactly ONCE and stores the answer
    # (`Contract#_check_and_copy_shape_members!` snapshots every member into a `ShapeConfig` of axn's
    # own). What a caller's object can decide is what the contract SAYS, at the one moment it is asked;
    # it cannot say one thing to a guard and another to a consumer, because no consumer asks it again.
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
      private_constant :HASH_EACH, :KERNEL_DUP

      # Every entry of a caller Hash — THE seam for reading one, so no layer ever asks a Hash subclass to
      # traverse itself.
      def self.each_entry(hash, &)
        HASH_EACH.bind_call(hash, &)
        nil
      end

      # A caller Hash's entries, in a plain Hash this module owns.
      def self.copy_entries(hash)
        copy = {}
        each_entry(hash) { |key, value| copy[key] = value }
        copy
      end

      # A same-CLASS shallow copy. The class is preserved deliberately: a container's own behavior is part of
      # what a declaration MEANS — an `inclusion:` set answers membership with its own `include?` — so replacing
      # a subclass with a plain Array would change the contract rather than protect it, and would also publish
      # an enum reflection deliberately withholds for anything but an exact Array.
      #
      # Only ever called for a container that answers nothing with its own code
      # (`NativeMethods.own_array_methods` is empty — see `Contract#_detached_option_array`, which is also where
      # the frozen escape hatch and the refusal live), so the bound `dup` runs Ruby's own copy, and every answer
      # the copy gives is the one the original gave.
      def self.detached_dup(value) = KERNEL_DUP.bind_call(value)

      # How deep a shape graph may nest, for every walk of one. Deep enough that no shape anyone writes by hand
      # can reach it — a hand-written block nests one level per `do…end`, and a schema nested 64 objects deep is
      # unreadable long before it is undeclarable — so the cap only ever fires on a graph something GENERATED.
      #
      # It lives HERE, with the seam every layer reads a shape graph through, because it is the answer to the
      # half of untraversability that identity cannot see. `CycleGuard` catches a graph that repeats an object; a
      # graph that MINTS a fresh nested shape on every read repeats nothing, is endless rather than cyclic, and
      # only a depth bound stops it. Every walk needs both, and two 64s in two layers would be free to drift into
      # disagreeing about what is declarable.
      MAX_NESTING = 64

      # The two ways a shape graph a LATER walk reaches can be untraversable, and the sentence for each. They live
      # here rather than with either walk because more than one layer re-walks a graph the class already holds —
      # the projection's size bound, and the ambient placement check when a later subfield is declared. One text,
      # so two layers cannot describe the same defect two ways. Raising is left to the caller: this module answers
      # questions, it does not decide what a declaration error says.
      #
      # A graph the declaration walk stored can be neither: it is a snapshot of axn's own Hashes and `ShapeConfig`s,
      # built bottom-up from a graph that walk already traversed. So a re-walk can only meet one of these on a
      # graph that never passed it — a field config array assigned onto the class directly, bypassing `expects`
      # entirely. The bounds stay because the alternative outcome is `SystemStackError`, which is outside
      # `StandardError` and escapes the rescue meant to settle a result: from a projection it reaches the caller,
      # and from a log line it takes down the call it was only observing.
      #
      # The member is named by CLASS, never by reading its `field`: that would run the caller's code while the
      # failure is being reported, and a member on this path is by definition one axn never snapshotted, so its
      # readers are still arbitrary code.
      AFTER_DECLARATION = "A `shape:` axn snapshotted at declaration can be neither, so this graph reached the " \
                          "class without being declared through `expects`/`exposes` — a field config assigned " \
                          "directly carries the shape exactly as you built it."
      private_constant :AFTER_DECLARATION

      def self.describe_via(member)
        return "" if nil.equal?(member)

        " reached from the shape member of class #{Axn::Internal::ClassName.of(member)}"
      end

      def self.self_containing_message(member)
        "a `shape:` graph#{describe_via(member)} contains itself, so walking it would recurse until the stack " \
          "overflows. #{AFTER_DECLARATION} Give the nested shape its own members rather than the shape (or the " \
          "member) that encloses it."
      end

      def self.too_deep_message(member)
        "a `shape:` graph#{describe_via(member)} nests more than #{MAX_NESTING} levels deep, so walking it would " \
          "recurse until the stack overflows — a shape object that builds a fresh nested shape on every read is " \
          "endless, and no hand-written shape block reaches that depth. #{AFTER_DECLARATION} Have the shape " \
          "return the same finite nested shape each time it is read, or flatten the nesting."
      end

      # How many member PATHS a stored shape graph may have — every route from a field to a member, counting a
      # nested shape reused by two siblings twice, because every walk of the stored graph walks it twice.
      #
      # Not a bound on emitted JSON properties: that one lives with reflection, is derived from what the emitter
      # actually emits, and applies at projection. This is a bound on the graph ITSELF, and what it bounds is the
      # cost of WALKING one, since every walk pays a step per path.
      #
      # The walks that read a stored graph on a live CALL are what needs bounding, and each needs it for its own
      # reason. Runtime shape
      # validation walks the graph per call and can never be memoized — it is matching a VALUE against members,
      # not deriving a constant. Redaction derives what it can from the declaration once per class
      # (`Contract#_contract_redaction`), so an ordinary contract pays for the graph one time — but that one time
      # lands inside a side channel on a real call: measured with the bound removed, 786,000 paths (one nested
      # shape shared by two siblings, 18 levels deep) cost about two seconds there. And a `sensitive:` that
      # resolves against the ACTION cannot be derived once at all, so it re-walks per logged call: about 1.3
      # seconds per log line at that same size.
      #
      # So the number is what a call may be asked to walk, and 25,000 is generous for anything hand-written: it
      # only fires on a graph that MULTIPLIES out, where N levels of two-way sharing are 2^N paths and one extra
      # nesting level is the whole distance from legal to rejected (13 levels charge 24,574 paths; 14 charge
      # 49,150).
      MAX_MEMBER_PATHS = 25_000

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

      # The members list AS SUPPLIED: the captured list, or nil when the shape supplies none at all. The
      # distinction matters in exactly one place — the declaration walk, where a raw shape with no members list
      # is malformed while an empty one is a real (if pointless) declaration. Every layer after that wants
      # `members`, which treats them alike because neither yields anything to walk. Nil for a non-Hash too: it
      # supplies no members either.
      def self.declared_members(shape)
        hash = hash_or_nil(shape)
        return nil if nil.equal?(hash)

        raw = hash[:members]
        return nil if nil.equal?(raw)

        capture(raw)
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

      # The shape carried by an already-read validations Hash. For axn's OWN configs, whose `validations`
      # is the framework's own Hash and so cannot lie — only the shape it holds came from a caller, and
      # that is what gets type-tested here. Skips the method-table lookup `nested_shape` needs, which
      # matters because the redaction walks read every config's shape.
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
