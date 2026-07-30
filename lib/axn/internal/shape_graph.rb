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
      def self.fetch(object, name)
        defined_method = begin
          OBJECT_METHOD.bind_call(object, name)
        rescue ::NameError
          nil
        end
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
