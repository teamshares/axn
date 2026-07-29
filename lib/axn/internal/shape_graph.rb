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
    # makes, so a lie there changes what both decide rather than splitting them apart.
    module ShapeGraph
      # `#method` is itself overridable, so the lookup below goes through Object's implementation: an
      # object whose own `#method` raises would otherwise replace a declaration verdict with its
      # exception — and escape every rescue when that exception is outside StandardError.
      OBJECT_METHOD = ::Object.instance_method(:method)
      private_constant :OBJECT_METHOD

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
      def self.members(shape)
        hash = hash_or_nil(shape)
        list = hash && hash[:members]
        return [] if list.nil?

        captured = []
        list.each { |member| captured << member } # rubocop:disable Style/MapIntoArray -- `map` is overridable; `each` only
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

      # The Method that actually implements `name` on `object`, or nil when nothing does.
      #
      # `Object#method` finds a defined method regardless of what `respond_to?` claims, so an object
      # DEFINING a reader cannot opt out of a guard by denying it — while a genuinely minimal
      # duck-typed member, which defines nothing, is still skipped. Duck typing keeps working:
      # `respond_to_missing?` is consulted only when nothing defines the name, so a `method_missing`-
      # backed reader still resolves. The distinction this draws is that a LIE cannot bypass a guard,
      # not that a member must be a full ShapeConfig.
      def self.reader(object, name)
        OBJECT_METHOD.bind_call(object, name)
      rescue ::NameError
        nil
      end

      def self.defines?(object, name) = !reader(object, name).nil?

      # The value of `name` on `object`, or nil when nothing defines it. Invoking the reader is the
      # same read reflection performs, so it is the one dispatch the walk requires. Callers that must
      # tell "no such reader" from "the reader returned nil" ask for the `reader` instead.
      def self.read(object, name) = reader(object, name)&.call
    end
  end
end
