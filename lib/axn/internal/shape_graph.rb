# frozen_string_literal: true

# Every ownership question this module answers is answered out of the method table, so a process that loaded
# this file alone must have the reader of that table: the reference is a runtime one, inside the copy.
require "axn/internal/identity"
require "axn/internal/native_methods"

module Axn
  module Internal
    # Non-dispatching reads of a caller-supplied shape graph, and the copy every caller-supplied option
    # container a declaration stores is taken through.
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
    #
    # That holds for what the walk CONVERTS as well as what it reads, and it has to be arranged as
    # deliberately: a member's name is canonicalized with `to_sym`, which is a second dispatch on the same
    # object, so the walk computes that Symbol once beside the check that judges it and stores THAT
    # (see `_check_and_copy_shape_members!`). Reading once while converting twice is the same defect wearing
    # a disguise — it split the duplicate check from the property the member was stored under.
    module ShapeGraph
      # `#public_send` is itself overridable, so the dispatch below goes through Object's implementation: an
      # object whose own `#public_send` raises would otherwise replace a declaration verdict with its
      # exception — and escape every rescue when that exception is outside StandardError.
      OBJECT_PUBLIC_SEND = ::Object.instance_method(:public_send)

      private_constant :OBJECT_PUBLIC_SEND

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
      HASH_KEY_P = ::Hash.instance_method(:key?)
      KERNEL_DUP = ::Kernel.instance_method(:dup)
      HASH_DEFAULT = ::Hash.instance_method(:default)
      HASH_DEFAULT_PROC = ::Hash.instance_method(:default_proc)
      private_constant :HASH_EACH, :HASH_KEY_P, :KERNEL_DUP, :HASH_DEFAULT, :HASH_DEFAULT_PROC

      # Every entry of a caller Hash — THE seam for reading one, so no layer ever asks a Hash subclass to
      # traverse itself.
      def self.each_entry(hash, &)
        HASH_EACH.bind_call(hash, &)
        nil
      end

      # Whether a caller Hash carries a key — BOUND, for the same reason the traversal above is: a guard whose
      # verdict a subclass can change by defining `key?` is not a guard. Read where the answer decides a
      # declaration, alongside `hash_or_nil` for the classification.
      def self.carries_key?(hash, key) = HASH_KEY_P.bind_call(hash, key)

      # Whether a caller Hash answers a key it has no ENTRY for — `Hash.new(x)` or a `default_proc`. What every
      # copy above cannot carry: a copy is entry-wise, so the value such a Hash would have answered with is not
      # in it, while a consumer reading the original with `[]` gets that value. The two disagree, which is the
      # split the copy exists to prevent, and the declaration decides which side is the contract (see
      # `reject_defaulting_option_container!` below).
      #
      # Both readers are Hash's own, bound: a subclass can override either, and one that denied its default
      # would slip past the guard whose whole subject it is. `Hash#default` takes an optional key, and calling
      # it without one never runs a `default_proc` — so neither read can run caller code.
      def self.supplies_default?(hash)
        !nil.equal?(HASH_DEFAULT.bind_call(hash)) || !nil.equal?(HASH_DEFAULT_PROC.bind_call(hash))
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
      # (`NativeMethods.own_array_methods` is empty — see `detached_option_array` below, which is also where
      # the frozen escape hatch and the refusal live), so the bound `dup` runs Ruby's own copy, and every answer
      # the copy gives is the one the original gave.
      def self.detached_dup(value) = KERNEL_DUP.bind_call(value)

      # A contract must not change after the class is declared, and an option value the caller still holds is
      # aliased into it: mutating a `validate:` bag swapped the validator a declared field runs, a mutated `of:`
      # bag changed a declared element type, and appending to an `inclusion:` list widened a declared enum —
      # each after the fact, on a class already defined.
      #
      # Detached one level deep, which is exactly the boundary that matters: the plain Hash/Array CONTAINERS
      # axn stores are copied, while the values inside them stay the caller's objects — a `validate:` callable,
      # a `model:` class, an `inclusion:` member. Those are meant to be the caller's, and copying them would
      # change what a declaration means rather than protect it. `shape:` is excluded because it needs a deep
      # copy of its own (see `Contract::ShapeDeclaration#_validate_and_snapshot_shape!`) and gets one downstream.
      # Nothing an option container can define decides whether it is detached, or what the detached copy holds.
      # The type tests are `case`/`when` (`Module#===`, a C-level check) rather than `is_a?`, and the copies are
      # taken through bound primitives (see ShapeGraph) rather than the container's own `transform_values`/`dup`.
      # A subclass answering `is_a?(Array)` with false, or whose `dup` returned `self`, or whose
      # `transform_values` handed back the receiver, otherwise stayed aliased into the declared contract while
      # the plain-Array case beside it was correctly copied. An ARRAY that owns any of those is now refused
      # before the copy is attempted (see detached_option_array), so the bound `dup` is belt-and-braces there;
      # a BAG is not, since it is copied entry-wise whatever its class, which is what the bound `Hash#each`
      # holds.
      #
      # An Array keeps its CLASS (a same-class `dup`, or the caller's own object when it is already frozen —
      # see detached_option_array) because its own class is part of what a declaration means — a frozen
      # `inclusion:` set answers membership with its own `include?`, and reflection withholds an enum for
      # anything but an exact Array. A bag becomes a plain Hash — which is what it already became, and axn
      # reads bags with `[]`/`dig` only.
      def self.detach_option_containers!(validations)
        validations.each do |key, value|
          next if key == :shape

          case value
          when ::Hash then validations[key] = detached_option_bag(key, value)
          when ::Array then validations[key] = detached_option_array(value, "`#{key}:`")
          end
        end
      end

      def self.detached_option_bag(key, bag)
        reject_defaulting_option_container!(bag) { "the `#{key}:` option bag" }
        copy = copy_entries(bag)
        copy.each do |option_key, option|
          case option
          when ::Array then copy[option_key] = detached_option_array(option, "`#{key}: { #{option_key}: … }`")
          end
        end
        copy
      end

      # A caller Hash that answers missing keys from a DEFAULT is refused wherever a declaration would store one.
      # It is the same split the copy exists to close, arriving from the other side: axn copies every container
      # it stores entry-wise, and a default is not an entry, so the options such a Hash answers are simply not
      # in the stored contract — while a guard reading the original with `[]` sees them. The author is told
      # rather than left to find out, per the option-key rule `Contract#_raise_ambiguous_option_key!` states: an
      # option is never silently ignored.
      #
      # Refusing rather than carrying the default over, because carrying it cannot make the declaration work.
      # ActiveModel builds each validator's options into a Hash of its OWN (`_parse_validates_options`), so a
      # default never reached a validator even when axn stored the caller's bag: `expects :a, type:
      # Hash.new(String)` raised "must supply :klass" on every CALL — a key the author believes they supplied —
      # before this copy existed and after it. Declaration is where that is knowable.
      #
      # The label is YIELDED, so naming the container costs nothing until there is an error to name (see
      # `Contract#_symbol_keyed_bag`), and the two readers consulted are Hash's own (see supplies_default? above).
      def self.reject_defaulting_option_container!(hash)
        return unless supplies_default?(hash)

        raise ArgumentError,
              "#{yield} answers a missing key from a Hash default (`Hash.new(…)` or a `default_proc`) rather " \
              "than from an entry of its own, and axn cannot carry that into the contract: a declared " \
              "container is copied entry-wise so that mutating what you still hold cannot change an " \
              "already-declared class, and ActiveModel rebuilds a validator's options into a Hash of its own " \
              "besides — so an option supplied through the default is dropped, and the declaration fails on a " \
              "call complaining about a key you did supply. Write the options out as entries " \
              "(`type: { klass: String }`)."
      end

      # Three outcomes, and which one a container gets is decided WITHOUT running any of its code.
      #
      # A container axn can copy faithfully by construction is copied, and the copy is the contract. That
      # condition is that the container answers NOTHING with code of its own (`NativeMethods.own_array_methods`
      # is empty): `Kernel#dup` copies the elements, so the copy answers as the original exactly where every
      # answer is a pure function of the elements, which is exactly where every answer is Ruby's own. Every
      # plain Array passes, as does a subclass that adds no methods. A FROZEN container is stored as it is,
      # whatever it owns: the copy exists so that mutating what the caller still holds cannot change a declared
      # contract, and a frozen container cannot be mutated, so there is nothing to detach it from. Anything
      # else is REFUSED at declaration.
      #
      # The refusal is deliberate over-rejection, and it replaces two rounds of verifying the copy and one of
      # gating on the duplication hooks. Comparing the copy's ELEMENTS missed a hook that dropped a derived
      # lookup index the container's own `include?` reads: the elements survived and the copy rejected every one
      # of them. Asking the copy `include?` about each element then missed a hook that dropped only the index of
      # accepted NON-elements — a set holding `"canon"` and aliasing `"alias"` to it accepted both, its copy
      # accepted only `"canon"`, and no element-based probe can see a difference outside the elements. Gating on
      # the duplication HOOKS then missed the copy's other two differences from the original: `dup` shares the
      # instance variables and drops the singleton class, so a membership derived from `self`, from an ivar, or
      # from a singleton method diverges with entirely native duplication (and an ivar-derived one is still the
      # caller's to mutate afterwards, which is the aliasing the copy exists to prevent). Ownership of
      # everything the container answers with is a fact rather than a prediction (see NativeMethods),
      # and a container that would copy faithfully is over-rejected by it with a bounded way to stay legal:
      # freeze it.
      #
      # Two residues, stated rather than papered over, and both are the same one-level depth the copy promises.
      # A FROZEN container's elements — and whatever its ivars point at — are still the caller's objects, so a
      # frozen container deriving membership from a mutable index can still be widened after the class is
      # declared: freezing promises that axn stores what you froze, and how deep that goes is the author's.
      # And a membership container that is not an Array (a `Set`, a `Range`, an object answering `include?`) is
      # not reached here at all: it is stored as the caller's object, so nothing of axn's answers membership and
      # there is nothing to diverge — but nothing detaches it either. A `Range` is frozen by construction; a
      # `Set` is mutable. Both residues are recorded in `property_name_collision_spec.rb`.
      #
      # The container is named by class and its methods by the method table, never by `inspect` — its own code
      # must not run while the declaration error it caused is being built, and both the class name and each
      # method name are rendered like any other name reaching prose (bytes with no UTF-8 rendering, from a
      # constant or from a method name, would otherwise raise while the error is built).
      def self.detached_option_array(value, label)
        return value if NativeMethods.frozen?(value)

        own = NativeMethods.own_array_methods(value)
        return detached_dup(value) if own.empty?

        raise ArgumentError,
              "the #{label} container (of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(value)}) " \
              "defines methods of its " \
              "own (#{describe_own_methods(own)}), so axn cannot copy it. A declared contract is copied at " \
              "declaration so that mutating what you still hold cannot change it — and `dup` copies the " \
              "elements while sharing the instance variables and dropping the singleton class, so the copy " \
              "answers as you declared only where the answer is Ruby's own. What your code answers in the copy " \
              "cannot be established without running it, so a copy that silently rejects the values you " \
              "declared is indistinguishable from a faithful one. Supply a plain Array, or freeze this " \
              "container (a frozen one is stored as-is, since nothing can mutate it afterwards)."
      end

      # The first few offending names, so the author is pointed at the method to move or the object to freeze
      # rather than at a rule. Sorted for a stable message, and capped because a rich subclass has dozens.
      def self.describe_own_methods(names)
        shown = names.uniq.sort
        rendered = shown.first(3).map { |name| "`#{Axn::Internal::Reflection::PropertyNames.inspect_field_name(name)}`" }.join(", ")
        shown.size > 3 ? "#{rendered}, and #{shown.size - 3} more" : rendered
      end

      private_class_method :detached_option_bag, :detached_option_array, :describe_own_methods

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
      # built bottom-up from a graph that walk already traversed. Traversing it is not on its own what makes it
      # shallow enough, though — the walk remembers sub-shapes it has verified, so what it descended is not what
      # it stored — and the depth bound holds here only because that walk re-judges every REFERENCE to a
      # remembered sub-shape against its height (`Contract#_walk_shape_graph!`). So a re-walk can only meet one of
      # these on a graph that never passed it — a field config array assigned onto the class directly, bypassing
      # `expects` entirely. The bounds stay because the alternative outcome is `SystemStackError`, which is outside
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

        " reached from the shape member of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(member)}"
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

      # The same sentence for the OTHER edge a contract graph has (PRO-3166), written out rather than composed
      # from the one above by swapping a noun: every clause names a different construct, and the fix an author
      # can act on ("flatten the nesting" of containers, not "give the shape its own members") is the whole
      # point of saying it. It sits beside its sibling for the reason that one is here — one text per defect,
      # so no two layers describe it two ways.
      #
      # No `member` to name: an `of:` rung is an UNNAMED position, and the runtime walk that raises this
      # (`OfValidator`) is handed a bag rather than the member that declared it. There is no cyclic counterpart
      # either — `guard_pair` treats a repeat as valid at runtime, adding nothing the frame that opened it is
      # not already adding.
      INNER_CONTRACT_AFTER_DECLARATION = "An `of:` bag axn canonicalized at declaration can be neither, so " \
                                         "this graph reached the class without being declared through " \
                                         "`expects`/`exposes` — a field config assigned directly carries the " \
                                         "bag exactly as you built it."
      private_constant :INNER_CONTRACT_AFTER_DECLARATION

      def self.inner_contract_too_deep_message
        "an `of:` graph nests more than #{MAX_NESTING} levels deep, so walking it would recurse until the " \
          "stack overflows — a bag that builds a fresh nested bag on every read is endless, and no " \
          "hand-written declaration nests containers that far. #{INNER_CONTRACT_AFTER_DECLARATION} Flatten " \
          "the nesting, or have the declaration give back the same finite nested bag each time it is read."
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

      # The container of a `shape:` whose position names no class — an `of:` bag that constrains its
      # contents by members alone (`of: { shape: … }`). A Module rather than a bare `nil` because
      # ABSENCE already means something here: it is the bug signature `_derive_raw_shape_container!`
      # exists to catch, a shape that never got a container derived and fails every call with a bare
      # `TypeError: class or module required`. Being a Module also satisfies the "a container must be a
      # class" guard without a special case there. `ShapeValidator` tests it by IDENTITY, with this
      # constant as the receiver, and never with `is_a?` — nothing is an instance of it.
      ANY_CONTAINER = ::Module.new do
        def self.name = "Axn::Internal::ShapeGraph::ANY_CONTAINER"
        def self.to_s = name
      end

      # Where an inner contract can sit. Logical positions, not schema path segments: reflection maps
      # these onto its own `items`/`additionalProperties` spelling, so the declaration layer does not
      # carry the emitter's vocabulary.
      ELEMENT_POSITION = :[]
      KEYS_POSITION = :keys
      VALUES_POSITION = :values
      MAP_POSITIONS = [KEYS_POSITION, VALUES_POSITION].freeze

      # The exempt set of a map that no `shape:` accompanies: every entry is governed. One frozen Array rather
      # than a fresh one per declaration and per undeclared read, since the overwhelmingly common map has no
      # shape beside it and the runtime asks this of every entry of every Hash it validates.
      NO_SHAPED_KEYS = [].freeze

      EMPTY_INNER_CONTRACTS = [].freeze
      private_constant :EMPTY_INNER_CONTRACTS

      # THE one answer to "what containers sit inside this node", shared by the declaration walk, the
      # redaction walk, the ambient walk and reflection — so no two of them can descend a different set.
      #
      # An ARRAY's `of:` bag IS the inner contract (one element position). A HASH's `of:` bag is the axis
      # bag, and the inner contracts are its axis VALUES — only where an axis carries a bag, since a bare
      # type names a class and has nothing inside it. Read through `hash_or_nil` throughout: the bag may be
      # a config ASSIGNED onto a class rather than one this DSL canonicalized, so an `of:` that is not a
      # Hash answers "nothing inside" rather than raising.
      def self.inner_contracts(validations)
        bag = hash_or_nil(validations && validations[:of])
        return EMPTY_INNER_CONTRACTS if nil.equal?(bag)

        return [[ELEMENT_POSITION, bag]] unless ::Hash.equal?(bag[:container])

        MAP_POSITIONS.filter_map do |axis|
          inner = hash_or_nil(bag[axis])
          inner && [axis, inner]
        end
      end

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
      # first reads the object's own METHOD TABLE (`NativeMethods.declared_method`), which finds a
      # DEFINED method whatever `respond_to?` claims — so an object defining a reader cannot opt out of
      # a guard by denying it, and nothing the object wrote runs to answer. The second is the plain
      # dispatch reflection itself makes, reached whenever the table declares nothing: a member served
      # by `method_missing` is absent to a table lookup BY DESIGN, while `member.field` answers
      # reflection perfectly well — and a guard that skipped it would leave reflection emitting a name
      # nothing checked. Both are undispatched at the point of asking (`#public_send` and `#respond_to?`
      # are overridable, and `#method` is a question put to the VALUE, which consults its
      # `respond_to_missing?` for any absent name), so an object whose own version raises cannot replace
      # a declaration verdict with its exception — the reason the table lookup is the first of the two
      # rather than `Object#method`, whose `respond_to_missing?` dispatch runs on exactly the absent
      # branch this method exists to reach.
      #
      # Only "nothing answered to THIS name" counts as absence — a NoMethodError naming something else
      # is a bug inside the reader and propagates. So an object that genuinely defines nothing is still
      # skipped rather than raising: the distinction drawn is that a LIE cannot bypass a guard, not that
      # a member must be a full ShapeConfig.
      #
      # Which name a NoMethodError reports is asked through `Identity.name_error_for?`, the ONE home for that
      # question — it reads the name through `NameError`'s own implementation and makes axn's Symbol the
      # receiver of `equal?`, so neither a subclass overriding `name` nor a returned object's `==` can answer
      # in its place. The full reasoning lives there.

      def self.fetch(object, name)
        declared = Axn::Internal::NativeMethods.declared_method(object, name)
        return declared.bind_call(object) if declared

        begin
          OBJECT_PUBLIC_SEND.bind_call(object, name)
        rescue ::NoMethodError => e
          raise unless Axn::Internal::Identity.name_error_for?(e, name)

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
